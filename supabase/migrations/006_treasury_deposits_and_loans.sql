-- Migration 006: Bank Treasury, Self-Service Deposits, and Loans
--
-- Problem this fixes: every account opened at Rs 0.00, and the ONLY way money
-- could move was customer-account-to-customer-account. There was no source of
-- money at all -- a transfer request ("send my brother 7,000 rupees") had
-- nothing to draw from. This migration adds a real, ledger-consistent funding
-- source instead of a shortcut that would have broken the double-entry
-- invariant this schema enforces everywhere else (system-wide debits=credits,
-- checked nightly by run_reconciliation). No magic balance mutation: every
-- rupee that appears in a customer account here is debited from a real
-- account (the bank's own treasury/reserve) via the exact same
-- process_money_movement() primitive execute_transfer() already uses.

-- ============================================================
-- 1. Treasury account: the bank's own funding source
-- ============================================================

ALTER TABLE public.accounts DROP CONSTRAINT accounts_account_type_check;
ALTER TABLE public.accounts ADD CONSTRAINT accounts_account_type_check
    CHECK (account_type = ANY (ARRAY['checking'::text, 'savings'::text, 'joint'::text, 'business'::text, 'treasury'::text]));

INSERT INTO public.accounts (account_number, account_type, currency, balance, status)
SELECT 'TREASURY-MAIN', 'treasury', 'PKR', 50000000000, 'active'
WHERE NOT EXISTS (SELECT 1 FROM public.accounts WHERE account_number = 'TREASURY-MAIN');
-- Rs 500,000,000.00 of the bank's own capital. Never customer-owned (no
-- account_holders row references it), so it is never reachable through any
-- email-authenticated intent -- only through the RPCs below. Nightly
-- reconciliation checks it like any other active account: its cached balance
-- must equal its ledger-entry sum, same as everyone else's.

-- ============================================================
-- 2. Loans
-- ============================================================

CREATE TABLE public.loans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id UUID NOT NULL REFERENCES public.profiles(id),
    account_id UUID NOT NULL REFERENCES public.accounts(id),
    principal_amount BIGINT NOT NULL CHECK (principal_amount > 0),
    interest_rate_pct NUMERIC NOT NULL DEFAULT 10,
    term_months INT NOT NULL CHECK (term_months > 0 AND term_months <= 60),
    total_repayable BIGINT NOT NULL CHECK (total_repayable > 0),
    monthly_payment_amount BIGINT NOT NULL CHECK (monthly_payment_amount > 0),
    outstanding_balance BIGINT NOT NULL CHECK (outstanding_balance >= 0),
    status TEXT NOT NULL DEFAULT 'pending_review'
        CHECK (status = ANY (ARRAY['pending_review'::text, 'rejected'::text, 'active'::text, 'paid_off'::text])),
    standing_order_id UUID REFERENCES public.standing_orders(id),
    rejection_reason TEXT,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at TIMESTAMPTZ,
    decided_by_profile_id UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.loans ENABLE ROW LEVEL SECURITY;
-- No policies defined -> deny-all for anon/authenticated, matching every
-- other internal financial table (audit_log, idempotency_keys, etc. per
-- migration 003). Made explicit here too rather than left incidental.
CREATE POLICY "deny_all_anon_loans" ON public.loans FOR ALL TO anon USING (false) WITH CHECK (false);
CREATE POLICY "deny_all_authenticated_loans" ON public.loans FOR ALL TO authenticated USING (false) WITH CHECK (false);

ALTER TABLE public.standing_orders ADD COLUMN loan_id UUID REFERENCES public.loans(id);
-- Links a repayment standing order back to the loan it's paying down, so
-- execute_standing_order() (redefined below) can decrement the right loan's
-- outstanding balance and retire it when fully repaid.

-- ============================================================
-- 3. Loan disbursement (shared by auto-approval and manual approval)
-- ============================================================

CREATE OR REPLACE FUNCTION public.disburse_loan(p_loan_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_loan public.loans%ROWTYPE;
    v_treasury_id UUID;
    v_transaction_id UUID;
    v_standing_order_id UUID;
BEGIN
    SELECT * INTO v_loan FROM public.loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found', p_loan_id;
    END IF;

    SELECT id INTO v_treasury_id FROM public.accounts WHERE account_number = 'TREASURY-MAIN';
    IF v_treasury_id IS NULL THEN
        RAISE EXCEPTION 'Treasury account not found';
    END IF;

    v_transaction_id := public.process_money_movement(
        v_treasury_id, v_loan.account_id, v_loan.principal_amount, 'PKR',
        'Loan disbursement', v_loan.profile_id
    );

    INSERT INTO public.standing_orders (
        source_account_id, destination_account_id, amount, currency,
        frequency, next_execution_at, loan_id
    ) VALUES (
        v_loan.account_id, v_treasury_id, v_loan.monthly_payment_amount, 'PKR',
        'monthly', NOW() + INTERVAL '1 month', p_loan_id
    ) RETURNING id INTO v_standing_order_id;

    UPDATE public.loans
    SET status = 'active', standing_order_id = v_standing_order_id, updated_at = NOW()
    WHERE id = p_loan_id;

    PERFORM public.write_audit_log(
        'loan_disbursed', 'system', v_loan.profile_id, 'loan', p_loan_id,
        jsonb_build_object(
            'transaction_id', v_transaction_id, 'principal_amount', v_loan.principal_amount,
            'standing_order_id', v_standing_order_id
        )
    );

    RETURN jsonb_build_object(
        'success', true, 'loan_id', p_loan_id, 'transaction_id', v_transaction_id,
        'standing_order_id', v_standing_order_id,
        'monthly_payment_amount', v_loan.monthly_payment_amount,
        'total_repayable', v_loan.total_repayable, 'term_months', v_loan.term_months
    );
END;
$$;

-- ============================================================
-- 4. apply_for_loan -- customer-facing entry point (called from WF-00)
-- ============================================================

CREATE OR REPLACE FUNCTION public.apply_for_loan(
    p_profile_id UUID,
    p_account_id UUID,
    p_amount BIGINT,
    p_term_months INT DEFAULT 12
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_is_holder BOOLEAN;
    v_loan_id UUID;
    v_interest_rate NUMERIC := 10; -- flat, simple interest -- hackathon-simple by design, not amortized
    v_total_repayable BIGINT;
    v_monthly_payment BIGINT;
    v_auto_approve_ceiling BIGINT := 20000000; -- Rs 200,000: auto-approved instantly, no human step
    v_max_loan_amount BIGINT := 200000000;     -- Rs 2,000,000: hard ceiling, not processable by email at all
    v_disbursement JSONB;
BEGIN
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan amount must be positive');
    END IF;

    IF p_amount > v_max_loan_amount THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Requested amount exceeds the maximum loan size we can process by email (Rs 2,000,000). Please visit a branch for larger loans.');
    END IF;

    IF p_term_months <= 0 OR p_term_months > 60 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan term must be between 1 and 60 months');
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found');
    END IF;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account is not active');
    END IF;

    SELECT EXISTS(
        SELECT 1 FROM public.account_holders WHERE account_id = p_account_id AND profile_id = p_profile_id
    ) INTO v_is_holder;
    IF NOT v_is_holder THEN
        RETURN jsonb_build_object('success', false, 'error', 'Only an account holder may apply for a loan against this account');
    END IF;

    v_total_repayable := ROUND(p_amount * (1 + (v_interest_rate / 100.0) * (p_term_months / 12.0)));
    v_monthly_payment := CEIL(v_total_repayable::NUMERIC / p_term_months);

    INSERT INTO public.loans (
        profile_id, account_id, principal_amount, interest_rate_pct, term_months,
        total_repayable, monthly_payment_amount, outstanding_balance, status
    ) VALUES (
        p_profile_id, p_account_id, p_amount, v_interest_rate, p_term_months,
        v_total_repayable, v_monthly_payment, v_total_repayable, 'pending_review'
    ) RETURNING id INTO v_loan_id;

    PERFORM public.write_audit_log(
        'loan_requested', 'customer', p_profile_id, 'loan', v_loan_id,
        jsonb_build_object('amount', p_amount, 'term_months', p_term_months)
    );

    IF p_amount <= v_auto_approve_ceiling THEN
        v_disbursement := public.disburse_loan(v_loan_id);
        RETURN v_disbursement || jsonb_build_object('status', 'active', 'auto_approved', true);
    END IF;

    RETURN jsonb_build_object(
        'success', true, 'loan_id', v_loan_id, 'status', 'pending_review', 'auto_approved', false,
        'principal_amount', p_amount, 'total_repayable', v_total_repayable,
        'monthly_payment_amount', v_monthly_payment, 'term_months', p_term_months
    );
END;
$$;

-- ============================================================
-- 5. approve_loan / reject_loan -- human operator actions for pending_review loans
-- ============================================================

CREATE OR REPLACE FUNCTION public.approve_loan(p_loan_id UUID, p_approved_by_profile_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_loan public.loans%ROWTYPE;
    v_disbursement JSONB;
BEGIN
    SELECT * INTO v_loan FROM public.loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan not found');
    END IF;

    IF v_loan.status <> 'pending_review' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan is not pending review', 'status', v_loan.status);
    END IF;

    v_disbursement := public.disburse_loan(p_loan_id);

    UPDATE public.loans
    SET decided_at = NOW(), decided_by_profile_id = p_approved_by_profile_id
    WHERE id = p_loan_id;

    RETURN v_disbursement;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_loan(p_loan_id UUID, p_rejected_by_profile_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_loan public.loans%ROWTYPE;
BEGIN
    SELECT * INTO v_loan FROM public.loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan not found');
    END IF;

    IF v_loan.status <> 'pending_review' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan is not pending review', 'status', v_loan.status);
    END IF;

    UPDATE public.loans
    SET status = 'rejected', rejection_reason = p_reason, decided_at = NOW(),
        decided_by_profile_id = p_rejected_by_profile_id, updated_at = NOW()
    WHERE id = p_loan_id;

    PERFORM public.write_audit_log(
        'loan_rejected', 'admin', p_rejected_by_profile_id, 'loan', p_loan_id,
        jsonb_build_object('reason', p_reason)
    );

    RETURN jsonb_build_object('success', true, 'loan_id', p_loan_id, 'status', 'rejected');
END;
$$;

-- ============================================================
-- 6. deposit_funds -- self-service deposit, capped and rate-limited
-- ============================================================
-- A "deposit" claimed by email is fundamentally unverifiable (no real cash/
-- wire rail behind it), so unlike a loan -- a real, approvable liability --
-- this is capped rather than escalated to human review: there's no more a
-- human can verify about a large claimed deposit than a small one.

CREATE OR REPLACE FUNCTION public.deposit_funds(p_account_id UUID, p_amount BIGINT, p_initiated_by_profile_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_treasury_id UUID;
    v_transaction_id UUID;
    v_new_balance BIGINT;
    v_max_deposit BIGINT := 5000000; -- Rs 50,000 per request
    v_recent_deposit_count INT;
BEGIN
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Deposit amount must be positive');
    END IF;

    IF p_amount > v_max_deposit THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Self-service deposits by email are limited to Rs 50,000 per request. For larger deposits, please visit a branch.');
    END IF;

    SELECT COUNT(*) INTO v_recent_deposit_count
    FROM public.transactions
    WHERE destination_account_id = p_account_id
      AND description = 'Self-service deposit'
      AND created_at > NOW() - INTERVAL '24 hours';

    IF v_recent_deposit_count >= 3 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Deposit limit reached: no more than 3 self-service deposits per account in a 24-hour period. Please try again later or visit a branch.');
    END IF;

    SELECT id INTO v_treasury_id FROM public.accounts WHERE account_number = 'TREASURY-MAIN';
    IF v_treasury_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Deposit processing is temporarily unavailable');
    END IF;

    v_transaction_id := public.process_money_movement(
        v_treasury_id, p_account_id, p_amount, 'PKR', 'Self-service deposit', p_initiated_by_profile_id
    );

    SELECT balance INTO v_new_balance FROM public.accounts WHERE id = p_account_id;

    PERFORM public.write_audit_log(
        'funds_deposited', 'customer', p_initiated_by_profile_id, 'account', p_account_id,
        jsonb_build_object('amount', p_amount, 'transaction_id', v_transaction_id, 'new_balance', v_new_balance)
    );

    RETURN jsonb_build_object('success', true, 'transaction_id', v_transaction_id, 'amount', p_amount, 'new_balance', v_new_balance);
END;
$$;

-- ============================================================
-- 7. execute_standing_order -- redefined to also retire loan balances
-- ============================================================
-- Identical to the existing function in every other respect; the only
-- addition is the loan-repayment bookkeeping block inside the success path
-- (marked below), plus the new v_loan_outstanding local variable it needs.

CREATE OR REPLACE FUNCTION public.execute_standing_order(p_standing_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order public.standing_orders%ROWTYPE;
    v_transaction_id UUID;
    v_next_exec TIMESTAMPTZ;
    v_idempotency_key TEXT;
    v_existing_key public.idempotency_keys%ROWTYPE;
    v_err_msg TEXT;
    v_loan_outstanding BIGINT;
BEGIN
    SELECT * INTO v_order
    FROM public.standing_orders
    WHERE id = p_standing_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order not found', 'standing_order_id', p_standing_order_id);
    END IF;

    IF v_order.execution_locked_at IS NOT NULL AND v_order.execution_locked_at > NOW() - INTERVAL '10 minutes' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Standing order is locked by active worker',
            'standing_order_id', p_standing_order_id,
            'locked_at', v_order.execution_locked_at
        );
    END IF;

    IF v_order.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order is not active', 'status', v_order.status);
    END IF;

    IF v_order.next_execution_at > NOW() THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order is not due yet', 'next_execution_at', v_order.next_execution_at);
    END IF;

    v_idempotency_key := 'so_' || p_standing_order_id::text || '_' || EXTRACT(EPOCH FROM v_order.next_execution_at)::text;

    SELECT * INTO v_existing_key
    FROM public.idempotency_keys
    WHERE key = v_idempotency_key FOR UPDATE;

    IF FOUND THEN
        IF v_existing_key.status = 'completed' THEN
            IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
            ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
            ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
            END IF;

            IF v_order.weekend_holiday_rule = 'next_business_day' THEN
                WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                    v_next_exec := v_next_exec + INTERVAL '1 day';
                END LOOP;
            ELSIF v_order.weekend_holiday_rule = 'process_early' THEN
                WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                    v_next_exec := v_next_exec - INTERVAL '1 day';
                END LOOP;
            END IF;

            UPDATE public.standing_orders
            SET next_execution_at = v_next_exec,
                execution_locked_at = NULL
            WHERE id = p_standing_order_id;

            RETURN jsonb_build_object(
                'success', true,
                'message', 'Standing order already executed for scheduled timestamp',
                'standing_order_id', p_standing_order_id,
                'next_execution_at', v_next_exec
            );
        ELSIF v_existing_key.status = 'processing' THEN
            IF v_existing_key.locked_at > NOW() - INTERVAL '5 minutes' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Standing order execution already in progress by another worker',
                    'standing_order_id', p_standing_order_id
                );
            ELSE
                UPDATE public.idempotency_keys
                SET locked_at = NOW()
                WHERE key = v_idempotency_key;
            END IF;
        END IF;
    ELSE
        INSERT INTO public.idempotency_keys (key, request_hash, status, locked_at)
        VALUES (v_idempotency_key, MD5(v_idempotency_key), 'processing', NOW());
    END IF;

    UPDATE public.standing_orders
    SET execution_locked_at = NOW()
    WHERE id = p_standing_order_id;

    BEGIN
        v_transaction_id := public.process_money_movement(
            v_order.source_account_id,
            v_order.destination_account_id,
            v_order.amount,
            v_order.currency,
            'Recurring standing order payment',
            NULL
        );

        UPDATE public.idempotency_keys
        SET status = 'completed',
            transaction_id = v_transaction_id,
            response_body = jsonb_build_object('success', true, 'transaction_id', v_transaction_id)
        WHERE key = v_idempotency_key;

        IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
        ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
        ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
        END IF;

        IF v_order.weekend_holiday_rule = 'next_business_day' THEN
            WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                v_next_exec := v_next_exec + INTERVAL '1 day';
            END LOOP;
        ELSIF v_order.weekend_holiday_rule = 'process_early' THEN
            WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                v_next_exec := v_next_exec - INTERVAL '1 day';
            END LOOP;
        END IF;

        UPDATE public.standing_orders
        SET next_execution_at = v_next_exec,
            execution_locked_at = NULL,
            retry_count = 0,
            last_error = NULL,
            updated_at = NOW()
        WHERE id = p_standing_order_id;

        -- ===== NEW: loan-repayment bookkeeping =====
        IF v_order.loan_id IS NOT NULL THEN
            UPDATE public.loans
            SET outstanding_balance = GREATEST(outstanding_balance - v_order.amount, 0),
                updated_at = NOW()
            WHERE id = v_order.loan_id
            RETURNING outstanding_balance INTO v_loan_outstanding;

            IF v_loan_outstanding <= 0 THEN
                UPDATE public.loans SET status = 'paid_off', updated_at = NOW() WHERE id = v_order.loan_id;
                UPDATE public.standing_orders SET status = 'cancelled', updated_at = NOW() WHERE id = p_standing_order_id;

                PERFORM public.write_audit_log(
                    'loan_paid_off', 'system', NULL, 'loan', v_order.loan_id,
                    jsonb_build_object('standing_order_id', p_standing_order_id)
                );
            END IF;
        END IF;
        -- ===== END NEW =====

        PERFORM public.write_audit_log(
            'standing_order_executed', 'system', NULL, 'standing_order', p_standing_order_id,
            jsonb_build_object('transaction_id', v_transaction_id, 'next_execution_at', v_next_exec)
        );

        RETURN jsonb_build_object(
            'success', true,
            'standing_order_id', p_standing_order_id,
            'transaction_id', v_transaction_id,
            'next_execution_at', v_next_exec
        );

    EXCEPTION WHEN OTHERS THEN
        v_err_msg := SQLERRM;

        UPDATE public.idempotency_keys
        SET status = 'failed',
            response_body = jsonb_build_object('success', false, 'error', v_err_msg)
        WHERE key = v_idempotency_key;

        UPDATE public.standing_orders
        SET retry_count = v_order.retry_count + 1,
            last_error = v_err_msg,
            status = CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END,
            execution_locked_at = NULL,
            updated_at = NOW()
        WHERE id = p_standing_order_id;

        PERFORM public.write_audit_log(
            'standing_order_failed', 'system', NULL, 'standing_order', p_standing_order_id,
            jsonb_build_object(
                'reason', v_err_msg, 'retry_count', v_order.retry_count + 1,
                'status', CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END
            )
        );

        RETURN jsonb_build_object(
            'success', false,
            'error', v_err_msg,
            'standing_order_id', p_standing_order_id,
            'retry_count', v_order.retry_count + 1,
            'status', CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END
        );
    END;
END;
$function$;

-- ============================================================
-- 8. Ownership and grants -- same hardening pattern as every other financial RPC
-- ============================================================

ALTER FUNCTION public.disburse_loan(UUID) OWNER TO banking_functions;
ALTER FUNCTION public.apply_for_loan(UUID, UUID, BIGINT, INT) OWNER TO banking_functions;
ALTER FUNCTION public.approve_loan(UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.reject_loan(UUID, UUID, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.deposit_funds(UUID, BIGINT, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.execute_standing_order(UUID) OWNER TO banking_functions;

REVOKE EXECUTE ON FUNCTION public.disburse_loan(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_for_loan(UUID, UUID, BIGINT, INT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.approve_loan(UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reject_loan(UUID, UUID, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.deposit_funds(UUID, BIGINT, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.execute_standing_order(UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.apply_for_loan(UUID, UUID, BIGINT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.approve_loan(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.reject_loan(UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.deposit_funds(UUID, BIGINT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.execute_standing_order(UUID) TO service_role;
-- disburse_loan is intentionally NOT granted to service_role: it's an internal
-- helper only ever called from inside apply_for_loan/approve_loan, both of
-- which already run as banking_functions (SECURITY DEFINER), so it never
-- needs to be callable directly from n8n.

GRANT ALL PRIVILEGES ON TABLE public.loans TO banking_functions;

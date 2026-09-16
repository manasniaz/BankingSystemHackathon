-- 027_operator_authority_and_loan_withdrawal.sql
--
-- Three separate problems, one migration, because they share a root cause:
-- the database had no concept of "someone who works at the bank". Every email
-- address was a customer address. So the operations mailbox got a customer
-- profile, an account, and eventually a loan with a repayment schedule --
-- the bank lent money to itself and started collecting it.
--
-- What this adds:
--   1. bank_staff        -- who works here. Staff are never customers.
--   2. operator_credit_account  -- ops hands money to a customer as a GRANT,
--                                  not a loan. No interest, no repayment.
--   3. operator_decide_loan     -- ops decides a customer's pending loan by
--                                  naming the customer, not a reference code.
--   4. withdraw_loan_application -- a customer takes back their own
--                                  application while it is still pending.
--   5. resolve_destination_account -- transfer by email address, not just by
--                                  account number.
--
-- Staff emails are deliberately NOT seeded here. They are real addresses and
-- this file is public. See docs/deployment.md for the one INSERT to run.

-- ---------------------------------------------------------------------------
-- 1. Who works at the bank
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.bank_staff (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       TEXT NOT NULL UNIQUE,
    role        TEXT NOT NULL DEFAULT 'ops' CHECK (role IN ('ops', 'admin')),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.bank_staff ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bank_staff FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bank_staff TO service_role;

CREATE OR REPLACE FUNCTION public.is_bank_staff(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.bank_staff
        WHERE lower(email) = lower(trim(COALESCE(p_email, ''))) AND is_active
    );
$$;

-- ---------------------------------------------------------------------------
-- 2. Status vocabulary: a loan can now be withdrawn, an approval cancelled
-- ---------------------------------------------------------------------------

ALTER TABLE public.loans DROP CONSTRAINT IF EXISTS loans_status_check;
ALTER TABLE public.loans ADD CONSTRAINT loans_status_check
    CHECK (status IN ('pending_review', 'rejected', 'active', 'paid_off', 'withdrawn'));

ALTER TABLE public.ops_approvals DROP CONSTRAINT IF EXISTS ops_approvals_status_check;
ALTER TABLE public.ops_approvals ADD CONSTRAINT ops_approvals_status_check
    CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'failed', 'cancelled'));

-- ---------------------------------------------------------------------------
-- 3. Staff are not customers -- database backstop
-- ---------------------------------------------------------------------------
-- n8n stops a staff email long before it reaches here, but the routing layer
-- is the thing most likely to be edited by mistake. This is the floor under it.

CREATE OR REPLACE FUNCTION public.guard_staff_not_customer()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF public.is_bank_staff(NEW.email) THEN
        RAISE EXCEPTION
            'Address % belongs to bank staff and cannot hold a customer profile.',
            NEW.email;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_staff_not_customer ON public.profiles;
CREATE TRIGGER trg_guard_staff_not_customer
    BEFORE INSERT OR UPDATE OF email ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.guard_staff_not_customer();

-- ---------------------------------------------------------------------------
-- 4. Resolving a destination: account number OR email address
-- ---------------------------------------------------------------------------
-- The bank's whole identity model is "you are your email address", so refusing
-- to send money to one was an arbitrary restriction. A name still cannot be
-- resolved -- names are not unique and not proof of anything -- but an address
-- is exactly what we authenticate on.
--
-- Ambiguity is reported, never guessed: if the recipient holds two accounts we
-- ask which one rather than picking the first.

CREATE OR REPLACE FUNCTION public.resolve_destination_account(p_lookup TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_lookup TEXT := trim(COALESCE(p_lookup, ''));
    v_account public.accounts%ROWTYPE;
    v_count INT;
    v_numbers TEXT[];
BEGIN
    IF v_lookup = '' THEN
        RETURN jsonb_build_object('found', false, 'reason', 'no_lookup');
    END IF;

    -- An email address: resolve through the holder, not the account number.
    IF v_lookup LIKE '%@%' THEN
        IF public.is_bank_staff(v_lookup) THEN
            RETURN jsonb_build_object('found', false, 'reason', 'staff_address');
        END IF;

        SELECT COUNT(*), array_agg(a.account_number ORDER BY a.created_at)
        INTO v_count, v_numbers
        FROM public.accounts a
        JOIN public.account_holders ah ON ah.account_id = a.id
        JOIN public.profiles p ON p.id = ah.profile_id
        WHERE lower(p.email) = lower(v_lookup) AND a.status = 'active';

        IF v_count = 0 THEN
            RETURN jsonb_build_object('found', false, 'reason', 'no_such_recipient');
        END IF;

        IF v_count > 1 THEN
            RETURN jsonb_build_object(
                'found', false, 'reason', 'ambiguous_recipient',
                'candidates', to_jsonb(v_numbers)
            );
        END IF;

        SELECT a.* INTO v_account
        FROM public.accounts a
        JOIN public.account_holders ah ON ah.account_id = a.id
        JOIN public.profiles p ON p.id = ah.profile_id
        WHERE lower(p.email) = lower(v_lookup) AND a.status = 'active'
        LIMIT 1;
    ELSE
        SELECT * INTO v_account FROM public.accounts
        WHERE upper(account_number) = upper(v_lookup);

        IF v_account.id IS NULL THEN
            BEGIN
                SELECT * INTO v_account FROM public.accounts WHERE id = v_lookup::uuid;
            EXCEPTION WHEN invalid_text_representation THEN
                v_account := NULL;
            END;
        END IF;

        IF v_account.id IS NULL THEN
            RETURN jsonb_build_object('found', false, 'reason', 'no_such_account');
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'found', true,
        'id', v_account.id,
        'account_id', v_account.id,
        'account_number', v_account.account_number,
        'currency', v_account.currency,
        'status', v_account.status
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. A customer withdrawing their own loan application
-- ---------------------------------------------------------------------------
-- Only while it is still pending. Once the money has been disbursed there is
-- nothing to withdraw -- it is a debt, and cancelling the paperwork would not
-- cancel the obligation. That distinction is the whole function.

CREATE OR REPLACE FUNCTION public.withdraw_loan_application(
    p_profile_id UUID,
    p_loan_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_loan public.loans%ROWTYPE;
    v_account_number TEXT;
    v_cancelled_ref TEXT;
BEGIN
    IF p_profile_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No customer identified.');
    END IF;

    IF p_loan_id IS NOT NULL THEN
        SELECT * INTO v_loan FROM public.loans
        WHERE id = p_loan_id AND profile_id = p_profile_id;

        IF v_loan.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error',
                'We could not find that loan application under your name.');
        END IF;
    ELSE
        SELECT * INTO v_loan FROM public.loans
        WHERE profile_id = p_profile_id AND status = 'pending_review'
        ORDER BY requested_at DESC LIMIT 1;

        IF v_loan.id IS NULL THEN
            -- Distinguish "nothing pending" from "nothing at all", because the
            -- two need completely different replies.
            IF EXISTS (SELECT 1 FROM public.loans
                       WHERE profile_id = p_profile_id AND status = 'active') THEN
                RETURN jsonb_build_object('success', false, 'already_disbursed', true,
                    'error', 'Your loan has already been approved and the money paid out, '
                          || 'so there is no application left to withdraw. The balance is '
                          || 'still owed and is being collected by standing order.');
            END IF;

            RETURN jsonb_build_object('success', false, 'nothing_pending', true,
                'error', 'You have no loan application awaiting a decision.');
        END IF;
    END IF;

    IF v_loan.status = 'active' THEN
        RETURN jsonb_build_object('success', false, 'already_disbursed', true,
            'error', 'That loan has already been approved and the money paid out, so it '
                  || 'cannot be withdrawn. The balance is still owed and is being '
                  || 'collected by standing order.');
    END IF;

    IF v_loan.status <> 'pending_review' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'That loan application is already ' || v_loan.status || '.');
    END IF;

    UPDATE public.loans
    SET status = 'withdrawn',
        decided_at = NOW(),
        rejection_reason = 'Withdrawn by the applicant before a decision was made',
        updated_at = NOW()
    WHERE id = v_loan.id;

    -- The pending ops approval is now pointless. Cancel it so the operations
    -- team is not asked to decide something nobody is asking for any more.
    UPDATE public.ops_approvals
    SET status = 'cancelled',
        decision_note = 'Application withdrawn by the applicant',
        decided_at = NOW(),
        updated_at = NOW()
    WHERE request_type = 'loan' AND target_id = v_loan.id AND status = 'pending'
    RETURNING ref_code INTO v_cancelled_ref;

    SELECT account_number INTO v_account_number
    FROM public.accounts WHERE id = v_loan.account_id;

    PERFORM public.write_audit_log(
        'loan_application_withdrawn', 'customer', p_profile_id, 'loan', v_loan.id,
        jsonb_build_object(
            'principal_amount', v_loan.principal_amount,
            'account_number', v_account_number,
            'cancelled_ops_ref', v_cancelled_ref
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'loan_id', v_loan.id,
        'principal_amount', v_loan.principal_amount,
        'account_number', v_account_number,
        'cancelled_ops_ref', v_cancelled_ref
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Operator credit: the bank giving a customer money
-- ---------------------------------------------------------------------------
-- Distinct from a loan in every way that matters to the customer: no interest,
-- no term, no standing order, nothing to repay. It is their money on arrival.
-- Distinct from a deposit too -- a deposit is the customer claiming to have
-- paid money in, which is why deposits are capped. This is the bank deciding
-- to pay money out, which is why it requires staff.

CREATE OR REPLACE FUNCTION public.operator_credit_account(
    p_operator_email TEXT,
    p_target TEXT,
    p_amount BIGINT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_resolved JSONB;
    v_account public.accounts%ROWTYPE;
    v_treasury public.accounts%ROWTYPE;
    v_txn_id UUID;
    v_holder_email TEXT;
BEGIN
    IF NOT public.is_bank_staff(p_operator_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Only the bank operations team can credit an account.');
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'State a positive amount to credit.');
    END IF;

    v_resolved := public.resolve_destination_account(p_target);
    IF NOT (v_resolved->>'found')::boolean THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Could not identify the account to credit (' ||
                     COALESCE(v_resolved->>'reason', 'unknown') || ').',
            'lookup', p_target, 'detail', v_resolved);
    END IF;

    SELECT * INTO v_account FROM public.accounts
    WHERE id = (v_resolved->>'account_id')::uuid;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is ' || v_account.status ||
            ' and cannot receive a credit.');
    END IF;

    SELECT * INTO v_treasury FROM public.accounts WHERE account_number = 'TREASURY-MAIN';
    IF v_treasury.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Treasury account not found.');
    END IF;

    v_txn_id := public.process_money_movement(
        v_treasury.id, v_account.id, p_amount, v_account.currency,
        'Bank credit' || CASE WHEN p_reason IS NULL OR trim(p_reason) = ''
                              THEN '' ELSE ': ' || trim(p_reason) END,
        NULL
    );

    SELECT p.email INTO v_holder_email
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = v_account.id
    ORDER BY ah.created_at LIMIT 1;

    PERFORM public.write_audit_log(
        'operator_credit', 'admin', NULL, 'account', v_account.id,
        jsonb_build_object(
            'operator_email', p_operator_email,
            'amount', p_amount,
            'reason', p_reason,
            'transaction_id', v_txn_id,
            'account_number', v_account.account_number
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'transaction_id', v_txn_id,
        'account_id', v_account.id,
        'account_number', v_account.account_number,
        'holder_email', v_holder_email,
        'amount', p_amount,
        'new_balance', (SELECT balance FROM public.accounts WHERE id = v_account.id),
        'reason', p_reason
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Operator deciding a loan by naming the customer
-- ---------------------------------------------------------------------------
-- Ops already decides loans by replying to an OPS- reference code. This is the
-- other direction: ops reaching in unprompted, naming an account or a customer,
-- to clear something that is stuck. The reference-code path stays the norm.

CREATE OR REPLACE FUNCTION public.operator_decide_loan(
    p_operator_email TEXT,
    p_target TEXT,
    p_decision TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_resolved JSONB;
    v_account_id UUID;
    v_loan public.loans%ROWTYPE;
    v_holder_email TEXT;
    v_account_number TEXT;
    v_approved JSONB;
BEGIN
    IF NOT public.is_bank_staff(p_operator_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Only the bank operations team can decide a loan this way.');
    END IF;

    IF lower(COALESCE(p_decision, '')) NOT IN ('approve', 'reject') THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Say approve or reject.');
    END IF;

    v_resolved := public.resolve_destination_account(p_target);
    IF NOT (v_resolved->>'found')::boolean THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Could not identify that account (' ||
            COALESCE(v_resolved->>'reason', 'unknown') || ').');
    END IF;
    v_account_id := (v_resolved->>'account_id')::uuid;

    SELECT * INTO v_loan FROM public.loans
    WHERE account_id = v_account_id AND status = 'pending_review'
    ORDER BY requested_at DESC LIMIT 1;

    IF v_loan.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'That account has no loan application awaiting a decision.');
    END IF;

    SELECT account_number INTO v_account_number FROM public.accounts WHERE id = v_account_id;
    SELECT p.email INTO v_holder_email
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = v_account_id ORDER BY ah.created_at LIMIT 1;

    IF lower(p_decision) = 'approve' THEN
        v_approved := public.approve_loan(v_loan.id, NULL);

        UPDATE public.ops_approvals
        SET status = 'approved', decided_by_email = p_operator_email,
            decision_note = p_reason, decided_at = NOW(), updated_at = NOW()
        WHERE request_type = 'loan' AND target_id = v_loan.id AND status = 'pending';

        RETURN jsonb_build_object(
            'success', true, 'decision', 'approve', 'loan_id', v_loan.id,
            'account_number', v_account_number, 'holder_email', v_holder_email,
            'result', v_approved
        );
    END IF;

    UPDATE public.loans
    SET status = 'rejected',
        rejection_reason = COALESCE(NULLIF(trim(p_reason), ''),
                                    'Declined by the bank after review'),
        decided_at = NOW(), updated_at = NOW()
    WHERE id = v_loan.id;

    UPDATE public.ops_approvals
    SET status = 'rejected', decided_by_email = p_operator_email,
        decision_note = p_reason, decided_at = NOW(), updated_at = NOW()
    WHERE request_type = 'loan' AND target_id = v_loan.id AND status = 'pending';

    PERFORM public.write_audit_log(
        'loan_rejected', 'admin', NULL, 'loan', v_loan.id,
        jsonb_build_object('operator_email', p_operator_email, 'reason', p_reason,
                           'account_number', v_account_number)
    );

    RETURN jsonb_build_object(
        'success', true, 'decision', 'reject', 'loan_id', v_loan.id,
        'account_number', v_account_number, 'holder_email', v_holder_email,
        'principal_amount', v_loan.principal_amount,
        'reason', COALESCE(NULLIF(trim(p_reason), ''), 'Declined by the bank after review')
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Tell a blocked customer what they can actually do about it
-- ---------------------------------------------------------------------------
-- The old closure refusal said "the loan must be settled" even when the loan
-- was merely awaiting a decision -- which reads as "you are stuck forever".
-- Now that an application can be withdrawn, the refusal says so.

CREATE OR REPLACE FUNCTION public.request_account_closure(
    p_profile_id UUID,
    p_account_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_existing public.joint_account_actions%ROWTYPE;
    v_requested jsonb;
    v_holder_emails TEXT[];
    v_holder_count INT;
    v_active_holds INT;
    v_active_orders INT;
    v_active_loans INT;
    v_pending_loans INT;
    v_requester_email TEXT;
BEGIN
    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND profile_id = p_profile_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of that account, so you cannot ask us to close it.');
    END IF;

    IF v_account.status = 'closed' THEN
        RETURN jsonb_build_object('success', false, 'already_closed', true, 'error',
            'Account ' || v_account.account_number || ' is already closed.');
    END IF;

    IF v_account.status = 'frozen' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is currently frozen and under review. ' ||
            'It cannot be closed until that review is resolved.');
    END IF;

    IF v_account.balance <> 0 THEN
        RETURN jsonb_build_object('success', false, 'has_balance', true,
            'balance', v_account.balance,
            'account_number', v_account.account_number,
            'error', 'Account ' || v_account.account_number || ' still holds Rs ' ||
                     to_char(v_account.balance / 100.0, 'FM999,999,999.00') ||
                     '. Please transfer the full balance to another account first, ' ||
                     'then ask us to close it.');
    END IF;

    SELECT COUNT(*) INTO v_active_holds
    FROM public.account_holds WHERE account_id = p_account_id AND status = 'active';
    IF v_active_holds > 0 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' has an active hold on it and cannot be ' ||
            'closed until that is released by our team.');
    END IF;

    SELECT COUNT(*) INTO v_active_orders
    FROM public.standing_orders WHERE source_account_id = p_account_id AND status = 'active';
    IF v_active_orders > 0 THEN
        RETURN jsonb_build_object('success', false, 'has_standing_orders', true,
            'standing_order_count', v_active_orders,
            'error', 'Account ' || v_account.account_number || ' has ' || v_active_orders ||
                     ' active standing order(s) paying out of it. Those must be cancelled ' ||
                     'before the account can be closed.');
    END IF;

    SELECT COUNT(*) INTO v_active_loans
    FROM public.loans WHERE account_id = p_account_id AND status = 'active';

    SELECT COUNT(*) INTO v_pending_loans
    FROM public.loans WHERE account_id = p_account_id AND status = 'pending_review';

    IF v_active_loans > 0 THEN
        RETURN jsonb_build_object('success', false, 'has_loan', true,
            'error', 'Account ' || v_account.account_number || ' has an outstanding loan. '
                  || 'The balance must be repaid in full before the account can be closed.');
    END IF;

    IF v_pending_loans > 0 THEN
        RETURN jsonb_build_object('success', false, 'has_loan', true,
            'has_pending_loan', true,
            'error', 'Account ' || v_account.account_number || ' has a loan application still '
                  || 'awaiting a decision. If you no longer want that loan, reply asking us to '
                  || 'cancel your loan application and we will withdraw it -- then the account '
                  || 'can be closed.');
    END IF;

    SELECT array_agg(p.email ORDER BY p.email), COUNT(*)
    INTO v_holder_emails, v_holder_count
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id;

    SELECT email INTO v_requester_email FROM public.profiles WHERE id = p_profile_id;

    SELECT * INTO v_existing FROM public.joint_account_actions
    WHERE account_id = p_account_id AND action_type = 'close_account'
      AND status = 'pending' AND expires_at > NOW()
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true, 'reused', true,
            'ref_code', v_existing.ref_code, 'joint_action_id', v_existing.id,
            'account_number', v_account.account_number, 'account_id', p_account_id,
            'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
            'holder_count', v_holder_count,
            'requester_email', v_requester_email,
            'expires_at', v_existing.expires_at
        );
    END IF;

    v_requested := public.request_joint_closure(p_account_id, p_profile_id);

    RETURN v_requested || jsonb_build_object(
        'reused', false,
        'account_number', v_account.account_number,
        'account_id', p_account_id,
        'account_type', v_account.account_type,
        'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
        'holder_count', v_holder_count,
        'requester_email', v_requester_email
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Permissions
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.is_bank_staff(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_destination_account(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.withdraw_loan_application(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.operator_credit_account(TEXT, TEXT, BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.operator_decide_loan(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.is_bank_staff(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_destination_account(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.withdraw_loan_application(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.operator_credit_account(TEXT, TEXT, BIGINT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.operator_decide_loan(TEXT, TEXT, TEXT, TEXT) TO service_role;

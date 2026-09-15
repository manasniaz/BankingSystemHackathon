-- 020: reversal / chargeback after the funds are already spent (brief item #14),
-- which was the last outright "scoped out" item in the Transactions domain.
--
-- The schema enforces CHECK (balance >= 0) everywhere, and weakening that to let
-- one account go negative would quietly destroy the invariant the whole ledger
-- rests on. So a shortfall is modelled the way a real bank models it: not as a
-- negative deposit balance, but as a RECEIVABLE recorded against the account in
-- its own table. The ledger stays balanced and non-negative; the debt is explicit,
-- auditable and separately settleable.

CREATE TABLE IF NOT EXISTS public.account_debts (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id            UUID NOT NULL REFERENCES public.accounts(id),
    origin_transaction_id UUID REFERENCES public.transactions(id),
    reversal_transaction_id UUID REFERENCES public.transactions(id),
    amount_original       BIGINT NOT NULL CHECK (amount_original > 0),
    amount_outstanding    BIGINT NOT NULL CHECK (amount_outstanding >= 0),
    reason                TEXT NOT NULL,
    status                TEXT NOT NULL DEFAULT 'outstanding'
                              CHECK (status IN ('outstanding', 'settled', 'written_off')),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    settled_at            TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_account_debts_open
    ON public.account_debts (account_id, status);

ALTER TABLE public.account_debts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_debts_deny_anon ON public.account_debts;
CREATE POLICY account_debts_deny_anon ON public.account_debts
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reverse_transaction(
    p_transaction_id uuid, p_reason TEXT, p_requested_by_profile_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tx public.transactions%ROWTYPE;
    v_recipient public.accounts%ROWTYPE;
    v_available BIGINT;
    v_clawback BIGINT;
    v_shortfall BIGINT;
    v_reversal_tx UUID;
    v_debt_id UUID;
BEGIN
    SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Transaction not found.');
    END IF;

    IF v_tx.status = 'reversed' THEN
        RETURN jsonb_build_object('success', false, 'already_reversed', true,
            'error', 'That transaction has already been reversed.');
    END IF;

    IF v_tx.status <> 'completed' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Only a completed transaction can be reversed; this one is ' || v_tx.status || '.');
    END IF;

    IF v_tx.source_account_id IS NULL OR v_tx.destination_account_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This transaction has no counterparty to reverse against.');
    END IF;

    SELECT * INTO v_recipient FROM public.accounts
    WHERE id = v_tx.destination_account_id FOR UPDATE;

    v_available := public.get_available_balance(v_tx.destination_account_id);
    IF v_available < 0 THEN v_available := 0; END IF;

    v_clawback := LEAST(v_available, v_tx.amount);
    v_shortfall := v_tx.amount - v_clawback;

    -- Claw back whatever is actually there, in the same atomic primitive every
    -- other money movement uses, so the reversal is itself double-entry.
    IF v_clawback > 0 THEN
        v_reversal_tx := public.process_money_movement(
            v_tx.destination_account_id,
            v_tx.source_account_id,
            v_clawback,
            v_tx.currency,
            'Reversal of transaction ' || p_transaction_id::text,
            p_requested_by_profile_id
        );
    END IF;

    -- Whatever could not be recovered becomes an explicit debt, NOT a negative
    -- balance. The original sender is made whole later, out of settlement.
    IF v_shortfall > 0 THEN
        INSERT INTO public.account_debts (
            account_id, origin_transaction_id, reversal_transaction_id,
            amount_original, amount_outstanding, reason
        ) VALUES (
            v_tx.destination_account_id, p_transaction_id, v_reversal_tx,
            v_shortfall, v_shortfall,
            COALESCE(NULLIF(btrim(p_reason), ''), 'Reversal shortfall: funds already spent')
        ) RETURNING id INTO v_debt_id;
    END IF;

    UPDATE public.transactions
    SET status = 'reversed', updated_at = NOW()
    WHERE id = p_transaction_id;

    PERFORM public.write_audit_log(
        'transaction_reversed', 'admin', p_requested_by_profile_id, 'transaction', p_transaction_id,
        jsonb_build_object('amount', v_tx.amount, 'recovered', v_clawback,
                           'shortfall', v_shortfall, 'debt_id', v_debt_id,
                           'reason', p_reason)
    );

    RETURN jsonb_build_object(
        'success', true,
        'transaction_id', p_transaction_id,
        'amount', v_tx.amount,
        'recovered', v_clawback,
        'shortfall', v_shortfall,
        'fully_recovered', v_shortfall = 0,
        'debt_id', v_debt_id,
        'reversal_transaction_id', v_reversal_tx,
        'recipient_account_number', v_recipient.account_number,
        'source_account_number', (SELECT account_number FROM public.accounts WHERE id = v_tx.source_account_id),
        'beneficiary_email', (SELECT p.email FROM public.account_holders ah
                              JOIN public.profiles p ON p.id = ah.profile_id
                              WHERE ah.account_id = v_tx.source_account_id
                              ORDER BY ah.created_at LIMIT 1),
        'debtor_email', (SELECT p.email FROM public.account_holders ah
                         JOIN public.profiles p ON p.id = ah.profile_id
                         WHERE ah.account_id = v_tx.destination_account_id
                         ORDER BY ah.created_at LIMIT 1)
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Settling a debt out of whatever the account has, whenever it has it. Run
-- nightly, so a debtor who receives money tomorrow pays it down tomorrow
-- without anyone chasing them, and without their balance ever going negative.

CREATE OR REPLACE FUNCTION public.sweep_outstanding_debts()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_debt RECORD;
    v_available BIGINT;
    v_pay BIGINT;
    v_treasury UUID;
    v_settled INT := 0;
    v_partial INT := 0;
    v_total BIGINT := 0;
BEGIN
    SELECT id INTO v_treasury FROM public.accounts WHERE account_number = 'TREASURY-MAIN';

    FOR v_debt IN
        SELECT d.*, a.currency
        FROM public.account_debts d
        JOIN public.accounts a ON a.id = d.account_id
        WHERE d.status = 'outstanding' AND a.status = 'active'
        ORDER BY d.created_at
    LOOP
        v_available := public.get_available_balance(v_debt.account_id);
        IF v_available IS NULL OR v_available <= 0 THEN
            CONTINUE;
        END IF;

        v_pay := LEAST(v_available, v_debt.amount_outstanding);
        IF v_pay <= 0 THEN CONTINUE; END IF;

        PERFORM public.process_money_movement(
            v_debt.account_id, v_treasury, v_pay, v_debt.currency,
            'Debt settlement for debt ' || v_debt.id::text, NULL
        );

        UPDATE public.account_debts
        SET amount_outstanding = amount_outstanding - v_pay,
            status = CASE WHEN amount_outstanding - v_pay = 0 THEN 'settled' ELSE 'outstanding' END,
            settled_at = CASE WHEN amount_outstanding - v_pay = 0 THEN NOW() ELSE settled_at END,
            updated_at = NOW()
        WHERE id = v_debt.id;

        v_total := v_total + v_pay;
        IF v_pay = v_debt.amount_outstanding THEN v_settled := v_settled + 1;
        ELSE v_partial := v_partial + 1; END IF;

        PERFORM public.write_audit_log(
            'debt_payment_collected', 'system', NULL, 'account', v_debt.account_id,
            jsonb_build_object('debt_id', v_debt.id, 'amount', v_pay,
                               'remaining', v_debt.amount_outstanding - v_pay)
        );
    END LOOP;

    RETURN jsonb_build_object('success', true, 'debts_settled', v_settled,
        'debts_partially_paid', v_partial, 'total_collected', v_total);
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_account_debt_summary(p_account_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_total BIGINT; v_count INT;
BEGIN
    SELECT COALESCE(SUM(amount_outstanding), 0), COUNT(*)
    INTO v_total, v_count
    FROM public.account_debts
    WHERE account_id = p_account_id AND status = 'outstanding';

    RETURN jsonb_build_object('success', true, 'account_id', p_account_id,
        'outstanding_total', v_total, 'debt_count', v_count);
END;
$$;

-- ---------------------------------------------------------------------------
-- finalize_joint_action_if_complete learns the two action types added in 019.
-- Everything else about it (execute first, only mark approved on success, stay
-- pending with last_error on failure) is unchanged from 014.
--
-- NOTE: superseded by 025, which additionally refuses add_holder until the
-- invited person has accepted. Kept here as applied.

CREATE OR REPLACE FUNCTION public.finalize_joint_action_if_complete(p_joint_action_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
    v_total_holders INT;
    v_consents_count INT;
    v_required INT;
    v_result JSONB;
    v_ok BOOLEAN;
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions WHERE id = p_joint_action_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Joint action % not found', p_joint_action_id;
    END IF;

    IF v_action.status <> 'pending' THEN
        RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id,
                                  'status', v_action.status);
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;

    SELECT COUNT(*) INTO v_total_holders FROM public.account_holders WHERE account_id = v_action.account_id;
    SELECT COUNT(*) INTO v_consents_count
    FROM public.joint_account_consents
    WHERE joint_action_id = p_joint_action_id AND consent = TRUE;

    IF v_action.action_type = 'close_account' AND v_account.closure_authority = 'majority' AND v_total_holders >= 3 THEN
        v_required := FLOOR(v_total_holders / 2.0) + 1;
    ELSE
        v_required := v_total_holders;
    END IF;

    IF v_consents_count < v_required THEN
        RETURN jsonb_build_object(
            'success', true, 'joint_action_id', p_joint_action_id, 'status', 'pending',
            'requires_additional_signatures', true,
            'consents_count', v_consents_count, 'required', v_required
        );
    END IF;

    IF v_action.action_type = 'close_account' THEN
        BEGIN
            PERFORM public.close_account(v_action.account_id);
            v_result := jsonb_build_object('success', true, 'executed_action', 'close_account');
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'close_account');
        END;

    ELSIF v_action.action_type = 'transfer_approval' THEN
        v_result := public.execute_transfer(
            v_action.account_id,
            (v_action.payload ->> 'destination_account_id')::UUID,
            (v_action.payload ->> 'amount')::BIGINT,
            v_action.payload ->> 'currency',
            v_action.payload ->> 'idempotency_key',
            v_action.requested_by_profile_id,
            (v_action.payload ->> 'fraud_assessment_id')::UUID
        );

    ELSIF v_action.action_type = 'add_holder' THEN
        BEGIN
            v_result := public.add_account_holder(
                v_action.account_id,
                (v_action.payload ->> 'new_profile_id')::UUID,
                COALESCE(v_action.payload ->> 'role', 'joint'),
                v_action.requested_by_profile_id,
                TRUE
            );
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'add_holder');
        END;

    ELSIF v_action.action_type = 'remove_holder' THEN
        BEGIN
            v_result := public.remove_account_holder(
                v_action.account_id,
                (v_action.payload ->> 'target_profile_id')::UUID,
                v_action.requested_by_profile_id
            );
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'remove_holder');
        END;

    ELSIF v_action.action_type = 'set_authority' THEN
        BEGIN
            v_result := public.apply_authority_change(p_joint_action_id);
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'set_authority');
        END;

    ELSE
        v_result := jsonb_build_object('success', false,
                                       'error', 'Unknown action type ' || v_action.action_type);
    END IF;

    v_ok := COALESCE((v_result ->> 'success')::boolean, false);

    IF v_ok THEN
        UPDATE public.joint_account_actions
        SET status = 'approved', last_error = NULL, updated_at = NOW()
        WHERE id = p_joint_action_id;
    ELSE
        UPDATE public.joint_account_actions
        SET last_error = v_result ->> 'error', updated_at = NOW()
        WHERE id = p_joint_action_id;
    END IF;

    PERFORM public.write_audit_log(
        CASE WHEN v_ok THEN 'joint_action_finalized' ELSE 'joint_action_execution_failed' END,
        'system', NULL, 'joint_account_action', p_joint_action_id,
        jsonb_build_object('action_type', v_action.action_type, 'consents_count', v_consents_count,
                           'required', v_required, 'error', v_result ->> 'error')
    );

    RETURN v_result || jsonb_build_object(
        'joint_action_id', p_joint_action_id,
        'action_type', v_action.action_type,
        'status', CASE WHEN v_ok THEN 'approved' ELSE 'pending' END,
        'all_signatures_collected', true
    );
END;
$$;

ALTER FUNCTION public.reverse_transaction(uuid, TEXT, uuid) OWNER TO banking_functions;
ALTER FUNCTION public.sweep_outstanding_debts() OWNER TO banking_functions;
ALTER FUNCTION public.get_account_debt_summary(uuid) OWNER TO banking_functions;
ALTER FUNCTION public.finalize_joint_action_if_complete(uuid) OWNER TO banking_functions;

REVOKE ALL ON FUNCTION public.reverse_transaction(uuid, TEXT, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sweep_outstanding_debts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_account_debt_summary(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.reverse_transaction(uuid, TEXT, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.sweep_outstanding_debts() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_account_debt_summary(uuid) TO service_role;

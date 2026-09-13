-- =============================================================================
-- MIGRATION: 002_security_hardening.sql
-- DESCRIPTION: Security hardening and reconciliation fix.
--              Applied to live Supabase on 2026-09-13.
-- CHANGES:
--   1. Remove anon write privileges on non-financial tables.
--   2. Restrict request_joint_closure() and record_joint_consent() to service_role only.
--   3. Fix run_reconciliation() to skip closed accounts (only check active/frozen).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. REMOVE ANON WRITE PRIVILEGES
-- -----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON public.profiles FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.account_holders FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.account_holds FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.joint_account_actions FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.joint_account_consents FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.standing_orders FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.reconciliation_runs FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.support_cases FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.support_case_drafts FROM anon;

-- -----------------------------------------------------------------------------
-- 2. RESTRICT JOINT CLOSURE/CONSENT TO service_role ONLY
-- Decision: For MVP, joint closure is orchestrated exclusively by n8n (service_role).
-- Authenticated direct access is removed to prevent identity spoofing via
-- caller-supplied profile_id parameter (auth.role() was removed from these functions).
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.request_joint_closure(UUID, UUID) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_joint_consent(UUID, UUID, BOOLEAN) FROM authenticated;

-- -----------------------------------------------------------------------------
-- 3. FIX run_reconciliation() TO SKIP CLOSED ACCOUNTS
-- Closed accounts are settled (balance = 0 by definition).
-- Their historical ledger entries must not trigger false per-account discrepancies.
-- System-wide debit/credit check still runs across ALL ledger entries.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_reconciliation(p_run_date DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_total_debits BIGINT;
    v_total_credits BIGINT;
    v_discrepancies JSONB := '[]'::jsonb;
    v_rec_id UUID;
    v_passed BOOLEAN;
    v_acc RECORD;
    v_calculated_bal BIGINT;
BEGIN
    SELECT COALESCE(SUM(amount), 0) INTO v_total_debits
    FROM public.ledger_entries WHERE entry_type = 'debit';

    SELECT COALESCE(SUM(amount), 0) INTO v_total_credits
    FROM public.ledger_entries WHERE entry_type = 'credit';

    IF v_total_debits <> v_total_credits THEN
        v_discrepancies := jsonb_insert(
            v_discrepancies, '{0}',
            jsonb_build_object('type', 'system_imbalance', 'debits', v_total_debits, 'credits', v_total_credits)
        );
    END IF;

    -- Only check active and frozen accounts. Closed accounts are settled.
    FOR v_acc IN
        SELECT id, balance, account_number FROM public.accounts
        WHERE status IN ('active', 'frozen')
    LOOP
        SELECT COALESCE(SUM(CASE WHEN entry_type = 'credit' THEN amount ELSE -amount END), 0)
        INTO v_calculated_bal
        FROM public.ledger_entries
        WHERE account_id = v_acc.id;

        IF v_acc.balance <> v_calculated_bal THEN
            v_discrepancies := v_discrepancies || jsonb_build_object(
                'account_id', v_acc.id,
                'account_number', v_acc.account_number,
                'cached_balance', v_acc.balance,
                'ledger_calculated_balance', v_calculated_bal,
                'diff', v_acc.balance - v_calculated_bal
            );
        END IF;
    END LOOP;

    v_passed := (jsonb_array_length(v_discrepancies) = 0);

    INSERT INTO public.reconciliation_runs (
        run_date, passed, total_system_debits, total_system_credits, discrepancies
    ) VALUES (
        p_run_date, v_passed, v_total_debits, v_total_credits, v_discrepancies
    )
    ON CONFLICT (run_date) DO UPDATE
    SET passed = EXCLUDED.passed,
        total_system_debits = EXCLUDED.total_system_debits,
        total_system_credits = EXCLUDED.total_system_credits,
        discrepancies = EXCLUDED.discrepancies,
        created_at = NOW()
    RETURNING id INTO v_rec_id;

    PERFORM public.write_audit_log(
        'reconciliation_completed', 'system', NULL, 'reconciliation_run', v_rec_id,
        jsonb_build_object('passed', v_passed, 'run_date', p_run_date)
    );

    RETURN jsonb_build_object(
        'success', true,
        'reconciliation_id', v_rec_id,
        'run_date', p_run_date,
        'passed', v_passed,
        'total_debits', v_total_debits,
        'total_credits', v_total_credits,
        'discrepancies', v_discrepancies
    );
END;
$$;

ALTER FUNCTION public.run_reconciliation(DATE) OWNER TO banking_functions;
GRANT EXECUTE ON FUNCTION public.run_reconciliation(DATE) TO service_role;

-- End of Migration 002_security_hardening.sql

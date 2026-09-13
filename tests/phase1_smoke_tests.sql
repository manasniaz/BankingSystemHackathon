-- =============================================================================
-- PHASE 1 SMOKE TESTS
-- File: tests/phase1_smoke_tests.sql
--
-- PURPOSE: Verify schema structure, function existence, RLS, triggers,
--          permissions, and basic integrity after migration.
-- PREREQUISITES: Run migrations 001 and 002. Run seed_test_data.sql first.
-- RUN ENVIRONMENT: Supabase Cloud SQL Editor (postgres role).
-- =============================================================================

ALTER ROLE banking_functions BYPASSRLS;
GRANT USAGE ON SCHEMA auth TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.uid() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.role() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.jwt() TO banking_functions;

SELECT '=== PHASE 1 SMOKE TESTS ===' AS section;

-- -----------------------------------------------------------------------------
-- TEST S1: All 15 tables exist
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name IN (
        'profiles','accounts','account_holders','transactions','ledger_entries',
        'idempotency_keys','account_holds','standing_orders','joint_account_actions',
        'joint_account_consents','fraud_assessments','support_cases',
        'support_case_drafts','reconciliation_runs','audit_log'
      );
    IF v_count = 15 THEN
        RAISE NOTICE 'TEST S1: PASS — All 15 tables exist.';
    ELSE
        RAISE NOTICE 'TEST S1: FAIL — Only % of 15 tables found.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S2: All 14 functions exist
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_type = 'FUNCTION'
      AND routine_name IN (
        'create_profile_for_user','get_available_balance','check_fraud_assessment',
        'execute_transfer','execute_standing_order','place_account_hold',
        'release_account_hold','request_joint_closure','record_joint_consent',
        'close_account','run_reconciliation','write_audit_log',
        'process_money_movement','prevent_modification_append_only'
      );
    IF v_count = 14 THEN
        RAISE NOTICE 'TEST S2: PASS — All 14 functions exist.';
    ELSE
        RAISE NOTICE 'TEST S2: FAIL — Only % of 14 functions found.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S3: All functions are SECURITY DEFINER owned by banking_functions
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_roles r ON r.oid = p.proowner
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND r.rolname = 'banking_functions'
      AND p.prosecdef = true;
    IF v_count = 14 THEN
        RAISE NOTICE 'TEST S3: PASS — All 14 functions are SECURITY DEFINER owned by banking_functions.';
    ELSE
        RAISE NOTICE 'TEST S3: FAIL — Only % functions correct.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S4: RLS enabled on all 15 tables
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relrowsecurity = true
      AND c.relname IN (
        'profiles','accounts','account_holders','transactions','ledger_entries',
        'idempotency_keys','account_holds','standing_orders','joint_account_actions',
        'joint_account_consents','fraud_assessments','support_cases',
        'support_case_drafts','reconciliation_runs','audit_log'
      );
    IF v_count = 15 THEN
        RAISE NOTICE 'TEST S4: PASS — RLS enabled on all 15 tables.';
    ELSE
        RAISE NOTICE 'TEST S4: FAIL — RLS only enabled on % tables.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S5: Append-only triggers exist on ledger_entries and audit_log
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.triggers
    WHERE trigger_name IN ('trg_ledger_entries_append_only','trg_audit_log_append_only');
    IF v_count = 4 THEN
        RAISE NOTICE 'TEST S5: PASS — Append-only triggers active (4 events: 2 tables x UPDATE+DELETE).';
    ELSE
        RAISE NOTICE 'TEST S5: FAIL — Expected 4 trigger events, found %.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S6: anon has no write privileges on any table
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.role_table_grants
    WHERE grantee = 'anon'
      AND table_schema = 'public'
      AND privilege_type IN ('INSERT','UPDATE','DELETE');
    IF v_count = 0 THEN
        RAISE NOTICE 'TEST S6: PASS — anon has no write privileges.';
    ELSE
        RAISE NOTICE 'TEST S6: FAIL — anon has % write privileges.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S7: execute_transfer restricted to service_role only
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public'
      AND routine_name = 'execute_transfer'
      AND grantee IN ('authenticated','anon');
    IF v_count = 0 THEN
        RAISE NOTICE 'TEST S7: PASS — execute_transfer not callable by authenticated or anon.';
    ELSE
        RAISE NOTICE 'TEST S7: FAIL — execute_transfer exposed to % non-service roles.', v_count;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S8: joint closure/consent restricted to service_role only
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public'
      AND routine_name IN ('request_joint_closure','record_joint_consent')
      AND grantee = 'authenticated';
    IF v_count = 0 THEN
        RAISE NOTICE 'TEST S8: PASS — Joint RPCs not callable by authenticated users directly.';
    ELSE
        RAISE NOTICE 'TEST S8: FAIL — Joint RPCs still exposed to authenticated role.';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S9: auth trigger exists on auth.users
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.triggers
    WHERE trigger_name = 'on_auth_user_created'
      AND event_object_table = 'users';
    IF v_count >= 1 THEN
        RAISE NOTICE 'TEST S9: PASS — Auth trigger on_auth_user_created exists.';
    ELSE
        RAISE NOTICE 'TEST S9: FAIL — Auth trigger not found.';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S10: Ledger is balanced (debits = credits)
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_debits BIGINT; v_credits BIGINT;
BEGIN
    SELECT
        SUM(CASE WHEN entry_type='debit'  THEN amount ELSE 0 END),
        SUM(CASE WHEN entry_type='credit' THEN amount ELSE 0 END)
    INTO v_debits, v_credits
    FROM public.ledger_entries;
    IF v_debits = v_credits THEN
        RAISE NOTICE 'TEST S10: PASS — Ledger balanced (debits=credits=%).', v_debits;
    ELSE
        RAISE NOTICE 'TEST S10: FAIL — Ledger imbalanced (debits=%, credits=%).', v_debits, v_credits;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S11: Cached balances match ledger truth (active/frozen accounts only)
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_mismatches INT;
BEGIN
    SELECT COUNT(*) INTO v_mismatches
    FROM (
        SELECT a.id
        FROM public.accounts a
        LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        WHERE a.status IN ('active','frozen')
        GROUP BY a.id, a.balance
        HAVING a.balance <> COALESCE(SUM(CASE WHEN le.entry_type='credit' THEN le.amount ELSE -le.amount END),0)
    ) x;
    IF v_mismatches = 0 THEN
        RAISE NOTICE 'TEST S11: PASS — All active/frozen account cached balances match ledger truth.';
    ELSE
        RAISE NOTICE 'TEST S11: FAIL — % accounts have balance drift.', v_mismatches;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S12: Reconciliation passes on clean seed data
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_result JSONB;
BEGIN
    v_result := public.run_reconciliation(CURRENT_DATE);
    IF (v_result->>'passed')::BOOLEAN THEN
        RAISE NOTICE 'TEST S12: PASS — Reconciliation passed with 0 discrepancies.';
    ELSE
        RAISE NOTICE 'TEST S12: FAIL — Reconciliation failed: %', v_result->'discrepancies';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S13: execute_transfer has no active auth.role() call
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_def TEXT;
BEGIN
    SELECT routine_definition INTO v_def
    FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'execute_transfer';

    IF v_def NOT LIKE '%IF (auth.role()%' AND v_def NOT LIKE '%IF(auth.role()%' THEN
        RAISE NOTICE 'TEST S13: PASS — auth.role() not called in execute_transfer.';
    ELSE
        RAISE NOTICE 'TEST S13: FAIL — auth.role() still called in execute_transfer.';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- TEST S14: Seed accounts exist with correct balances
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_alice BIGINT; v_bob BIGINT; v_joint BIGINT;
BEGIN
    SELECT balance INTO v_alice FROM public.accounts WHERE id = 'aa000000-0000-0000-0000-000000000001';
    SELECT balance INTO v_bob   FROM public.accounts WHERE id = 'bb000000-0000-0000-0000-000000000002';
    SELECT balance INTO v_joint FROM public.accounts WHERE id = 'cc000000-0000-0000-0000-000000000003';

    IF v_alice = 100000 AND v_bob = 50000 AND v_joint = 0 THEN
        RAISE NOTICE 'TEST S14: PASS — Alice=100000, Bob=50000, Joint=0.';
    ELSE
        RAISE NOTICE 'TEST S14: FAIL — Alice=%, Bob=%, Joint=%.', v_alice, v_bob, v_joint;
    END IF;
END;
$$;

SELECT '=== SMOKE TESTS COMPLETE — Review notices above ===' AS summary;
SELECT 'Next: run tests/test_transfer_flow.sql' AS next_step;

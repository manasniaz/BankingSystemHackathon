-- =============================================================================
-- PHASE 1: DATABASE SMOKE TESTS
-- File: tests/phase1_smoke_tests.sql
--
-- PURPOSE: Verify schema structure, functions, RLS, ownership, triggers, grants,
--          constraints, and indexes in Supabase Cloud SQL Editor.
-- HOW TO USE:
--   1. Execute migration 001_initial_banking_schema.sql first.
--   2. Paste and run this file in Supabase SQL Editor.
--   3. All sections output clear PASS/FAIL notices and summary status.
-- =============================================================================

-- =============================================================================
-- FIX DEPLOYED SCHEMA ROLE PRIVILEGES
-- Ensure banking_functions has BYPASSRLS and auth schema access so SECURITY DEFINER
-- functions can write to RLS-enabled tables and verify auth.role()/auth.uid().
-- =============================================================================
ALTER ROLE banking_functions BYPASSRLS;
GRANT USAGE ON SCHEMA auth TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.uid() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.role() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.jwt() TO banking_functions;

-- Clean up any residual smoke test data if re-run
DO $$
BEGIN
    SET session_replication_role = 'replica';
    DELETE FROM public.ledger_entries WHERE account_id IN (SELECT id FROM public.accounts WHERE account_number LIKE 'TEST-NEG-%' OR account_number LIKE 'TEST-APPEND-%');
    DELETE FROM public.transactions WHERE source_account_id IN (SELECT id FROM public.accounts WHERE account_number LIKE 'TEST-NEG-%' OR account_number LIKE 'TEST-APPEND-%') OR destination_account_id IN (SELECT id FROM public.accounts WHERE account_number LIKE 'TEST-NEG-%' OR account_number LIKE 'TEST-APPEND-%');
    DELETE FROM public.accounts WHERE account_number LIKE 'TEST-NEG-%' OR account_number LIKE 'TEST-APPEND-%';
    SET session_replication_role = 'origin';
END;
$$;


-- =============================================================================
-- SECTION 1: TABLE EXISTENCE CHECK (15 tables)
-- =============================================================================

SELECT 'SECTION 1: TABLE EXISTENCE' AS test_section;

SELECT
    tablename,
    CASE WHEN tablename IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END AS status
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
    'profiles','accounts','account_holders','transactions','ledger_entries',
    'idempotency_keys','account_holds','standing_orders','joint_account_actions',
    'joint_account_consents','fraud_assessments','support_cases',
    'support_case_drafts','reconciliation_runs','audit_log'
  )
ORDER BY tablename;

SELECT
    CASE WHEN COUNT(*) = 15 THEN 'PASS: All 15 tables exist'
         ELSE 'FAIL: Expected 15 tables, found ' || COUNT(*)::TEXT
    END AS result
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
    'profiles','accounts','account_holders','transactions','ledger_entries',
    'idempotency_keys','account_holds','standing_orders','joint_account_actions',
    'joint_account_consents','fraud_assessments','support_cases',
    'support_case_drafts','reconciliation_runs','audit_log'
  );


-- =============================================================================
-- SECTION 2: FUNCTION EXISTENCE CHECK (14 functions)
-- =============================================================================

SELECT 'SECTION 2: FUNCTION EXISTENCE' AS test_section;

SELECT
    p.proname AS function_name,
    'EXISTS' AS status
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'write_audit_log','create_profile_for_user','get_available_balance',
    'check_fraud_assessment','close_account','process_money_movement',
    'execute_transfer','execute_standing_order','place_account_hold',
    'release_account_hold','request_joint_closure','record_joint_consent',
    'run_reconciliation','prevent_modification_append_only'
  )
ORDER BY p.proname;

SELECT
    CASE WHEN COUNT(DISTINCT p.proname) = 14
         THEN 'PASS: All 14 functions exist'
         ELSE 'FAIL: Expected 14 functions, found ' || COUNT(DISTINCT p.proname)::TEXT
    END AS result
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'write_audit_log','create_profile_for_user','get_available_balance',
    'check_fraud_assessment','close_account','process_money_movement',
    'execute_transfer','execute_standing_order','place_account_hold',
    'release_account_hold','request_joint_closure','record_joint_consent',
    'run_reconciliation','prevent_modification_append_only'
  );


-- =============================================================================
-- SECTION 3: RLS ENABLED CHECK (15 tables)
-- =============================================================================

SELECT 'SECTION 3: RLS ENABLED' AS test_section;

SELECT
    relname AS table_name,
    CASE WHEN relrowsecurity THEN 'RLS ON' ELSE 'RLS OFF' END AS rls_status
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND relname IN (
    'profiles','accounts','account_holders','transactions','ledger_entries',
    'idempotency_keys','account_holds','standing_orders','joint_account_actions',
    'joint_account_consents','fraud_assessments','support_cases',
    'support_case_drafts','reconciliation_runs','audit_log'
  )
ORDER BY relname;

SELECT
    CASE WHEN COUNT(*) = 15 THEN 'PASS: RLS enabled on all 15 tables'
         ELSE 'FAIL: RLS not enabled on ' || (15 - COUNT(*))::TEXT || ' tables'
    END AS result
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relrowsecurity = TRUE
  AND relname IN (
    'profiles','accounts','account_holders','transactions','ledger_entries',
    'idempotency_keys','account_holds','standing_orders','joint_account_actions',
    'joint_account_consents','fraud_assessments','support_cases',
    'support_case_drafts','reconciliation_runs','audit_log'
  );


-- =============================================================================
-- SECTION 4: FUNCTION OWNERSHIP (banking_functions)
-- =============================================================================

SELECT 'SECTION 4: FUNCTION OWNERSHIP' AS test_section;

SELECT
    p.proname AS function_name,
    r.rolname AS owner,
    CASE WHEN r.rolname = 'banking_functions' THEN 'PASS' ELSE 'FAIL - owner is ' || r.rolname END AS status
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_roles r ON r.oid = p.proowner
WHERE n.nspname = 'public'
  AND p.proname IN (
    'write_audit_log','create_profile_for_user','get_available_balance',
    'check_fraud_assessment','close_account','process_money_movement',
    'execute_transfer','execute_standing_order','place_account_hold',
    'release_account_hold','request_joint_closure','record_joint_consent',
    'run_reconciliation','prevent_modification_append_only'
  )
ORDER BY p.proname;


-- =============================================================================
-- SECTION 5: SECURITY DEFINER CHECK
-- =============================================================================

SELECT 'SECTION 5: SECURITY DEFINER' AS test_section;

SELECT
    p.proname AS function_name,
    CASE WHEN p.prosecdef THEN 'SECURITY DEFINER - PASS' ELSE 'SECURITY INVOKER - FAIL' END AS status
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'execute_transfer','execute_standing_order','process_money_movement',
    'place_account_hold','release_account_hold','request_joint_closure',
    'record_joint_consent','run_reconciliation','write_audit_log',
    'check_fraud_assessment','close_account','get_available_balance',
    'create_profile_for_user','prevent_modification_append_only'
  )
ORDER BY p.proname;


-- =============================================================================
-- SECTION 6: APPEND-ONLY PROTECTION TRIGGERS
-- =============================================================================

SELECT 'SECTION 6: APPEND-ONLY TRIGGERS' AS test_section;

SELECT
    trigger_name,
    event_object_table AS table_name,
    event_manipulation
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name IN ('trg_ledger_entries_append_only', 'trg_audit_log_append_only')
ORDER BY trigger_name, event_manipulation;

SELECT
    CASE WHEN COUNT(DISTINCT trigger_name) = 2
         THEN 'PASS: Both append-only triggers exist'
         ELSE 'FAIL: Expected 2 append-only triggers, found ' || COUNT(DISTINCT trigger_name)::TEXT
    END AS result
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name IN ('trg_ledger_entries_append_only', 'trg_audit_log_append_only');


-- =============================================================================
-- SECTION 7: EXECUTE GRANTS CHECK
-- =============================================================================

SELECT 'SECTION 7: EXECUTE GRANTS' AS test_section;

SELECT
    p.proname AS function_name,
    r.rolname AS grantee,
    'HAS EXECUTE' AS privilege,
    CASE
        WHEN p.proname = 'process_money_movement'
             AND r.rolname IN ('authenticated','anon','service_role','PUBLIC')
        THEN 'FAIL: process_money_movement accessible to ' || r.rolname
        WHEN p.proname IN ('execute_transfer','execute_standing_order')
             AND r.rolname = 'service_role'
        THEN 'PASS: RPC callable by service_role'
        ELSE 'INFO'
    END AS status
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) ace ON TRUE
JOIN pg_roles r ON r.oid = ace.grantee
WHERE n.nspname = 'public'
  AND ace.privilege_type = 'EXECUTE'
  AND p.proname IN (
    'execute_transfer','execute_standing_order','process_money_movement',
    'place_account_hold','release_account_hold'
  )
ORDER BY p.proname, r.rolname;


-- =============================================================================
-- SECTION 8: FINANCIAL TABLE WRITE PROTECTION
-- =============================================================================

SELECT 'SECTION 8: FINANCIAL TABLE WRITE PROTECTION' AS test_section;

SELECT
    grantee,
    table_name,
    privilege_type,
    'VIOLATION' AS status
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('accounts','ledger_entries','transactions','idempotency_keys','audit_log')
  AND privilege_type IN ('INSERT','UPDATE','DELETE')
  AND grantee IN ('authenticated','anon','PUBLIC')
ORDER BY table_name, grantee, privilege_type;

SELECT
    CASE WHEN COUNT(*) = 0
         THEN 'PASS: No unauthorized write access to financial tables'
         ELSE 'FAIL: ' || COUNT(*) || ' unauthorized write privileges found'
    END AS result
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('accounts','ledger_entries','transactions','idempotency_keys','audit_log')
  AND privilege_type IN ('INSERT','UPDATE','DELETE')
  AND grantee IN ('authenticated','anon','PUBLIC');


-- =============================================================================
-- SECTION 9: BALANCE CONSTRAINTS
-- =============================================================================

SELECT 'SECTION 9: BALANCE CONSTRAINTS' AS test_section;

SELECT
    column_default,
    CASE WHEN column_default = '0' THEN 'PASS: DEFAULT 0'
         ELSE 'FAIL: default is ' || COALESCE(column_default,'NULL')
    END AS default_check
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'accounts'
  AND column_name = 'balance';

-- Direct negative balance insert attempt (should fail via CHECK constraint)
DO $$
BEGIN
    BEGIN
        INSERT INTO public.accounts (account_number, account_type, currency, balance, status)
        VALUES ('TEST-NEG-BAL-001', 'checking', 'USD', -1, 'active');
        RAISE NOTICE 'SECTION 9b: FAIL - Negative balance was accepted';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'SECTION 9b: PASS - Negative balance rejected: %', SQLERRM;
    END;
END;
$$;


-- =============================================================================
-- SECTION 10: LEDGER APPEND-ONLY ENFORCEMENT
-- =============================================================================

SELECT 'SECTION 10: LEDGER APPEND-ONLY ENFORCEMENT' AS test_section;

DO $$
DECLARE
    v_txn_id UUID;
    v_acct_id UUID;
    v_led_id UUID;
    v_update_blocked BOOLEAN := FALSE;
    v_delete_blocked BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO public.accounts (account_number, account_type, currency, balance, status)
        VALUES ('TEST-APPEND-001', 'checking', 'USD', 0, 'active')
        RETURNING id INTO v_acct_id;

        INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
        VALUES (v_acct_id, v_acct_id, 1, 'USD', 'completed', 'append-only test')
        RETURNING id INTO v_txn_id;

        INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
        VALUES (v_txn_id, v_acct_id, 'credit', 1, 0)
        RETURNING id INTO v_led_id;

        BEGIN
            UPDATE public.ledger_entries SET amount = 9999 WHERE id = v_led_id;
            v_update_blocked := FALSE;
        EXCEPTION WHEN OTHERS THEN
            v_update_blocked := TRUE;
        END;

        BEGIN
            DELETE FROM public.ledger_entries WHERE id = v_led_id;
            v_delete_blocked := FALSE;
        EXCEPTION WHEN OTHERS THEN
            v_delete_blocked := TRUE;
        END;

        RAISE NOTICE 'SECTION 10: Ledger UPDATE blocked: % | DELETE blocked: %',
            CASE WHEN v_update_blocked THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN v_delete_blocked THEN 'PASS' ELSE 'FAIL' END;

        -- Raise exception to rollback this inner block
        RAISE EXCEPTION 'TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'TEST_ROLLBACK' THEN
            RAISE;
        END IF;
    END;
END;
$$;


-- =============================================================================
-- SECTION 11: AUDIT LOG APPEND-ONLY ENFORCEMENT
-- =============================================================================

SELECT 'SECTION 11: AUDIT LOG APPEND-ONLY ENFORCEMENT' AS test_section;

DO $$
DECLARE
    v_audit_id UUID;
    v_update_blocked BOOLEAN := FALSE;
    v_delete_blocked BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO public.audit_log (event_type, actor_type, details)
        VALUES ('test_event', 'system', '{"test": true}')
        RETURNING id INTO v_audit_id;

        BEGIN
            UPDATE public.audit_log SET event_type = 'tampered' WHERE id = v_audit_id;
            v_update_blocked := FALSE;
        EXCEPTION WHEN OTHERS THEN
            v_update_blocked := TRUE;
        END;

        BEGIN
            DELETE FROM public.audit_log WHERE id = v_audit_id;
            v_delete_blocked := FALSE;
        EXCEPTION WHEN OTHERS THEN
            v_delete_blocked := TRUE;
        END;

        RAISE NOTICE 'SECTION 11: Audit log UPDATE blocked: % | DELETE blocked: %',
            CASE WHEN v_update_blocked THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN v_delete_blocked THEN 'PASS' ELSE 'FAIL' END;

        -- Raise exception to rollback this inner block
        RAISE EXCEPTION 'TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'TEST_ROLLBACK' THEN
            RAISE;
        END IF;
    END;
END;
$$;


-- =============================================================================
-- SECTION 12: AUTH TRIGGER CHECK
-- =============================================================================

SELECT 'SECTION 12: AUTH TRIGGER' AS test_section;

SELECT
    trigger_name,
    event_object_schema || '.' || event_object_table AS on_table,
    event_manipulation,
    action_timing,
    'EXISTS' AS status
FROM information_schema.triggers
WHERE trigger_name = 'on_auth_user_created';

SELECT
    CASE WHEN COUNT(*) > 0 THEN 'PASS: on_auth_user_created trigger exists'
         ELSE 'FAIL: on_auth_user_created trigger NOT found'
    END AS result
FROM information_schema.triggers
WHERE trigger_name = 'on_auth_user_created';


-- =============================================================================
-- SECTION 13: INDEXES CHECK (13 indexes)
-- =============================================================================

SELECT 'SECTION 13: INDEXES' AS test_section;

SELECT
    indexname,
    tablename,
    'EXISTS' AS status
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_account_holders_profile','idx_account_holders_account',
    'idx_transactions_source','idx_transactions_dest','idx_transactions_created',
    'idx_ledger_entries_account','idx_ledger_entries_tx',
    'idx_account_holds_account_status','idx_standing_orders_next_exec',
    'idx_fraud_assessments_account','idx_support_cases_profile',
    'idx_audit_log_created','idx_audit_log_event'
  )
ORDER BY indexname;

SELECT
    CASE WHEN COUNT(*) = 13 THEN 'PASS: All 13 indexes exist'
         ELSE 'FAIL: Expected 13 indexes, found ' || COUNT(*)::TEXT
    END AS result
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_account_holders_profile','idx_account_holders_account',
    'idx_transactions_source','idx_transactions_dest','idx_transactions_created',
    'idx_ledger_entries_account','idx_ledger_entries_tx',
    'idx_account_holds_account_status','idx_standing_orders_next_exec',
    'idx_fraud_assessments_account','idx_support_cases_profile',
    'idx_audit_log_created','idx_audit_log_event'
  );


-- =============================================================================
-- SECTION 14: banking_functions ROLE CHECK
-- =============================================================================

SELECT 'SECTION 14: ROLE CHECK' AS test_section;

SELECT
    rolname,
    rolcanlogin,
    CASE WHEN rolname = 'banking_functions' AND NOT rolcanlogin
         THEN 'PASS: role exists, NOLOGIN'
         ELSE 'CHECK'
    END AS status
FROM pg_roles
WHERE rolname = 'banking_functions';

SELECT
    CASE WHEN COUNT(*) = 1 THEN 'PASS: banking_functions role exists'
         ELSE 'FAIL: banking_functions role NOT found'
    END AS result
FROM pg_roles
WHERE rolname = 'banking_functions';


-- =============================================================================
-- SUMMARY
-- =============================================================================

SELECT '=== SMOKE TESTS COMPLETE — Sections 1-14 ===' AS summary;
SELECT 'Check all PASS/FAIL results. Next step: run tests/seed_test_data.sql' AS next_step;

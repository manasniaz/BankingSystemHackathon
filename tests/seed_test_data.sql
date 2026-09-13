-- =============================================================================
-- TEST / DEVELOPMENT SEED DATA
-- File: tests/seed_test_data.sql
--
-- PURPOSE: Insert deterministic test fixtures for functional and integration testing.
-- HOW TO USE:
--   Run in Supabase SQL Editor as postgres AFTER running 001_initial_banking_schema.sql.
--   Fully idempotent: includes an automatic cleanup block to clear previous runs.
-- =============================================================================

-- =============================================================================
-- FIX DEPLOYED SCHEMA ROLE PRIVILEGES
-- The deployed migration created banking_functions without BYPASSRLS, and did
-- not grant auth schema usage. We configure it here so SECURITY DEFINER functions
-- execute cleanly under Supabase Cloud SQL Editor.
-- =============================================================================
ALTER ROLE banking_functions BYPASSRLS;
GRANT USAGE ON SCHEMA auth TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.uid() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.role() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.jwt() TO banking_functions;

-- =============================================================================
-- STEP 0: CLEANUP BLOCK
-- Removes test data from previous runs to ensure repeatable execution
-- =============================================================================

DO $$
BEGIN
    SET session_replication_role = 'replica';

    DELETE FROM public.audit_log
    WHERE actor_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003')
       OR target_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003', 'aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003')
       OR event_type = 'seed_data_loaded';

    DELETE FROM public.reconciliation_runs WHERE run_date = CURRENT_DATE;

    DELETE FROM public.support_case_drafts
    WHERE support_case_id IN (
        SELECT id FROM public.support_cases
        WHERE profile_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003')
    );

    DELETE FROM public.support_cases
    WHERE profile_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003');

    DELETE FROM public.fraud_assessments
    WHERE account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    DELETE FROM public.joint_account_consents
    WHERE profile_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003');

    DELETE FROM public.joint_account_actions
    WHERE account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    DELETE FROM public.standing_orders
    WHERE source_account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    DELETE FROM public.account_holds
    WHERE account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    DELETE FROM public.idempotency_keys
    WHERE key LIKE 'test-%' OR key LIKE 'so_%' OR key LIKE 'seed-%';

    DELETE FROM public.ledger_entries
    WHERE account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    DELETE FROM public.transactions
    WHERE source_account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003')
       OR destination_account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    DELETE FROM public.account_holders
    WHERE profile_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003');

    DELETE FROM public.accounts
    WHERE id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003')
       OR account_number IN ('TEST-ALICE-001', 'TEST-BOB-001', 'TEST-JOINT-001');

    DELETE FROM public.profiles
    WHERE id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003')
       OR email LIKE '%@test.banking';

    SET session_replication_role = 'origin';
    RAISE NOTICE 'SEED CLEANUP: Previous seed data cleared cleanly.';
END;
$$;


-- =============================================================================
-- STEP 1: TEST PROFILES
-- Uses fixed UUIDs and session_replication_role to bypass auth.users FK
-- =============================================================================

DO $$
BEGIN
    SET session_replication_role = 'replica';

    -- Alice
    INSERT INTO public.profiles (id, email, full_name, phone_number)
    VALUES (
        'a0000000-0000-0000-0000-000000000001',
        'alice@test.banking',
        'Alice Testuser',
        '+1-555-000-0001'
    );

    -- Bob
    INSERT INTO public.profiles (id, email, full_name, phone_number)
    VALUES (
        'b0000000-0000-0000-0000-000000000002',
        'bob@test.banking',
        'Bob Testuser',
        '+1-555-000-0002'
    );

    -- Charlie (joint account co-holder with Alice)
    INSERT INTO public.profiles (id, email, full_name, phone_number)
    VALUES (
        'c0000000-0000-0000-0000-000000000003',
        'charlie@test.banking',
        'Charlie Testuser',
        '+1-555-000-0003'
    );

    SET session_replication_role = 'origin';
    RAISE NOTICE 'SEED: Test profiles inserted (Alice, Bob, Charlie).';
END;
$$;


-- =============================================================================
-- STEP 2: TEST ACCOUNTS & INITIAL FUNDING
-- Alice checking ($1,000.00 / 100,000 cents)
-- Bob checking ($500.00 / 50,000 cents)
-- Joint checking ($0.00 balance for closure testing)
-- =============================================================================

DO $$
DECLARE
    v_alice_acct UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_acct UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_joint_acct UUID := 'cc000000-0000-0000-0000-000000000003';

    v_seed_tx_alice UUID;
    v_seed_tx_bob UUID;
    v_alice_fund BIGINT := 100000; -- $1,000.00 in cents
    v_bob_fund   BIGINT := 50000;  -- $500.00 in cents
BEGIN
    -- 1. Alice individual checking
    INSERT INTO public.accounts (id, account_number, account_type, currency, balance, status)
    VALUES (v_alice_acct, 'TEST-ALICE-001', 'checking', 'USD', 0, 'active');

    -- 2. Bob individual checking
    INSERT INTO public.accounts (id, account_number, account_type, currency, balance, status)
    VALUES (v_bob_acct, 'TEST-BOB-001', 'checking', 'USD', 0, 'active');

    -- 3. Joint account (Alice + Charlie, starts at 0 balance for closure test)
    INSERT INTO public.accounts (id, account_number, account_type, currency, balance, status)
    VALUES (v_joint_acct, 'TEST-JOINT-001', 'joint', 'USD', 0, 'active');

    -- =========================================================================
    -- Fund Alice ($1,000.00) and Bob ($500.00) via initial deposit transactions.
    -- Create transaction and ledger entries matching balance update for reconciliation.
    -- =========================================================================

    -- Fund Alice
    INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
    VALUES (v_alice_acct, v_alice_acct, v_alice_fund, 'USD', 'completed', 'Seed initial deposit - Alice')
    RETURNING id INTO v_seed_tx_alice;

    UPDATE public.accounts SET balance = v_alice_fund, updated_at = NOW() WHERE id = v_alice_acct;

    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (v_seed_tx_alice, v_alice_acct, 'credit', v_alice_fund, v_alice_fund);

    -- Fund Bob
    INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
    VALUES (v_bob_acct, v_bob_acct, v_bob_fund, 'USD', 'completed', 'Seed initial deposit - Bob')
    RETURNING id INTO v_seed_tx_bob;

    UPDATE public.accounts SET balance = v_bob_fund, updated_at = NOW() WHERE id = v_bob_acct;

    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (v_seed_tx_bob, v_bob_acct, 'credit', v_bob_fund, v_bob_fund);

    RAISE NOTICE 'SEED: Accounts created and funded (Alice: $1000, Bob: $500, Joint: $0).';
END;
$$;


-- =============================================================================
-- STEP 3: ACCOUNT HOLDERS
-- Matches migration constraint: role IN ('primary', 'joint', 'beneficiary')
-- =============================================================================

DO $$
DECLARE
    v_alice_id UUID   := 'a0000000-0000-0000-0000-000000000001';
    v_bob_id UUID     := 'b0000000-0000-0000-0000-000000000002';
    v_charlie_id UUID := 'c0000000-0000-0000-0000-000000000003';

    v_alice_acct UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_acct UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_joint_acct UUID := 'cc000000-0000-0000-0000-000000000003';
BEGIN
    -- Alice owns her checking account
    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (v_alice_acct, v_alice_id, 'primary');

    -- Bob owns his checking account
    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (v_bob_acct, v_bob_id, 'primary');

    -- Joint account: Alice (primary) + Charlie (joint)
    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (v_joint_acct, v_alice_id, 'primary');

    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (v_joint_acct, v_charlie_id, 'joint');

    RAISE NOTICE 'SEED: Account holders assigned (Alice: primary, Bob: primary, Joint: Alice+Charlie).';
END;
$$;


-- =============================================================================
-- STEP 4: AUDIT LOG
-- =============================================================================

DO $$
BEGIN
    PERFORM public.write_audit_log(
        'seed_data_loaded',
        'system',
        NULL,
        'database',
        NULL,
        jsonb_build_object(
            'environment', 'test/development',
            'loaded_at', NOW(),
            'accounts', ARRAY['TEST-ALICE-001', 'TEST-BOB-001', 'TEST-JOINT-001'],
            'profiles', ARRAY['alice@test.banking', 'bob@test.banking', 'charlie@test.banking']
        )
    );
    RAISE NOTICE 'SEED: Audit log entry recorded.';
END;
$$;


-- =============================================================================
-- STEP 5: VERIFICATION SUMMARY
-- =============================================================================

SELECT 'SEED DATA VERIFICATION' AS section;

SELECT
    p.email,
    a.account_number,
    a.account_type,
    a.balance AS balance_cents,
    (a.balance::NUMERIC / 100)::NUMERIC(12,2) AS balance_dollars,
    a.status,
    ah.role
FROM public.profiles p
JOIN public.account_holders ah ON ah.profile_id = p.id
JOIN public.accounts a ON a.id = ah.account_id
WHERE p.email LIKE '%@test.banking'
ORDER BY p.email, a.account_number;

SELECT 'SEED COMPLETE: Run tests/test_transfer_flow.sql next.' AS next_step;

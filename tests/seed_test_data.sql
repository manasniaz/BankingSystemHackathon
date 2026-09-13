-- =============================================================================
-- TEST / DEVELOPMENT SEED DATA
-- File: tests/seed_test_data.sql
--
-- PURPOSE: Insert deterministic test fixtures for functional and integration testing.
-- PREREQUISITES: Run migrations 001 and 002 first.
-- IDEMPOTENT: Cleanup block removes previous runs before re-seeding.
--
-- ACCOUNTING MODEL:
--   Opening deposits use proper double-entry via BANK-EQUITY-001 (internal account).
--   BANK-EQUITY-001 is closed after distributing capital. run_reconciliation()
--   skips closed accounts, so no false reconciliation failures occur.
--   System invariant: total debits = total credits = 300,000 cents at seed time.
-- =============================================================================

ALTER ROLE banking_functions BYPASSRLS;
GRANT USAGE ON SCHEMA auth TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.uid() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.role() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.jwt() TO banking_functions;

-- =============================================================================
-- STEP 0: CLEANUP
-- =============================================================================
DO $$
BEGIN
    SET session_replication_role = 'replica';

    DELETE FROM public.audit_log
    WHERE actor_id IN (
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-000000000003'
    ) OR target_id IN (
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-000000000003',
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000001'
    ) OR event_type IN ('seed_data_loaded','reconciliation_completed');

    DELETE FROM public.reconciliation_runs;

    DELETE FROM public.support_case_drafts WHERE support_case_id IN (
        SELECT id FROM public.support_cases WHERE profile_id IN (
            'a0000000-0000-0000-0000-000000000001',
            'b0000000-0000-0000-0000-000000000002',
            'c0000000-0000-0000-0000-000000000003'
        )
    );
    DELETE FROM public.support_cases WHERE profile_id IN (
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.fraud_assessments WHERE account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.joint_account_consents WHERE profile_id IN (
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.joint_account_actions WHERE account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.standing_orders WHERE source_account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.account_holds WHERE account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.idempotency_keys
    WHERE key LIKE 'test-%' OR key LIKE 'so_%' OR key LIKE 'seed-%';
    DELETE FROM public.ledger_entries WHERE account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000001'
    );
    DELETE FROM public.transactions
    WHERE source_account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000001'
    ) OR destination_account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000001'
    );
    DELETE FROM public.account_holders WHERE profile_id IN (
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.accounts WHERE id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000001'
    ) OR account_number IN ('TEST-ALICE-001','TEST-BOB-001','TEST-JOINT-001','BANK-EQUITY-001');
    DELETE FROM public.profiles WHERE id IN (
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-000000000003'
    ) OR email LIKE '%@test.banking';

    SET session_replication_role = 'origin';
    RAISE NOTICE 'SEED CLEANUP: Done.';
END;
$$;

-- =============================================================================
-- STEP 1: TEST PROFILES (bypass auth.users FK via replica role)
-- =============================================================================
DO $$
BEGIN
    SET session_replication_role = 'replica';
    INSERT INTO public.profiles (id, email, full_name, phone_number) VALUES
        ('a0000000-0000-0000-0000-000000000001', 'alice@test.banking',   'Alice Testuser',   '+1-555-000-0001'),
        ('b0000000-0000-0000-0000-000000000002', 'bob@test.banking',     'Bob Testuser',     '+1-555-000-0002'),
        ('c0000000-0000-0000-0000-000000000003', 'charlie@test.banking', 'Charlie Testuser', '+1-555-000-0003');
    SET session_replication_role = 'origin';
    RAISE NOTICE 'SEED: Profiles inserted (Alice, Bob, Charlie).';
END;
$$;

-- =============================================================================
-- STEP 2: ACCOUNTS (all start at balance = 0)
-- =============================================================================
INSERT INTO public.accounts (id, account_number, account_type, currency, balance, status) VALUES
    ('aa000000-0000-0000-0000-000000000001', 'TEST-ALICE-001', 'checking', 'USD', 0, 'active'),
    ('bb000000-0000-0000-0000-000000000002', 'TEST-BOB-001',   'checking', 'USD', 0, 'active'),
    ('cc000000-0000-0000-0000-000000000003', 'TEST-JOINT-001', 'joint',    'USD', 0, 'active');

-- =============================================================================
-- STEP 3: ACCOUNT HOLDERS
-- =============================================================================
INSERT INTO public.account_holders (account_id, profile_id, role) VALUES
    ('aa000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'primary'),
    ('bb000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'primary'),
    ('cc000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'primary'),
    ('cc000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'joint');

RAISE NOTICE 'SEED: Accounts and holders created.';

-- =============================================================================
-- STEP 4: OPENING DEPOSITS (proper double-entry via BANK-EQUITY-001)
--
-- BANK-EQUITY-001 (internal, closed after distribution):
--   Capital injection self-balanced: debit 150k + credit 150k (net 0)
--   Alice deposit:  debit BANK-EQUITY-001 100k / credit Alice 100k
--   Bob deposit:    debit BANK-EQUITY-001  50k / credit Bob   50k
--   BANK-EQUITY-001 balance after distribution = 0 -> closed
--   System total: debits = credits = 300,000 cents
-- =============================================================================
DO $$
DECLARE
    v_bank_id  UUID := '00000000-0000-0000-0000-000000000001';
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_tx_cap   UUID;
    v_tx_alice UUID;
    v_tx_bob   UUID;
BEGIN
    -- Bank equity account starts with 150,000 cents (total capital to distribute)
    INSERT INTO public.accounts (id, account_number, account_type, currency, balance, status)
    VALUES (v_bank_id, 'BANK-EQUITY-001', 'business', 'USD', 150000, 'active');

    -- Capital injection: self-balanced bootstrap entry
    INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
    VALUES (v_bank_id, v_bank_id, 150000, 'USD', 'completed', 'Bank capital injection')
    RETURNING id INTO v_tx_cap;
    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after) VALUES
        (v_tx_cap, v_bank_id, 'debit',  150000, 0),
        (v_tx_cap, v_bank_id, 'credit', 150000, 150000);

    -- Alice opening deposit: $1,000.00 (100,000 cents)
    INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
    VALUES (v_bank_id, v_alice_id, 100000, 'USD', 'completed', 'Opening deposit - Alice')
    RETURNING id INTO v_tx_alice;
    UPDATE public.accounts SET balance = balance - 100000, updated_at = NOW() WHERE id = v_bank_id;
    UPDATE public.accounts SET balance = balance + 100000, updated_at = NOW() WHERE id = v_alice_id;
    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after) VALUES
        (v_tx_alice, v_bank_id,  'debit',  100000, 50000),
        (v_tx_alice, v_alice_id, 'credit', 100000, 100000);

    -- Bob opening deposit: $500.00 (50,000 cents)
    INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
    VALUES (v_bank_id, v_bob_id, 50000, 'USD', 'completed', 'Opening deposit - Bob')
    RETURNING id INTO v_tx_bob;
    UPDATE public.accounts SET balance = balance - 50000, updated_at = NOW() WHERE id = v_bank_id;
    UPDATE public.accounts SET balance = balance + 50000, updated_at = NOW() WHERE id = v_bob_id;
    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after) VALUES
        (v_tx_bob, v_bank_id, 'debit',  50000, 0),
        (v_tx_bob, v_bob_id,  'credit', 50000, 50000);

    -- Close BANK-EQUITY-001 after capital fully distributed
    UPDATE public.accounts SET status = 'closed', updated_at = NOW() WHERE id = v_bank_id;

    RAISE NOTICE 'SEED: Double-entry deposits done. Alice=100000, Bob=50000. BANK-EQUITY-001 closed.';
END;
$$;

-- =============================================================================
-- STEP 5: AUDIT LOG
-- =============================================================================
DO $$
BEGIN
    PERFORM public.write_audit_log(
        'seed_data_loaded', 'system', NULL, 'database', NULL,
        jsonb_build_object(
            'environment', 'test/development',
            'loaded_at', NOW(),
            'accounts', ARRAY['TEST-ALICE-001','TEST-BOB-001','TEST-JOINT-001'],
            'note', 'Double-entry opening deposits via BANK-EQUITY-001 (closed after distribution).'
        )
    );
    RAISE NOTICE 'SEED: Audit log recorded.';
END;
$$;

-- =============================================================================
-- STEP 6: VERIFICATION
-- =============================================================================
SELECT 'SEED DATA VERIFICATION' AS section;

SELECT p.email, a.account_number, a.account_type,
       a.balance AS balance_cents,
       (a.balance::NUMERIC/100)::NUMERIC(12,2) AS balance_dollars,
       a.status, ah.role
FROM public.profiles p
JOIN public.account_holders ah ON ah.profile_id = p.id
JOIN public.accounts a ON a.id = ah.account_id
WHERE p.email LIKE '%@test.banking'
ORDER BY p.email, a.account_number;

SELECT
    SUM(CASE WHEN entry_type='debit'  THEN amount ELSE 0 END) AS total_debits,
    SUM(CASE WHEN entry_type='credit' THEN amount ELSE 0 END) AS total_credits,
    SUM(CASE WHEN entry_type='debit'  THEN amount ELSE 0 END) =
    SUM(CASE WHEN entry_type='credit' THEN amount ELSE 0 END) AS ledger_balanced
FROM public.ledger_entries;

SELECT public.run_reconciliation(CURRENT_DATE) AS reconciliation_result;

SELECT 'SEED COMPLETE: Run tests/test_transfer_flow.sql next.' AS next_step;

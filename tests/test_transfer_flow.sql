-- =============================================================================
-- TRANSFER FLOW FUNCTIONAL TESTS
-- File: tests/test_transfer_flow.sql
--
-- PURPOSE: Verify all core financial RPCs, fraud rules, idempotency, standing orders,
--          joint closure workflows, and reconciliation.
-- PREREQUISITE: Run tests/seed_test_data.sql first.
-- RUN ENVIRONMENT: Supabase Cloud SQL Editor (postgres role).
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
-- =============================================================================
-- CLEANUP BLOCK FOR TEST IDEMPOTENCY
-- Resets balances, standing orders, joint actions, and test keys so this file
-- can be run multiple times safely without needing a full re-seed.
-- =============================================================================

DO $$
BEGIN
    -- Reset test balances to seed values
    UPDATE public.accounts SET balance = 100000, status = 'active', updated_at = NOW() WHERE id = 'aa000000-0000-0000-0000-000000000001';
    UPDATE public.accounts SET balance = 50000, status = 'active', updated_at = NOW() WHERE id = 'bb000000-0000-0000-0000-000000000002';
    UPDATE public.accounts SET balance = 0, status = 'active', updated_at = NOW() WHERE id = 'cc000000-0000-0000-0000-000000000003';

    -- Clean up test records created during transfer flow tests
    DELETE FROM public.joint_account_consents WHERE profile_id IN ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003');
    DELETE FROM public.joint_account_actions WHERE account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');
    DELETE FROM public.standing_orders WHERE source_account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');
    DELETE FROM public.fraud_assessments WHERE account_id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');
    DELETE FROM public.idempotency_keys WHERE key LIKE 'test-%' OR key LIKE 'so_%';

    RAISE NOTICE 'TRANSFER TEST CLEANUP: Test environment reset for repeatable execution.';
END;
$$;


-- =============================================================================
-- TEST 0: VERIFY SEED DATA IS PRESENT
-- =============================================================================

SELECT 'TEST 0: SEED DATA PRESENT' AS test_section;

DO $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM public.accounts
    WHERE id IN ('aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000003');

    IF v_count = 3 THEN
        RAISE NOTICE 'TEST 0: PASS — Seed accounts found';
    ELSE
        RAISE EXCEPTION 'TEST 0: FAIL — Seed accounts missing. Run tests/seed_test_data.sql first.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 1: SUCCESSFUL TRANSFER (ATOMICITY & BALANCE MUTATION)
-- =============================================================================

SELECT 'TEST 1: SUCCESSFUL TRANSFER' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID;
    v_result JSONB;
    v_tx_id UUID;
    v_alice_bal_before BIGINT;
    v_alice_bal_after BIGINT;
    v_bob_bal_before BIGINT;
    v_bob_bal_after BIGINT;
    v_debit_count INT;
    v_credit_count INT;
    v_audit_count INT;
    v_tx_count INT;
    v_idem_key TEXT := 'test-transfer-001-' || gen_random_uuid()::text;
BEGIN
    SELECT balance INTO v_alice_bal_before FROM public.accounts WHERE id = v_alice_id;
    SELECT balance INTO v_bob_bal_before FROM public.accounts WHERE id = v_bob_id;

    -- Step 1: Insert valid fraud assessment
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 1000, 5.0, TRUE, 'Low risk assessment', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    -- Step 2: Execute transfer (1000 cents / $10.00 from Alice to Bob)
    v_result := public.execute_transfer(
        v_alice_id,
        v_bob_id,
        1000,
        'USD',
        v_idem_key,
        v_alice_profile_id,
        v_fraud_id
    );

    RAISE NOTICE 'TEST 1: execute_transfer result: %', v_result;

    IF NOT (v_result->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 1: FAIL — Transfer returned success=false: %', v_result->>'error';
        RETURN;
    END IF;

    v_tx_id := (v_result->>'transaction_id')::UUID;

    SELECT COUNT(*) INTO v_tx_count FROM public.transactions WHERE id = v_tx_id;
    SELECT COUNT(*) INTO v_debit_count FROM public.ledger_entries WHERE transaction_id = v_tx_id AND entry_type = 'debit';
    SELECT COUNT(*) INTO v_credit_count FROM public.ledger_entries WHERE transaction_id = v_tx_id AND entry_type = 'credit';
    SELECT balance INTO v_alice_bal_after FROM public.accounts WHERE id = v_alice_id;
    SELECT balance INTO v_bob_bal_after FROM public.accounts WHERE id = v_bob_id;
    SELECT COUNT(*) INTO v_audit_count FROM public.audit_log WHERE event_type = 'transfer_completed' AND target_id = v_tx_id;

    IF v_tx_count = 1 AND v_debit_count = 1 AND v_credit_count = 1
       AND v_alice_bal_after = v_alice_bal_before - 1000
       AND v_bob_bal_after = v_bob_bal_before + 1000
       AND v_audit_count >= 1
    THEN
        RAISE NOTICE 'TEST 1: PASS — Transfer completed atomically (Alice: % -> %, Bob: % -> %).',
            v_alice_bal_before, v_alice_bal_after, v_bob_bal_before, v_bob_bal_after;
    ELSE
        RAISE NOTICE 'TEST 1: FAIL — Verification mismatch.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 2: IDEMPOTENCY REPLAY (SAME KEY + SAME PARAMS)
-- =============================================================================

SELECT 'TEST 2: IDEMPOTENCY REPLAY' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID;
    v_result1 JSONB;
    v_result2 JSONB;
    v_bal_after_first BIGINT;
    v_bal_after_second BIGINT;
    v_idem_key TEXT := 'test-idem-replay-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 500, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    -- First call
    v_result1 := public.execute_transfer(v_alice_id, v_bob_id, 500, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    SELECT balance INTO v_bal_after_first FROM public.accounts WHERE id = v_alice_id;

    -- Second call with SAME key and SAME params
    v_result2 := public.execute_transfer(v_alice_id, v_bob_id, 500, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    SELECT balance INTO v_bal_after_second FROM public.accounts WHERE id = v_alice_id;

    IF (v_result1->>'success')::BOOLEAN
       AND (v_result2->>'success')::BOOLEAN
       AND v_result1->>'transaction_id' = v_result2->>'transaction_id'
       AND v_bal_after_first = v_bal_after_second
    THEN
        RAISE NOTICE 'TEST 2: PASS — Replayed idempotency key returned cached response without double-debiting.';
    ELSE
        RAISE NOTICE 'TEST 2: FAIL — Replay mismatch.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 3: IDEMPOTENCY PARAMETER MISMATCH REJECTION
-- =============================================================================

SELECT 'TEST 3: IDEMPOTENCY PARAMETER MISMATCH' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id_1 UUID;
    v_fraud_id_2 UUID;
    v_result1 JSONB;
    v_result2 JSONB;
    v_idem_key TEXT := 'test-idem-mismatch-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 200, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id_1;

    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 300, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id_2;

    -- First call with amount=200
    v_result1 := public.execute_transfer(v_alice_id, v_bob_id, 200, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id_1);

    -- Second call with SAME key but DIFFERENT amount (300)
    v_result2 := public.execute_transfer(v_alice_id, v_bob_id, 300, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id_2);

    IF (v_result1->>'success')::BOOLEAN
       AND NOT (v_result2->>'success')::BOOLEAN
       AND v_result2->>'error' LIKE '%different parameters%'
    THEN
        RAISE NOTICE 'TEST 3: PASS — Reused key with different parameters rejected cleanly.';
    ELSE
        RAISE NOTICE 'TEST 3: FAIL — Parameter mismatch was not caught.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 4: FAILED TRANSFER ROLLBACK (INSUFFICIENT FUNDS)
-- =============================================================================

SELECT 'TEST 4: FAILED TRANSFER ROLLBACK' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID;
    v_result JSONB;
    v_bal_before BIGINT;
    v_bal_after BIGINT;
    v_tx_count INT;
    v_ledger_count INT;
    v_idem_key TEXT := 'test-insufficient-' || gen_random_uuid()::text;
    v_massive_amount BIGINT := 999999999999;
BEGIN
    SELECT balance INTO v_bal_before FROM public.accounts WHERE id = v_alice_id;

    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, v_massive_amount, 5.0, TRUE, 'Test', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, v_massive_amount, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    SELECT balance INTO v_bal_after FROM public.accounts WHERE id = v_alice_id;

    SELECT COUNT(*) INTO v_tx_count FROM public.transactions WHERE source_account_id = v_alice_id AND amount = v_massive_amount;
    SELECT COUNT(*) INTO v_ledger_count FROM public.ledger_entries le JOIN public.transactions t ON t.id = le.transaction_id WHERE t.source_account_id = v_alice_id AND t.amount = v_massive_amount;

    IF NOT (v_result->>'success')::BOOLEAN
       AND v_bal_before = v_bal_after
       AND v_tx_count = 0
       AND v_ledger_count = 0
    THEN
        RAISE NOTICE 'TEST 4: PASS — Insufficient funds transfer rolled back state cleanly.';
    ELSE
        RAISE NOTICE 'TEST 4: FAIL — Rollback incomplete.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 5: RETRY AFTER FAILURE USES NEW KEY
-- =============================================================================

SELECT 'TEST 5: RETRY AFTER FAILURE USES NEW KEY' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_fail UUID;
    v_fraud_ok UUID;
    v_result_fail JSONB;
    v_result_ok JSONB;
    v_key_fail TEXT := 'test-retry-fail-' || gen_random_uuid()::text;
    v_key_ok   TEXT := 'test-retry-ok-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 999999999, 5.0, TRUE, 'Fail test', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_fail;

    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 100, 5.0, TRUE, 'OK test', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_ok;

    -- Attempt 1 (fails due to amount)
    v_result_fail := public.execute_transfer(v_alice_id, v_bob_id, 999999999, 'USD', v_key_fail, v_alice_profile_id, v_fraud_fail);

    -- Attempt 2 (succeeds with new key and valid amount)
    v_result_ok := public.execute_transfer(v_alice_id, v_bob_id, 100, 'USD', v_key_ok, v_alice_profile_id, v_fraud_ok);

    IF NOT (v_result_fail->>'success')::BOOLEAN AND (v_result_ok->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 5: PASS — Retry with new key succeeded following a failed attempt.';
    ELSE
        RAISE NOTICE 'TEST 5: FAIL.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 6: EXPIRED FRAUD ASSESSMENT REJECTED
-- =============================================================================

SELECT 'TEST 6: EXPIRED FRAUD ASSESSMENT REJECTED' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID;
    v_result JSONB;
    v_idem_key TEXT := 'test-fraud-expired-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 100, 5.0, TRUE, 'Low risk', FALSE, NOW() - INTERVAL '1 minute')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, 100, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);

    IF NOT (v_result->>'success')::BOOLEAN AND v_result->>'error' LIKE '%expired%' THEN
        RAISE NOTICE 'TEST 6: PASS — Expired fraud assessment rejected.';
    ELSE
        RAISE NOTICE 'TEST 6: FAIL — Expired fraud assessment was accepted.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 7: UNAPPROVED FRAUD ASSESSMENT REJECTED
-- =============================================================================

SELECT 'TEST 7: UNAPPROVED FRAUD ASSESSMENT REJECTED' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID;
    v_result JSONB;
    v_idem_key TEXT := 'test-fraud-denied-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 100, 85.0, FALSE, 'High risk — denied', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, 100, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);

    IF NOT (v_result->>'success')::BOOLEAN AND v_result->>'error' LIKE '%NOT approved%' THEN
        RAISE NOTICE 'TEST 7: PASS — Unapproved fraud assessment rejected.';
    ELSE
        RAISE NOTICE 'TEST 7: FAIL — Unapproved fraud assessment was accepted.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 8: FRAUD ASSESSMENT CONSUMED ONLY ONCE
-- =============================================================================

SELECT 'TEST 8: FRAUD ASSESSMENT CONSUMED ONLY ONCE' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID;
    v_result1 JSONB;
    v_result2 JSONB;
    v_key1 TEXT := 'test-consumed-1-' || gen_random_uuid()::text;
    v_key2 TEXT := 'test-consumed-2-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 50, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result1 := public.execute_transfer(v_alice_id, v_bob_id, 50, 'USD', v_key1, v_alice_profile_id, v_fraud_id);
    v_result2 := public.execute_transfer(v_alice_id, v_bob_id, 50, 'USD', v_key2, v_alice_profile_id, v_fraud_id);

    IF (v_result1->>'success')::BOOLEAN
       AND NOT (v_result2->>'success')::BOOLEAN
       AND v_result2->>'error' LIKE '%already been consumed%'
    THEN
        RAISE NOTICE 'TEST 8: PASS — Reuse of consumed fraud assessment rejected.';
    ELSE
        RAISE NOTICE 'TEST 8: FAIL — Fraud assessment reused.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 9: STANDING ORDER EXECUTION
-- =============================================================================

SELECT 'TEST 9: STANDING ORDER EXECUTION' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_order_id UUID;
    v_result JSONB;
    v_bal_before BIGINT;
    v_bal_after BIGINT;
BEGIN
    SELECT balance INTO v_bal_before FROM public.accounts WHERE id = v_alice_id;

    INSERT INTO public.standing_orders (
        source_account_id, destination_account_id, amount, currency,
        frequency, next_execution_at, status, retry_count
    ) VALUES (
        v_alice_id, v_bob_id, 250, 'USD',
        'monthly', NOW() - INTERVAL '1 hour', 'active', 0
    ) RETURNING id INTO v_order_id;

    v_result := public.execute_standing_order(v_order_id);
    SELECT balance INTO v_bal_after FROM public.accounts WHERE id = v_alice_id;

    IF (v_result->>'success')::BOOLEAN AND v_bal_after = v_bal_before - 250 THEN
        RAISE NOTICE 'TEST 9: PASS — Standing order executed successfully ($2.50 deducted).';
    ELSE
        RAISE NOTICE 'TEST 9: FAIL — Standing order execution failed: %', v_result->>'error';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 10: STANDING ORDER DUPLICATE PREVENTION
-- =============================================================================

SELECT 'TEST 10: STANDING ORDER DUPLICATE PREVENTION' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_order_id UUID;
    v_result1 JSONB;
    v_result2 JSONB;
    v_bal_before BIGINT;
    v_bal_after BIGINT;
BEGIN
    SELECT balance INTO v_bal_before FROM public.accounts WHERE id = v_alice_id;

    INSERT INTO public.standing_orders (
        source_account_id, destination_account_id, amount, currency,
        frequency, next_execution_at, status, retry_count
    ) VALUES (
        v_alice_id, v_bob_id, 150, 'USD',
        'daily', NOW() - INTERVAL '2 hours', 'active', 0
    ) RETURNING id INTO v_order_id;

    v_result1 := public.execute_standing_order(v_order_id);
    v_result2 := public.execute_standing_order(v_order_id);
    SELECT balance INTO v_bal_after FROM public.accounts WHERE id = v_alice_id;

    IF (v_result1->>'success')::BOOLEAN
       AND NOT (v_result2->>'success')::BOOLEAN
       AND v_result2->>'error' LIKE '%not due yet%'
       AND v_bal_after = v_bal_before - 150
    THEN
        RAISE NOTICE 'TEST 10: PASS — Duplicate standing order execution prevented.';
    ELSE
        RAISE NOTICE 'TEST 10: FAIL — Standing order ran twice.';
    END IF;
END;
$$;


-- =============================================================================
-- TEST 11: STANDING ORDER RETRIES & PERMANENT FAILURE
-- =============================================================================

SELECT 'TEST 11: STANDING ORDER RETRIES & PERMANENT FAILURE' AS test_section;

DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id UUID   := 'bb000000-0000-0000-0000-000000000002';
    v_order_id UUID;
    v_result JSONB;
    v_retry_count INT;
    v_status TEXT;
BEGIN
    INSERT INTO public.standing_orders (
        source_account_id, destination_account_id, amount, currency,
        frequency, next_execution_at, status, retry_count
    ) VALUES (
        v_alice_id, v_bob_id, 999999999999, 'USD',
        'daily', NOW() - INTERVAL '1 hour', 'active', 0
    ) RETURNING id INTO v_order_id;

    -- Attempt 1
    v_result := public.execute_standing_order(v_order_id);

    -- Attempt 2 (reset next_execution_at to past)
    UPDATE public.standing_orders SET next_execution_at = NOW() - INTERVAL '1 hour' WHERE id = v_order_id;
    v_result := public.execute_standing_order(v_order_id);

    -- Attempt 3 (reset next_execution_at to past -> triggers permanent failure state)
    UPDATE public.standing_orders SET next_execution_at = NOW() - INTERVAL '1 hour' WHERE id = v_order_id;
    v_result := public.execute_standing_order(v_order_id);

    SELECT retry_count, status INTO v_retry_count, v_status FROM public.standing_orders WHERE id = v_order_id;

    -- Attempt 4 (verify execution blocked)
    UPDATE public.standing_orders SET next_execution_at = NOW() - INTERVAL '1 hour' WHERE id = v_order_id;
    v_result := public.execute_standing_order(v_order_id);

    IF v_retry_count = 3 AND v_status = 'failed' AND NOT (v_result->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 11: PASS — Standing order incremented retry counter to 3 and marked permanent failure.';
    ELSE
        RAISE NOTICE 'TEST 11: FAIL — Retry/failure status incorrect (retry_count=%, status=%).', v_retry_count, v_status;
    END IF;
END;
$$;


-- =============================================================================
-- TEST 12: JOINT ACCOUNT CLOSURE WORKFLOW
-- Requires all holder consents (Alice + Charlie) and balance = 0
-- =============================================================================

SELECT 'TEST 12: JOINT ACCOUNT CLOSURE WORKFLOW' AS test_section;

DO $$
DECLARE
    v_joint_id UUID := 'cc000000-0000-0000-0000-000000000003';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_charlie_profile_id UUID := 'c0000000-0000-0000-0000-000000000003';
    v_action_id UUID;
    v_result1 JSONB;
    v_result2 JSONB;
    v_action_status TEXT;
    v_account_status TEXT;
BEGIN
    -- Step 1: Alice requests closure
    v_result1 := public.request_joint_closure(v_joint_id, v_alice_profile_id);
    v_action_id := (v_result1->>'joint_action_id')::UUID;

    -- Step 2: Charlie records consent
    v_result2 := public.record_joint_consent(v_action_id, v_charlie_profile_id, TRUE);

    SELECT status INTO v_action_status FROM public.joint_account_actions WHERE id = v_action_id;
    SELECT status INTO v_account_status FROM public.accounts WHERE id = v_joint_id;

    IF (v_result1->>'status') = 'pending'
       AND v_action_status = 'approved'
       AND v_account_status = 'closed'
    THEN
        RAISE NOTICE 'TEST 12: PASS — Joint closure executed after receiving all co-holder consents.';
    ELSE
        RAISE NOTICE 'TEST 12: FAIL — Joint closure workflow incomplete (action=%, account=%).', v_action_status, v_account_status;
    END IF;
END;
$$;


-- =============================================================================
-- TEST 13: RECONCILIATION ENGINE
-- =============================================================================

SELECT 'TEST 13: RECONCILIATION ENGINE' AS test_section;

DO $$
DECLARE
    v_result JSONB;
BEGIN
    v_result := public.run_reconciliation(CURRENT_DATE);

    IF (v_result->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 13: PASS — Reconciliation completed (passed=%, discrepancies=%).',
            v_result->>'passed', v_result->'discrepancies';
    ELSE
        RAISE NOTICE 'TEST 13: FAIL — Reconciliation engine failed: %', v_result->>'error';
    END IF;
END;
$$;


-- =============================================================================
-- SUMMARY
-- =============================================================================

SELECT '=== TRANSFER FLOW TESTS COMPLETE ===' AS summary;
SELECT 'Review notices output above. Next step: run tests/test_concurrency.sql' AS next_step;

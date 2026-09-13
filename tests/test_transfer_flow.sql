-- =============================================================================
-- TRANSFER FLOW FUNCTIONAL TESTS
-- File: tests/test_transfer_flow.sql
--
-- PURPOSE: Verify all core financial RPCs, fraud rules, idempotency,
--          standing orders, joint closure workflows, and reconciliation.
-- PREREQUISITE: Run seed_test_data.sql first.
-- RUN ENVIRONMENT: Supabase Cloud SQL Editor (postgres role).
-- =============================================================================

ALTER ROLE banking_functions BYPASSRLS;
GRANT USAGE ON SCHEMA auth TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.uid() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.role() TO banking_functions;
GRANT EXECUTE ON FUNCTION auth.jwt() TO banking_functions;

-- =============================================================================
-- CLEANUP BLOCK
-- Resets balances and clears test-specific records for repeatable execution.
-- =============================================================================
DO $$
BEGIN
    UPDATE public.accounts SET balance = 100000, status = 'active', updated_at = NOW()
    WHERE id = 'aa000000-0000-0000-0000-000000000001';
    UPDATE public.accounts SET balance = 50000, status = 'active', updated_at = NOW()
    WHERE id = 'bb000000-0000-0000-0000-000000000002';
    UPDATE public.accounts SET balance = 0, status = 'active', updated_at = NOW()
    WHERE id = 'cc000000-0000-0000-0000-000000000003';

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
    DELETE FROM public.fraud_assessments WHERE account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );
    DELETE FROM public.idempotency_keys WHERE key LIKE 'test-%' OR key LIKE 'so_%';
    DELETE FROM public.account_holds WHERE account_id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );

    RAISE NOTICE 'TRANSFER TEST CLEANUP: Done.';
END;
$$;

-- =============================================================================
-- TEST 0: VERIFY SEED DATA IS PRESENT
-- =============================================================================
SELECT 'TEST 0: SEED DATA PRESENT' AS test_section;
DO $$
DECLARE v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM public.accounts
    WHERE id IN (
        'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000002',
        'cc000000-0000-0000-0000-000000000003'
    );
    IF v_count = 3 THEN
        RAISE NOTICE 'TEST 0: PASS — Seed accounts found.';
    ELSE
        RAISE EXCEPTION 'TEST 0: FAIL — Seed accounts missing. Run seed_test_data.sql first.';
    END IF;
END;
$$;

-- =============================================================================
-- TEST 1: SUCCESSFUL TRANSFER (ATOMICITY & BALANCE MUTATION)
-- =============================================================================
SELECT 'TEST 1: SUCCESSFUL TRANSFER' AS test_section;
DO $$
DECLARE
    v_alice_id         UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id           UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID; v_result JSONB; v_tx_id UUID;
    v_alice_before BIGINT; v_alice_after BIGINT;
    v_bob_before BIGINT; v_bob_after BIGINT;
    v_debit_count INT; v_credit_count INT; v_audit_count INT; v_tx_count INT;
    v_idem_key TEXT := 'test-transfer-001-' || gen_random_uuid()::text;
BEGIN
    SELECT balance INTO v_alice_before FROM public.accounts WHERE id = v_alice_id;
    SELECT balance INTO v_bob_before   FROM public.accounts WHERE id = v_bob_id;

    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 1000, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, 1000, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    RAISE NOTICE 'TEST 1 result: %', v_result;

    IF NOT (v_result->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 1: FAIL — %', v_result->>'error'; RETURN;
    END IF;

    v_tx_id := (v_result->>'transaction_id')::UUID;
    SELECT COUNT(*) INTO v_tx_count    FROM public.transactions WHERE id = v_tx_id;
    SELECT COUNT(*) INTO v_debit_count FROM public.ledger_entries WHERE transaction_id = v_tx_id AND entry_type = 'debit';
    SELECT COUNT(*) INTO v_credit_count FROM public.ledger_entries WHERE transaction_id = v_tx_id AND entry_type = 'credit';
    SELECT balance INTO v_alice_after FROM public.accounts WHERE id = v_alice_id;
    SELECT balance INTO v_bob_after   FROM public.accounts WHERE id = v_bob_id;
    SELECT COUNT(*) INTO v_audit_count FROM public.audit_log WHERE event_type = 'transfer_completed' AND target_id = v_tx_id;

    IF v_tx_count = 1 AND v_debit_count = 1 AND v_credit_count = 1
       AND v_alice_after = v_alice_before - 1000
       AND v_bob_after   = v_bob_before   + 1000
       AND v_audit_count >= 1
    THEN
        RAISE NOTICE 'TEST 1: PASS — Transfer atomic. Alice % -> %, Bob % -> %.',
            v_alice_before, v_alice_after, v_bob_before, v_bob_after;
    ELSE
        RAISE NOTICE 'TEST 1: FAIL — Verification mismatch.';
    END IF;
END;
$$;

-- =============================================================================
-- TEST 2: IDEMPOTENCY REPLAY
-- =============================================================================
SELECT 'TEST 2: IDEMPOTENCY REPLAY' AS test_section;
DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID; v_result1 JSONB; v_result2 JSONB;
    v_bal_after_first BIGINT; v_bal_after_second BIGINT;
    v_idem_key TEXT := 'test-idem-replay-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 500, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result1 := public.execute_transfer(v_alice_id, v_bob_id, 500, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    SELECT balance INTO v_bal_after_first FROM public.accounts WHERE id = v_alice_id;

    v_result2 := public.execute_transfer(v_alice_id, v_bob_id, 500, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    SELECT balance INTO v_bal_after_second FROM public.accounts WHERE id = v_alice_id;

    IF (v_result1->>'success')::BOOLEAN
       AND (v_result2->>'success')::BOOLEAN
       AND v_result1->>'transaction_id' = v_result2->>'transaction_id'
       AND v_bal_after_first = v_bal_after_second
    THEN
        RAISE NOTICE 'TEST 2: PASS — Idempotency replay returned cached response without double-debit.';
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
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id_1 UUID; v_fraud_id_2 UUID;
    v_result1 JSONB; v_result2 JSONB;
    v_idem_key TEXT := 'test-idem-mismatch-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 200, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id_1;
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 300, 5.0, TRUE, 'Low risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id_2;

    v_result1 := public.execute_transfer(v_alice_id, v_bob_id, 200, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id_1);
    v_result2 := public.execute_transfer(v_alice_id, v_bob_id, 300, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id_2);

    IF (v_result1->>'success')::BOOLEAN
       AND NOT (v_result2->>'success')::BOOLEAN
       AND v_result2->>'error' LIKE '%different parameters%'
    THEN
        RAISE NOTICE 'TEST 3: PASS — Reused key with different parameters rejected.';
    ELSE
        RAISE NOTICE 'TEST 3: FAIL — result1=%, result2=%', v_result1, v_result2;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 4: INSUFFICIENT FUNDS ROLLBACK
-- =============================================================================
SELECT 'TEST 4: INSUFFICIENT FUNDS ROLLBACK' AS test_section;
DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID; v_result JSONB;
    v_bal_before BIGINT; v_bal_after BIGINT;
    v_massive BIGINT := 999999999999;
    v_idem_key TEXT := 'test-insufficient-' || gen_random_uuid()::text;
BEGIN
    SELECT balance INTO v_bal_before FROM public.accounts WHERE id = v_alice_id;

    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, v_massive, 5.0, TRUE, 'Test', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, v_massive, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);
    SELECT balance INTO v_bal_after FROM public.accounts WHERE id = v_alice_id;

    IF NOT (v_result->>'success')::BOOLEAN AND v_bal_before = v_bal_after THEN
        RAISE NOTICE 'TEST 4: PASS — Insufficient funds rejected, balance unchanged.';
    ELSE
        RAISE NOTICE 'TEST 4: FAIL — result=%, before=%, after=%', v_result, v_bal_before, v_bal_after;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 5: RETRY WITH NEW KEY AFTER FAILURE
-- =============================================================================
SELECT 'TEST 5: RETRY WITH NEW KEY' AS test_section;
DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_fail UUID; v_fraud_ok UUID;
    v_result_fail JSONB; v_result_ok JSONB;
    v_key_fail TEXT := 'test-retry-fail-' || gen_random_uuid()::text;
    v_key_ok   TEXT := 'test-retry-ok-'   || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 999999999, 5.0, TRUE, 'Fail', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_fail;
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 100, 5.0, TRUE, 'OK', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_ok;

    v_result_fail := public.execute_transfer(v_alice_id, v_bob_id, 999999999, 'USD', v_key_fail, v_alice_profile_id, v_fraud_fail);
    v_result_ok   := public.execute_transfer(v_alice_id, v_bob_id, 100,       'USD', v_key_ok,   v_alice_profile_id, v_fraud_ok);

    IF NOT (v_result_fail->>'success')::BOOLEAN AND (v_result_ok->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 5: PASS — Retry with new key succeeded after failed attempt.';
    ELSE
        RAISE NOTICE 'TEST 5: FAIL — fail=%, ok=%', v_result_fail, v_result_ok;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 6: EXPIRED FRAUD ASSESSMENT REJECTED
-- =============================================================================
SELECT 'TEST 6: EXPIRED FRAUD ASSESSMENT' AS test_section;
DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID; v_result JSONB;
    v_idem_key TEXT := 'test-fraud-expired-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 100, 5.0, TRUE, 'Low risk', FALSE, NOW() - INTERVAL '1 minute')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, 100, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);

    IF NOT (v_result->>'success')::BOOLEAN AND v_result->>'error' LIKE '%expired%' THEN
        RAISE NOTICE 'TEST 6: PASS — Expired fraud assessment rejected.';
    ELSE
        RAISE NOTICE 'TEST 6: FAIL — %', v_result;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 7: UNAPPROVED FRAUD ASSESSMENT REJECTED
-- =============================================================================
SELECT 'TEST 7: UNAPPROVED FRAUD ASSESSMENT' AS test_section;
DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID; v_result JSONB;
    v_idem_key TEXT := 'test-fraud-denied-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO public.fraud_assessments (account_id, amount, risk_score, approved, reason, consumed, expires_at)
    VALUES (v_alice_id, 100, 85.0, FALSE, 'High risk', FALSE, NOW() + INTERVAL '10 minutes')
    RETURNING id INTO v_fraud_id;

    v_result := public.execute_transfer(v_alice_id, v_bob_id, 100, 'USD', v_idem_key, v_alice_profile_id, v_fraud_id);

    IF NOT (v_result->>'success')::BOOLEAN AND v_result->>'error' LIKE '%NOT approved%' THEN
        RAISE NOTICE 'TEST 7: PASS — Unapproved fraud assessment rejected.';
    ELSE
        RAISE NOTICE 'TEST 7: FAIL — %', v_result;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 8: FRAUD ASSESSMENT CONSUMED ONLY ONCE
-- =============================================================================
SELECT 'TEST 8: FRAUD ASSESSMENT CONSUMED ONCE' AS test_section;
DO $$
DECLARE
    v_alice_id UUID := 'aa000000-0000-0000-0000-000000000001';
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_alice_profile_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_fraud_id UUID; v_result1 JSONB; v_result2 JSONB;
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
        RAISE NOTICE 'TEST 8: PASS — Fraud assessment reuse rejected.';
    ELSE
        RAISE NOTICE 'TEST 8: FAIL — result1=%, result2=%', v_result1, v_result2;
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
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_order_id UUID; v_result JSONB;
    v_bal_before BIGINT; v_bal_after BIGINT;
BEGIN
    SELECT balance INTO v_bal_before FROM public.accounts WHERE id = v_alice_id;

    INSERT INTO public.standing_orders (source_account_id, destination_account_id, amount, currency, frequency, next_execution_at, status, retry_count)
    VALUES (v_alice_id, v_bob_id, 250, 'USD', 'monthly', NOW() - INTERVAL '1 hour', 'active', 0)
    RETURNING id INTO v_order_id;

    v_result := public.execute_standing_order(v_order_id);
    SELECT balance INTO v_bal_after FROM public.accounts WHERE id = v_alice_id;

    IF (v_result->>'success')::BOOLEAN AND v_bal_after = v_bal_before - 250 THEN
        RAISE NOTICE 'TEST 9: PASS — Standing order executed. Balance % -> %.', v_bal_before, v_bal_after;
    ELSE
        RAISE NOTICE 'TEST 9: FAIL — result=%, before=%, after=%', v_result, v_bal_before, v_bal_after;
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
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_order_id UUID; v_result1 JSONB; v_result2 JSONB;
    v_bal_before BIGINT; v_bal_after BIGINT;
BEGIN
    SELECT balance INTO v_bal_before FROM public.accounts WHERE id = v_alice_id;

    INSERT INTO public.standing_orders (source_account_id, destination_account_id, amount, currency, frequency, next_execution_at, status, retry_count)
    VALUES (v_alice_id, v_bob_id, 150, 'USD', 'daily', NOW() - INTERVAL '2 hours', 'active', 0)
    RETURNING id INTO v_order_id;

    v_result1 := public.execute_standing_order(v_order_id);
    -- After first execution, next_execution_at is advanced by 1 day (future), so second call fails with "not due yet"
    v_result2 := public.execute_standing_order(v_order_id);
    SELECT balance INTO v_bal_after FROM public.accounts WHERE id = v_alice_id;

    IF (v_result1->>'success')::BOOLEAN
       AND NOT (v_result2->>'success')::BOOLEAN
       AND v_result2->>'error' LIKE '%not due yet%'
       AND v_bal_after = v_bal_before - 150
    THEN
        RAISE NOTICE 'TEST 10: PASS — Duplicate standing order execution prevented.';
    ELSE
        RAISE NOTICE 'TEST 10: FAIL — result1=%, result2=%', v_result1, v_result2;
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
    v_bob_id   UUID := 'bb000000-0000-0000-0000-000000000002';
    v_order_id UUID; v_result JSONB;
    v_retry_count INT; v_status TEXT;
BEGIN
    INSERT INTO public.standing_orders (source_account_id, destination_account_id, amount, currency, frequency, next_execution_at, status, retry_count)
    VALUES (v_alice_id, v_bob_id, 999999999999, 'USD', 'daily', NOW() - INTERVAL '1 hour', 'active', 0)
    RETURNING id INTO v_order_id;

    -- Attempt 1
    v_result := public.execute_standing_order(v_order_id);
    UPDATE public.standing_orders SET next_execution_at = NOW() - INTERVAL '1 hour', execution_locked_at = NULL WHERE id = v_order_id;
    DELETE FROM public.idempotency_keys WHERE key LIKE 'so_' || v_order_id::text || '%';

    -- Attempt 2
    v_result := public.execute_standing_order(v_order_id);
    UPDATE public.standing_orders SET next_execution_at = NOW() - INTERVAL '1 hour', execution_locked_at = NULL WHERE id = v_order_id;
    DELETE FROM public.idempotency_keys WHERE key LIKE 'so_' || v_order_id::text || '%';

    -- Attempt 3 (triggers permanent failure)
    v_result := public.execute_standing_order(v_order_id);

    SELECT retry_count, status INTO v_retry_count, v_status FROM public.standing_orders WHERE id = v_order_id;

    IF v_retry_count = 3 AND v_status = 'failed' THEN
        RAISE NOTICE 'TEST 11: PASS — retry_count=3, status=failed.';
    ELSE
        RAISE NOTICE 'TEST 11: FAIL — retry_count=%, status=%', v_retry_count, v_status;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 12: JOINT ACCOUNT CLOSURE WORKFLOW
-- =============================================================================
SELECT 'TEST 12: JOINT ACCOUNT CLOSURE WORKFLOW' AS test_section;
DO $$
DECLARE
    v_joint_id           UUID := 'cc000000-0000-0000-0000-000000000003';
    v_alice_profile_id   UUID := 'a0000000-0000-0000-0000-000000000001';
    v_charlie_profile_id UUID := 'c0000000-0000-0000-0000-000000000003';
    v_action_id UUID; v_result1 JSONB; v_result2 JSONB;
    v_action_status TEXT; v_account_status TEXT;
BEGIN
    -- Ensure joint account is active with zero balance
    UPDATE public.accounts SET status = 'active', balance = 0, updated_at = NOW() WHERE id = v_joint_id;

    v_result1 := public.request_joint_closure(v_joint_id, v_alice_profile_id);
    v_action_id := (v_result1->>'joint_action_id')::UUID;

    v_result2 := public.record_joint_consent(v_action_id, v_charlie_profile_id, TRUE);

    SELECT status INTO v_action_status  FROM public.joint_account_actions WHERE id = v_action_id;
    SELECT status INTO v_account_status FROM public.accounts WHERE id = v_joint_id;

    IF (v_result1->>'status') = 'pending'
       AND v_action_status = 'approved'
       AND v_account_status = 'closed'
    THEN
        RAISE NOTICE 'TEST 12: PASS — Joint closure approved after both holders consented.';
    ELSE
        RAISE NOTICE 'TEST 12: FAIL — result1=%, result2=%, action=%, account=%',
            v_result1, v_result2, v_action_status, v_account_status;
    END IF;
END;
$$;

-- =============================================================================
-- TEST 13: RECONCILIATION ENGINE
-- =============================================================================
SELECT 'TEST 13: RECONCILIATION ENGINE' AS test_section;
DO $$
DECLARE v_result JSONB;
BEGIN
    v_result := public.run_reconciliation(CURRENT_DATE);
    IF (v_result->>'success')::BOOLEAN THEN
        RAISE NOTICE 'TEST 13: PASS — Reconciliation ran (passed=%, discrepancies=%)',
            v_result->>'passed', v_result->'discrepancies';
    ELSE
        RAISE NOTICE 'TEST 13: FAIL — %', v_result->>'error';
    END IF;
END;
$$;

SELECT '=== TRANSFER FLOW TESTS COMPLETE ===' AS summary;
SELECT 'Review notices above. Next: run tests/test_concurrency.sql' AS next_step;

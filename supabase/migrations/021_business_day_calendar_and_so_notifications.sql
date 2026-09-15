-- 021: standing order scheduling against a real business-day calendar (brief #15),
-- and giving execute_standing_order() enough context for the CUSTOMER to be told
-- when their recurring payment dies for good (brief #17 -- only ops was told).
--
-- Weekends were already handled inline. Holidays were not: there was no calendar
-- at all, so a payment due on Independence Day was simply processed on the day.

CREATE TABLE IF NOT EXISTS public.bank_holidays (
    holiday_date DATE PRIMARY KEY,
    name         TEXT NOT NULL,
    is_estimated BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.bank_holidays ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bank_holidays_deny_anon ON public.bank_holidays;
CREATE POLICY bank_holidays_deny_anon ON public.bank_holidays
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- Pakistan public holidays. The fixed-date national holidays are exact. The
-- Islamic-calendar holidays are lunar and their Gregorian dates are announced
-- close to the day, so they are flagged is_estimated = true and must be
-- confirmed and corrected each year rather than trusted blindly.
INSERT INTO public.bank_holidays (holiday_date, name, is_estimated) VALUES
    ('2026-02-05', 'Kashmir Solidarity Day', FALSE),
    ('2026-03-23', 'Pakistan Day', FALSE),
    ('2026-05-01', 'Labour Day', FALSE),
    ('2026-08-14', 'Independence Day', FALSE),
    ('2026-11-09', 'Iqbal Day', FALSE),
    ('2026-12-25', 'Quaid-e-Azam Day', FALSE),
    ('2026-03-20', 'Eid al-Fitr (estimated)', TRUE),
    ('2026-03-21', 'Eid al-Fitr (estimated)', TRUE),
    ('2026-03-22', 'Eid al-Fitr (estimated)', TRUE),
    ('2026-05-27', 'Eid al-Adha (estimated)', TRUE),
    ('2026-05-28', 'Eid al-Adha (estimated)', TRUE),
    ('2026-05-29', 'Eid al-Adha (estimated)', TRUE),
    ('2026-06-25', 'Ashura (estimated)', TRUE),
    ('2026-06-26', 'Ashura (estimated)', TRUE),
    ('2026-08-25', 'Eid Milad un-Nabi (estimated)', TRUE),
    ('2027-02-05', 'Kashmir Solidarity Day', FALSE),
    ('2027-03-23', 'Pakistan Day', FALSE),
    ('2027-05-01', 'Labour Day', FALSE),
    ('2027-08-14', 'Independence Day', FALSE),
    ('2027-11-09', 'Iqbal Day', FALSE),
    ('2027-12-25', 'Quaid-e-Azam Day', FALSE)
ON CONFLICT (holiday_date) DO NOTHING;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_business_day(p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
    SELECT EXTRACT(DOW FROM p_date) NOT IN (0, 6)
       AND NOT EXISTS (SELECT 1 FROM public.bank_holidays WHERE holiday_date = p_date);
$$;

CREATE OR REPLACE FUNCTION public.adjust_for_business_day(
    p_ts TIMESTAMPTZ, p_rule TEXT
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_ts TIMESTAMPTZ := p_ts;
    v_guard INT := 0;
BEGIN
    -- 'allow_weekend' means settle on the calendar date whatever it is. This
    -- system settles instantly and internally, so that is a legitimate choice
    -- rather than a bug -- there is no interbank window to miss.
    IF p_rule IS NULL OR p_rule = 'allow_weekend' THEN
        RETURN v_ts;
    END IF;

    WHILE NOT public.is_business_day(v_ts::DATE) LOOP
        v_guard := v_guard + 1;
        -- A run of more than a fortnight of non-business days means the holiday
        -- table is wrong; stop rather than loop forever.
        IF v_guard > 14 THEN
            RETURN p_ts;
        END IF;

        IF p_rule = 'process_early' THEN
            v_ts := v_ts - INTERVAL '1 day';
        ELSE
            v_ts := v_ts + INTERVAL '1 day';
        END IF;
    END LOOP;

    RETURN v_ts;
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.execute_standing_order(p_standing_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_order public.standing_orders%ROWTYPE;
    v_transaction_id UUID;
    v_next_exec TIMESTAMPTZ;
    v_idempotency_key TEXT;
    v_existing_key public.idempotency_keys%ROWTYPE;
    v_err_msg TEXT;
    v_loan_outstanding BIGINT;
    v_new_status TEXT;
    v_src_number TEXT;
    v_dst_number TEXT;
    v_holder_emails TEXT[];
    v_is_loan BOOLEAN;
BEGIN
    SELECT * INTO v_order FROM public.standing_orders
    WHERE id = p_standing_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order not found',
                                  'standing_order_id', p_standing_order_id);
    END IF;

    IF v_order.execution_locked_at IS NOT NULL
       AND v_order.execution_locked_at > NOW() - INTERVAL '10 minutes' THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Standing order is locked by active worker',
            'standing_order_id', p_standing_order_id,
            'locked_at', v_order.execution_locked_at);
    END IF;

    IF v_order.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order is not active',
                                  'status', v_order.status);
    END IF;

    IF v_order.next_execution_at > NOW() THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order is not due yet',
                                  'next_execution_at', v_order.next_execution_at);
    END IF;

    -- Context gathered up front so it is available to BOTH the success and the
    -- failure return. WF-02 cannot email the customer about a dead standing
    -- order if the RPC only tells it that something failed.
    SELECT account_number INTO v_src_number FROM public.accounts WHERE id = v_order.source_account_id;
    SELECT account_number INTO v_dst_number FROM public.accounts WHERE id = v_order.destination_account_id;
    SELECT array_agg(p.email ORDER BY p.email) INTO v_holder_emails
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = v_order.source_account_id;
    v_is_loan := v_order.loan_id IS NOT NULL;

    v_idempotency_key := 'so_' || p_standing_order_id::text || '_' ||
                         EXTRACT(EPOCH FROM v_order.next_execution_at)::text;

    SELECT * INTO v_existing_key FROM public.idempotency_keys
    WHERE key = v_idempotency_key FOR UPDATE;

    IF FOUND THEN
        IF v_existing_key.status = 'completed' THEN
            IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
            ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
            ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
            END IF;
            v_next_exec := public.adjust_for_business_day(v_next_exec, v_order.weekend_holiday_rule);

            UPDATE public.standing_orders
            SET next_execution_at = v_next_exec, execution_locked_at = NULL
            WHERE id = p_standing_order_id;

            RETURN jsonb_build_object('success', true,
                'message', 'Standing order already executed for scheduled timestamp',
                'standing_order_id', p_standing_order_id, 'next_execution_at', v_next_exec);
        ELSIF v_existing_key.status = 'processing' THEN
            IF v_existing_key.locked_at > NOW() - INTERVAL '5 minutes' THEN
                RETURN jsonb_build_object('success', false,
                    'error', 'Standing order execution already in progress by another worker',
                    'standing_order_id', p_standing_order_id);
            ELSE
                UPDATE public.idempotency_keys SET locked_at = NOW() WHERE key = v_idempotency_key;
            END IF;
        END IF;
    ELSE
        INSERT INTO public.idempotency_keys (key, request_hash, status, locked_at)
        VALUES (v_idempotency_key, MD5(v_idempotency_key), 'processing', NOW());
    END IF;

    UPDATE public.standing_orders SET execution_locked_at = NOW() WHERE id = p_standing_order_id;

    BEGIN
        v_transaction_id := public.process_money_movement(
            v_order.source_account_id, v_order.destination_account_id,
            v_order.amount, v_order.currency,
            'Recurring standing order payment', NULL
        );

        UPDATE public.idempotency_keys
        SET status = 'completed', transaction_id = v_transaction_id,
            response_body = jsonb_build_object('success', true, 'transaction_id', v_transaction_id)
        WHERE key = v_idempotency_key;

        IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
        ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
        ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
        END IF;
        v_next_exec := public.adjust_for_business_day(v_next_exec, v_order.weekend_holiday_rule);

        UPDATE public.standing_orders
        SET next_execution_at = v_next_exec, execution_locked_at = NULL,
            retry_count = 0, last_error = NULL, updated_at = NOW()
        WHERE id = p_standing_order_id;

        IF v_order.loan_id IS NOT NULL THEN
            UPDATE public.loans
            SET outstanding_balance = GREATEST(outstanding_balance - v_order.amount, 0), updated_at = NOW()
            WHERE id = v_order.loan_id
            RETURNING outstanding_balance INTO v_loan_outstanding;

            IF v_loan_outstanding <= 0 THEN
                UPDATE public.loans SET status = 'paid_off', updated_at = NOW() WHERE id = v_order.loan_id;
                UPDATE public.standing_orders SET status = 'cancelled', updated_at = NOW()
                WHERE id = p_standing_order_id;
                PERFORM public.write_audit_log('loan_paid_off', 'system', NULL, 'loan', v_order.loan_id,
                    jsonb_build_object('standing_order_id', p_standing_order_id));
            END IF;
        END IF;

        PERFORM public.write_audit_log(
            'standing_order_executed', 'system', NULL, 'standing_order', p_standing_order_id,
            jsonb_build_object('transaction_id', v_transaction_id, 'next_execution_at', v_next_exec));

        RETURN jsonb_build_object('success', true,
            'standing_order_id', p_standing_order_id, 'transaction_id', v_transaction_id,
            'next_execution_at', v_next_exec, 'amount', v_order.amount,
            'currency', v_order.currency,
            'source_account_number', v_src_number, 'destination_account_number', v_dst_number,
            'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
            'loan_repayment', v_is_loan,
            'loan_outstanding', v_loan_outstanding);

    EXCEPTION WHEN OTHERS THEN
        v_err_msg := SQLERRM;
        v_new_status := CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END;

        UPDATE public.idempotency_keys
        SET status = 'failed',
            response_body = jsonb_build_object('success', false, 'error', v_err_msg)
        WHERE key = v_idempotency_key;

        UPDATE public.standing_orders
        SET retry_count = v_order.retry_count + 1, last_error = v_err_msg,
            status = v_new_status, execution_locked_at = NULL, updated_at = NOW()
        WHERE id = p_standing_order_id;

        PERFORM public.write_audit_log(
            'standing_order_failed', 'system', NULL, 'standing_order', p_standing_order_id,
            jsonb_build_object('reason', v_err_msg, 'retry_count', v_order.retry_count + 1,
                               'status', v_new_status));

        RETURN jsonb_build_object('success', false, 'error', v_err_msg,
            'standing_order_id', p_standing_order_id,
            'retry_count', v_order.retry_count + 1,
            'max_retries', 3,
            'status', v_new_status,
            'permanently_failed', v_new_status = 'failed',
            'amount', v_order.amount, 'currency', v_order.currency,
            'frequency', v_order.frequency,
            'source_account_number', v_src_number, 'destination_account_number', v_dst_number,
            'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
            'loan_repayment', v_is_loan);
    END;
END;
$$;

ALTER FUNCTION public.is_business_day(DATE) OWNER TO banking_functions;
ALTER FUNCTION public.adjust_for_business_day(TIMESTAMPTZ, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.execute_standing_order(uuid) OWNER TO banking_functions;
GRANT EXECUTE ON FUNCTION public.is_business_day(DATE) TO service_role;
GRANT EXECUTE ON FUNCTION public.adjust_for_business_day(TIMESTAMPTZ, TEXT) TO service_role;

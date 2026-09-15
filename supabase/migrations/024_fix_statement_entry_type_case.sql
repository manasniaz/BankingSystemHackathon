-- 024: fixes 022. ledger_entries.entry_type is stored lower case ('credit' /
-- 'debit'), but generate_account_statement() compared against 'CREDIT' / 'DEBIT',
-- so every statement reported total_credits = 0 and total_debits = 0 while still
-- listing the correct entries underneath -- a statement that looks populated but
-- whose totals are silently always zero. Comparison is now case-insensitive.
--
-- Caught by generating a statement for a real account and noticing entry_count
-- was 3 while both totals were 0. Nothing about the output looked malformed;
-- only the arithmetic gave it away, which is why the Python side now asserts
-- opening + credits - debits = closing before a statement is ever emailed.

CREATE OR REPLACE FUNCTION public.generate_account_statement(
    p_account_id uuid, p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_from DATE := COALESCE(p_from, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);
    v_to   DATE := COALESCE(p_to, (date_trunc('month', CURRENT_DATE)::DATE - 1));
    v_opening BIGINT;
    v_closing BIGINT;
    v_credits BIGINT;
    v_debits BIGINT;
    v_count INT;
    v_lines JSONB;
    v_holders TEXT[];
    v_debt BIGINT;
BEGIN
    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF v_to < v_from THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The statement end date cannot be before the start date.');
    END IF;

    SELECT balance_after INTO v_opening
    FROM public.ledger_entries
    WHERE account_id = p_account_id AND created_at < v_from::timestamptz
    ORDER BY created_at DESC, id DESC
    LIMIT 1;
    v_opening := COALESCE(v_opening, 0);

    SELECT balance_after INTO v_closing
    FROM public.ledger_entries
    WHERE account_id = p_account_id AND created_at < (v_to + 1)::timestamptz
    ORDER BY created_at DESC, id DESC
    LIMIT 1;
    v_closing := COALESCE(v_closing, v_opening);

    SELECT
        COALESCE(SUM(CASE WHEN UPPER(le.entry_type) = 'CREDIT' THEN le.amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN UPPER(le.entry_type) = 'DEBIT'  THEN le.amount ELSE 0 END), 0),
        COUNT(*)
    INTO v_credits, v_debits, v_count
    FROM public.ledger_entries le
    WHERE le.account_id = p_account_id
      AND le.created_at >= v_from::timestamptz
      AND le.created_at < (v_to + 1)::timestamptz;

    SELECT COALESCE(jsonb_agg(line ORDER BY line ->> 'posted_at'), '[]'::jsonb)
    INTO v_lines
    FROM (
        SELECT jsonb_build_object(
            'posted_at', le.created_at,
            'entry_type', UPPER(le.entry_type),
            'amount', le.amount,
            'balance_after', le.balance_after,
            'description', COALESCE(t.description, 'Transaction'),
            'counterparty', CASE
                WHEN UPPER(le.entry_type) = 'DEBIT' THEN dst.account_number
                ELSE src.account_number END,
            'transaction_id', le.transaction_id,
            'status', t.status
        ) AS line
        FROM public.ledger_entries le
        LEFT JOIN public.transactions t ON t.id = le.transaction_id
        LEFT JOIN public.accounts src ON src.id = t.source_account_id
        LEFT JOIN public.accounts dst ON dst.id = t.destination_account_id
        WHERE le.account_id = p_account_id
          AND le.created_at >= v_from::timestamptz
          AND le.created_at < (v_to + 1)::timestamptz
    ) s;

    SELECT array_agg(p.email ORDER BY p.email) INTO v_holders
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id;

    SELECT COALESCE(SUM(amount_outstanding), 0) INTO v_debt
    FROM public.account_debts WHERE account_id = p_account_id AND status = 'outstanding';

    RETURN jsonb_build_object(
        'success', true,
        'account_id', p_account_id,
        'account_number', v_account.account_number,
        'account_type', v_account.account_type,
        'currency', v_account.currency,
        'status', v_account.status,
        'period_start', v_from,
        'period_end', v_to,
        'opening_balance', v_opening,
        'closing_balance', v_closing,
        'total_credits', v_credits,
        'total_debits', v_debits,
        'entry_count', v_count,
        'current_balance', v_account.balance,
        'outstanding_debt', v_debt,
        'holder_emails', to_jsonb(COALESCE(v_holders, ARRAY[]::TEXT[])),
        'entries', v_lines
    );
END;
$$;

ALTER FUNCTION public.generate_account_statement(uuid, DATE, DATE) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.generate_account_statement(uuid, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_account_statement(uuid, DATE, DATE) TO service_role;

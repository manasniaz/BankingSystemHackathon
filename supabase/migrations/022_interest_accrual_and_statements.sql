-- 022: interest accrual and account statements -- the two halves of the brief's
-- "Interest, Statements & Reconciliation" domain that were never built (only the
-- reconciliation third existed).
--
-- Interest is paid out of TREASURY-MAIN through the same double-entry primitive
-- as every other movement, so interest income shows up in the ledger and in the
-- nightly reconciliation rather than being conjured into a balance.
--
-- NOTE: generate_account_statement() here compares entry_type against uppercase
-- 'CREDIT'/'DEBIT' while the ledger stores them lowercase, so its totals always
-- come back zero. Fixed in 024. Kept as applied.

CREATE TABLE IF NOT EXISTS public.interest_rates (
    account_type    TEXT PRIMARY KEY,
    annual_rate_pct NUMERIC(5,2) NOT NULL CHECK (annual_rate_pct >= 0),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.interest_rates (account_type, annual_rate_pct) VALUES
    ('savings', 5.00),
    ('checking', 0.00),
    ('business', 0.00)
ON CONFLICT (account_type) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.interest_accruals (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      UUID NOT NULL REFERENCES public.accounts(id),
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    annual_rate_pct NUMERIC(5,2) NOT NULL,
    balance_basis   BIGINT NOT NULL,
    interest_amount BIGINT NOT NULL CHECK (interest_amount >= 0),
    transaction_id  UUID REFERENCES public.transactions(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- One accrual per account per period. This is what makes a re-run safe:
    -- running the monthly job twice cannot pay interest twice.
    CONSTRAINT interest_accruals_unique_period UNIQUE (account_id, period_start)
);

CREATE INDEX IF NOT EXISTS idx_interest_accruals_account
    ON public.interest_accruals (account_id, period_start DESC);

ALTER TABLE public.interest_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.interest_accruals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS interest_rates_deny_anon ON public.interest_rates;
CREATE POLICY interest_rates_deny_anon ON public.interest_rates
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS interest_accruals_deny_anon ON public.interest_accruals;
CREATE POLICY interest_accruals_deny_anon ON public.interest_accruals
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accrue_monthly_interest(p_as_of DATE DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_as_of DATE := COALESCE(p_as_of, CURRENT_DATE);
    v_period_start DATE;
    v_period_end DATE;
    v_treasury UUID;
    v_row RECORD;
    v_interest BIGINT;
    v_tx UUID;
    v_paid INT := 0;
    v_skipped INT := 0;
    v_total BIGINT := 0;
    v_details JSONB := '[]'::jsonb;
BEGIN
    -- Interest is always accrued for the month that has fully elapsed, never
    -- the month in progress, so a mid-month run cannot pay a partial month as
    -- if it were whole.
    v_period_start := date_trunc('month', v_as_of - INTERVAL '1 month')::DATE;
    v_period_end   := (date_trunc('month', v_as_of)::DATE - 1);

    SELECT id INTO v_treasury FROM public.accounts WHERE account_number = 'TREASURY-MAIN';
    IF v_treasury IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Treasury account not found');
    END IF;

    FOR v_row IN
        SELECT a.id, a.account_number, a.balance, a.currency, a.account_type,
               r.annual_rate_pct
        FROM public.accounts a
        JOIN public.interest_rates r ON r.account_type = a.account_type
        WHERE a.status = 'active'
          AND a.balance > 0
          AND r.annual_rate_pct > 0
          AND a.account_number <> 'TREASURY-MAIN'
        ORDER BY a.account_number
    LOOP
        -- Already paid for this period? Skip. The unique constraint is the
        -- real guarantee; this just avoids a pointless failed insert.
        IF EXISTS (SELECT 1 FROM public.interest_accruals
                   WHERE account_id = v_row.id AND period_start = v_period_start) THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        -- Closing balance as the basis, floor-rounded. Rounding down means the
        -- bank never pays a paisa it did not compute, which is the safe
        -- direction for an automated credit.
        v_interest := FLOOR(v_row.balance * (v_row.annual_rate_pct / 100.0) / 12.0);

        IF v_interest <= 0 THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_tx := public.process_money_movement(
            v_treasury, v_row.id, v_interest, v_row.currency,
            'Monthly interest for ' || to_char(v_period_start, 'Mon YYYY'), NULL
        );

        INSERT INTO public.interest_accruals (
            account_id, period_start, period_end, annual_rate_pct,
            balance_basis, interest_amount, transaction_id
        ) VALUES (
            v_row.id, v_period_start, v_period_end, v_row.annual_rate_pct,
            v_row.balance, v_interest, v_tx
        );

        PERFORM public.write_audit_log(
            'interest_accrued', 'system', NULL, 'account', v_row.id,
            jsonb_build_object('period_start', v_period_start, 'period_end', v_period_end,
                               'rate_pct', v_row.annual_rate_pct,
                               'balance_basis', v_row.balance,
                               'interest_amount', v_interest, 'transaction_id', v_tx)
        );

        v_paid := v_paid + 1;
        v_total := v_total + v_interest;
        v_details := v_details || jsonb_build_object(
            'account_number', v_row.account_number, 'account_id', v_row.id,
            'interest_amount', v_interest, 'rate_pct', v_row.annual_rate_pct);
    END LOOP;

    RETURN jsonb_build_object('success', true,
        'period_start', v_period_start, 'period_end', v_period_end,
        'accounts_paid', v_paid, 'accounts_skipped', v_skipped,
        'total_interest', v_total, 'details', v_details);
END;
$$;

-- ---------------------------------------------------------------------------
-- Statements. Opening balance is derived from the ledger itself (the
-- balance_after of the last entry before the window) rather than from any
-- cached figure, so a statement is reconstructable from the ledger alone.

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
        COALESCE(SUM(CASE WHEN le.entry_type = 'CREDIT' THEN le.amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN le.entry_type = 'DEBIT'  THEN le.amount ELSE 0 END), 0),
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
            'entry_type', le.entry_type,
            'amount', le.amount,
            'balance_after', le.balance_after,
            'description', COALESCE(t.description, 'Transaction'),
            'counterparty', CASE
                WHEN le.entry_type = 'DEBIT' THEN dst.account_number
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

ALTER FUNCTION public.accrue_monthly_interest(DATE) OWNER TO banking_functions;
ALTER FUNCTION public.generate_account_statement(uuid, DATE, DATE) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.accrue_monthly_interest(DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_account_statement(uuid, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accrue_monthly_interest(DATE) TO service_role;
GRANT EXECUTE ON FUNCTION public.generate_account_statement(uuid, DATE, DATE) TO service_role;

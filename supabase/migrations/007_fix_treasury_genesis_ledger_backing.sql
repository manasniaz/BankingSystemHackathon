-- Migration 007: fix a real bug in migration 006.
--
-- Migration 006 funded TREASURY-MAIN by directly setting accounts.balance to
-- 50,000,000,000 via a raw INSERT, with no backing ledger_entries. That is
-- exactly the "magic balance mutation" that migration's own comment said it
-- was avoiding -- caught immediately by run_reconciliation, which failed with
-- a 50,000,000,000 discrepancy on TREASURY-MAIN (its cached balance had no
-- ledger entries to sum to). Fixed properly: a genesis transaction crediting
-- treasury from a new BANK-CAPITAL account (status 'closed' from creation --
-- reconciliation's per-account check only examines 'active'/'frozen'
-- accounts, so a permanently-closed notional capital account is the correct,
-- schema-consistent place for the one-time offsetting debit a real balance
-- sheet would also carry as paid-in capital).

INSERT INTO public.accounts (account_number, account_type, currency, balance, status)
SELECT 'BANK-CAPITAL', 'treasury', 'PKR', 0, 'closed'
WHERE NOT EXISTS (SELECT 1 FROM public.accounts WHERE account_number = 'BANK-CAPITAL');

DO $$
DECLARE
    v_capital_id UUID;
    v_treasury_id UUID;
    v_genesis_amount BIGINT := 50000000000;
    v_transaction_id UUID;
BEGIN
    SELECT id INTO v_capital_id FROM public.accounts WHERE account_number = 'BANK-CAPITAL';
    SELECT id INTO v_treasury_id FROM public.accounts WHERE account_number = 'TREASURY-MAIN';

    -- Only backfill once: skip if a genesis transaction already exists.
    IF NOT EXISTS (
        SELECT 1 FROM public.transactions
        WHERE source_account_id = v_capital_id AND destination_account_id = v_treasury_id
    ) THEN
        INSERT INTO public.transactions (source_account_id, destination_account_id, amount, currency, status, description)
        VALUES (v_capital_id, v_treasury_id, v_genesis_amount, 'PKR', 'completed', 'Initial bank capital funding')
        RETURNING id INTO v_transaction_id;

        INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
        VALUES (v_transaction_id, v_capital_id, 'debit', v_genesis_amount, 0);

        INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
        VALUES (v_transaction_id, v_treasury_id, 'credit', v_genesis_amount, v_genesis_amount);

        PERFORM public.write_audit_log(
            'bank_capital_genesis_funding', 'admin', NULL, 'account', v_treasury_id,
            jsonb_build_object('amount', v_genesis_amount, 'transaction_id', v_transaction_id)
        );
    END IF;
END;
$$;

-- 033_accounts_are_pkr_only.sql
--
-- WF-00's "Open Additional Account for Existing Customer" node hardcoded
-- `"p_currency": "USD"` -- a leftover from before migration 005 converted this
-- bank to PKR. The new-customer path was updated at the time; this one was
-- missed, and nothing caught it because `accounts.currency` had no constraint.
--
-- The result: an existing customer who opened a second account got a USD
-- account at a PKR-only bank. It could never send or receive anything --
-- process_money_movement() refuses a currency mismatch -- so the account was
-- dead on arrival, and the failure surfaced far away from its cause, as
-- "Cross-currency transfers are not supported (PKR to USD)" on some later
-- transfer the customer tried to make.
--
-- Fixing the node fixes one instance. The constraint makes the whole class
-- impossible: this bank is PKR-only by design, every policy document says so,
-- and the schema now says so too.

-- One account was created this way. It has no ledger entries, no transactions
-- and a zero balance, so correcting its denomination is a relabel, not a
-- revaluation -- there is nothing denominated in it to convert.
UPDATE public.accounts
SET currency = 'PKR', updated_at = NOW()
WHERE currency <> 'PKR'
  AND balance = 0
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries le WHERE le.account_id = accounts.id);

ALTER TABLE public.accounts DROP CONSTRAINT IF EXISTS accounts_currency_check;
ALTER TABLE public.accounts ADD CONSTRAINT accounts_currency_check
    CHECK (currency = 'PKR');

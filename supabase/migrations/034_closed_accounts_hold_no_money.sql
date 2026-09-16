-- 034_closed_accounts_hold_no_money.sql
--
-- `run_reconciliation()` checks a cached balance against the ledger for active
-- and frozen accounts only. Its comment gives the reason:
--
--     Closed accounts are settled; their cached balance is definitionally 0
--     and their ledger entries are historical records, not live state
--
-- That was a comment, not a guarantee. `close_account()` refuses to close an
-- account holding money, so the balance is zero at the moment of closing --
-- but nothing stopped a balance being written to an already-closed account
-- afterwards, and the nightly check would not have looked at it. Money could
-- sit on a closed account indefinitely without any check noticing, which is
-- the precise failure the reconciliation exists to catch.
--
-- The system-wide debits-equal-credits check still covers every ledger line
-- including closed accounts, so a forged ledger entry was always caught. What
-- was uncovered was the cached `balance` column on a closed row.
--
-- The schema now guarantees what reconciliation assumes. That is what makes
-- skipping those rows safe rather than merely convenient.

ALTER TABLE public.accounts DROP CONSTRAINT IF EXISTS accounts_closed_balance_zero;
ALTER TABLE public.accounts ADD CONSTRAINT accounts_closed_balance_zero
    CHECK (status <> 'closed' OR balance = 0);

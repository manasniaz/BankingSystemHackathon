-- 030_fix_cross_owner_execute_grants.sql
--
-- Migration 029 added an authorisation check to resolve_ops_approval:
--
--     IF NOT public.is_bank_staff(p_decided_by_email) THEN ... refuse
--
-- and broke every ops approval in the bank. resolve_ops_approval is
-- SECURITY DEFINER owned by `banking_functions`, so it runs as that role --
-- but is_bank_staff was created in migration 027 owned by `postgres` and
-- granted only to `service_role`. The call failed with
-- `permission denied for function is_bank_staff`, every time, for every
-- approval type: loans, disputes, policy answers, reversals, staff enrolment.
--
-- It surfaced as an administrator replying APPROVE and nothing happening.
--
-- The lesson worth keeping: a SECURITY DEFINER function runs as its OWNER, not
-- as the caller, so a helper it calls must be executable BY THAT OWNER. The
-- project's older functions are owned by `banking_functions` and the ones added
-- in sessions 12 by `postgres`, so any call that crosses between them needs an
-- explicit grant. The audit query in docs/database.md finds them.

GRANT EXECUTE ON FUNCTION public.is_bank_staff(TEXT) TO banking_functions;
GRANT EXECUTE ON FUNCTION public.is_bank_admin(TEXT) TO banking_functions;
GRANT EXECUTE ON FUNCTION public.resolve_destination_account(TEXT) TO banking_functions;

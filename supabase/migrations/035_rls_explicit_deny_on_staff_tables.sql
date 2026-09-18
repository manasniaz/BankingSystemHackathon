-- 035_rls_explicit_deny_on_staff_tables.sql
--
-- Migration 003 made "RLS enabled, no policies" explicit on the four
-- internal-only tables that existed at the time. Three tables added later, in
-- the operations and administrator work (migrations 027 and 028), are in
-- exactly the same state and were never given the same treatment:
--
--     bank_staff                who is an operator or administrator
--     staff_enrolment_attempts  the audit trail of pass phrase attempts
--     staff_passphrase          the bcrypt hash of the joining pass phrase
--
-- As in 003, this is not a live vulnerability. RLS enabled with zero policies
-- already yields zero rows to anon and authenticated; only service_role, which
-- carries BYPASSRLS, can read them. The point is the same as it was then: make
-- the intent explicit rather than incidental, so a reviewer can see that these
-- tables are closed on purpose rather than closed by an accident of
-- configuration that a later migration could quietly undo.
--
-- It matters more here than it did in 003. `staff_passphrase` holds the
-- credential that grants operator access to the bank, and `bank_staff` decides
-- who may credit a customer account from the treasury. Of everything in this
-- schema, these are the last three tables whose access rules should rest on an
-- unstated default.

CREATE POLICY "deny_all_client_access" ON public.bank_staff
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE POLICY "deny_all_client_access" ON public.staff_enrolment_attempts
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE POLICY "deny_all_client_access" ON public.staff_passphrase
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

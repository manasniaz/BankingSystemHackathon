-- 003_rls_explicit_deny_policies.sql
--
-- The Supabase security advisor flags four tables as "RLS enabled, no policies":
-- audit_log, idempotency_keys, reconciliation_runs, support_case_drafts.
--
-- This is NOT a live vulnerability: in Postgres, RLS enabled with zero policies
-- already means anon/authenticated get zero rows. Only service_role (used by n8n
-- and the Python microservice, both of which carry BYPASSRLS) can read or write
-- these tables. These are all internal-only tables by design -- customers never
-- see raw audit events, idempotency bookkeeping, reconciliation runs, or
-- unapproved RAG drafts.
--
-- This migration makes that intent explicit instead of incidental, which is what
-- the linter actually wants to see, and documents the decision for reviewers.

CREATE POLICY "deny_all_client_access" ON public.audit_log
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE POLICY "deny_all_client_access" ON public.idempotency_keys
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE POLICY "deny_all_client_access" ON public.reconciliation_runs
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE POLICY "deny_all_client_access" ON public.support_case_drafts
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

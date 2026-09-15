# Database & Migrations

The full table list, relationships, and RPC signatures live in [`architecture.md`](architecture.md) — this page is the migration history: what each file adds and why, in the order they must be applied.

## Migration order

Apply these in Supabase's SQL editor, in order, against a fresh project:

| # | File | What it adds |
|---|---|---|
| 1 | [`001_initial_banking_schema.sql`](../supabase/migrations/001_initial_banking_schema.sql) | The original 15 tables, double-entry ledger triggers (append-only enforcement on `ledger_entries`/`audit_log`), and the first 11 `SECURITY DEFINER` RPCs (`execute_transfer`, `execute_standing_order`, `place_account_hold`, `release_account_hold`, `request_joint_closure`, `record_joint_consent`, `close_account`, `run_reconciliation`, `write_audit_log`, etc.). |
| 2 | [`002_security_hardening.sql`](../supabase/migrations/002_security_hardening.sql) | RLS enabled on every table; `REVOKE`/`GRANT` hardening so financial RPCs are only callable by `service_role`/`banking_functions`, never `anon`/`authenticated` directly. |
| 3 | [`003_rls_explicit_deny_policies.sql`](../supabase/migrations/003_rls_explicit_deny_policies.sql) | Explicit deny-all RLS policies for `anon`/`authenticated` on the four internal-only tables (`audit_log`, `idempotency_keys`, `reconciliation_runs`, `support_case_drafts`) that had RLS enabled but no policies — functionally already deny-all, made explicit rather than incidental. |
| 4 | [`004_governance_and_account_opening.sql`](../supabase/migrations/004_governance_and_account_opening.sql) | Self-service account opening (`open_account_for_profile`), holder governance (`add_account_holder`, `holder_type`/`guardian_of_profile_id`, age-based promotion via `promote_minors_to_adult`), either-or vs. both-signature transfer authority (`authority_model`, `initiate_transfer`, `is_holder_transfer_authorized`), majority-vote closure consent, and a weekend/holiday rule on `execute_standing_order`. Full `REVOKE FROM PUBLIC` / `GRANT TO service_role` pass across every financial function, including ones from migration 001 that were previously implicitly public-executable. |
| 5 | [`005_pkr_currency_joint_invitations_public_rag.sql`](../supabase/migrations/005_pkr_currency_joint_invitations_public_rag.sql) | Converts all currency columns/defaults to PKR; adds `joint_account_invitations` (5-minute-expiry email invitations) with `create_joint_account_invitation`/`respond_to_joint_invitation`/`expire_stale_joint_invitations`; makes `support_cases.profile_id` nullable with `customer_email`/`inquirer_type` so non-customers can use the public RAG chatbot; grants the new table to `banking_functions` (new tables aren't covered by migration 001's one-time snapshot grant). |
| 6 | [`006_treasury_deposits_and_loans.sql`](../supabase/migrations/006_treasury_deposits_and_loans.sql) | Adds the real funding source the system was missing: a `TREASURY-MAIN` account (Rs 500,000,000 of the bank's own capital) as the counterparty for money entering any customer account. New `loans` table plus `apply_for_loan`/`approve_loan`/`reject_loan`/`disburse_loan` RPCs (flat 10% interest, auto-approve ≤ Rs 200,000, human review up to a Rs 2,000,000 ceiling) and `deposit_funds` (self-service, capped at Rs 50,000/request, 3/account/24h). `standing_orders` gained a `loan_id` column, and `execute_standing_order()` was extended to retire a loan's `outstanding_balance` on repayment. |
| 7 | [`007_fix_treasury_genesis_ledger_backing.sql`](../supabase/migrations/007_fix_treasury_genesis_ledger_backing.sql) | Fixes a real bug in migration 006: the treasury's starting balance was set via a raw `UPDATE`-style insert with no backing `ledger_entries`, which `run_reconciliation()` immediately caught as a 50-billion-paisa discrepancy. Adds a `BANK-CAPITAL` account (`status = 'closed'`, exempt from the per-account reconciliation check) and a genesis transaction that properly credits treasury from it. |

## Minimal ER overview

```
auth.users ──(trigger)──> profiles ──< account_holders >── accounts
                                                              │
                          ┌───────────────┬───────────────────┼──────────────────┬───────────────────┐
                          │               │                   │                  │                    │
                    ledger_entries  account_holds     standing_orders   joint_account_actions   joint_account_invitations
                          │                                                       │
                    transactions                                       joint_account_consents
                          │
                    fraud_assessments, idempotency_keys

support_cases ── support_case_drafts (internal only, never exposed to a customer)
reconciliation_runs, audit_log (append-only, written by every financial function)
```

See `architecture.md` for the full 15-table list, every RPC's signature, and the security/permission model in detail.

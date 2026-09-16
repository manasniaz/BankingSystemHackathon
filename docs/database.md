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
| 8 | [`008_one_active_loan_per_profile.sql`](../supabase/migrations/008_one_active_loan_per_profile.sql) | Fixes another real gap in migration 006: `apply_for_loan` had no check against a profile already having a loan in flight, so someone could get several Rs 200,000 loans auto-approved back to back, each individually under the ceiling. Now blocks a new application while one is `pending_review` or `active`. |

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

## 009 – 017: email-driven approvals, account-opening details, minors, transfer authority

Applied live 2026-09-15. Each file is kept exactly as it was applied, including the two that fix a mistake in an earlier one, so replaying the folder in order reproduces the live database.

| # | File | What it adds |
|---|---|---|
| 009 | `009_ops_approval_queue.sql` | `ops_approvals` table (RLS deny-all for `anon`/`authenticated`), `create_ops_approval()`, `resolve_ops_approval()`, `expire_stale_ops_approvals()`. One row per pending human decision, addressed by a short `OPS-XXXXXXXX` code. |
| 010 | `010_loan_raises_ops_approval.sql` | `apply_for_loan()` raises its own ops approval when the amount is over the Rs 200,000 ceiling and returns the ref code, applicant name and email alongside the numbers. Also refuses a loan applied for by a minor holder. |
| 011 | `011_fix_ops_approval_audit_actor_type.sql` | Fixes 009: `audit_log.actor_type` has no `'operator'` value, so every successful `resolve_ops_approval()` aborted at the audit write and rolled the whole decision back. Ops decisions are `'admin'`. |
| 012 | `012_harden_transfer_authority.sql` | `initiate_transfer()` becomes the single enforced entry point: holder check, minor check (via the previously dead `is_holder_transfer_authorized()`), currency match, destination status, and the `either_or` / `all_signatures` mandate. |
| 013 | `013_joint_action_email_consent.sql` | `joint_account_actions.ref_code` (`JNT-XXXXXXXX`) with a `BEFORE INSERT` trigger, `respond_to_joint_action_by_ref()`, `list_pending_joint_actions_for_email()`. |
| 014 | `014_joint_action_execution_correctness.sql` | Fixes two bugs found by live testing: an action was marked `approved` before the thing it authorised ran and was never rolled back on failure; and the fraud assessment captured at request time (10-minute TTL) is always stale by the time consent arrives (7-day window). Adds `joint_account_actions.last_error` and `get_joint_action_by_ref()`. |
| 015 | `015_account_opening_details_and_minors.sql` | `set_profile_details()`, `open_account_with_details()` (stores date of birth, refuses under-18), `minor_account_requests` table, `request_minor_account()`, `respond_to_minor_account_request()`, `finalize_minor_account_request()`, `expire_stale_minor_account_requests()`. Also adds `joint_account_invitations.authority_model`. |
| 016 | `016_joint_invitation_authority_model.sql` | `create_joint_account_invitation()` takes the mandate, and `respond_to_joint_invitation()` applies it to the account it creates. Before this, `accounts.authority_model` existed but nothing ever set it. |
| 017 | `017_transfer_approval_returns_ref_code.sql` | `request_transfer_approval()` returns the `JNT` ref code, both account numbers, the amount and the requester's name, so the "please sign" email can be written without extra lookups. |

### New tables

**`ops_approvals`** — `ref_code` (unique), `request_type` (`loan` | `support_draft` | `minor_account` | `fraud_hold_release` | `transfer_reversal` | `remove_holder`), `target_id`, `status` (`pending` | `approved` | `rejected` | `expired` | `failed`), `subject`, `summary`, `payload`, `requested_for_email`, `decided_by_email`, `decision_note`, `decision_result`, `expires_at` (7 days), `decided_at`. `create_ops_approval()` reuses an existing open row for the same target rather than minting a duplicate.

**`minor_account_requests`** — `ref_code` (unique), `applicant_email`/`applicant_name`/`date_of_birth`, `guardian_email`, `account_type`, `currency`, `status` (`pending_guardian` | `guardian_approved` | `guardian_rejected` | `completed` | `expired`), and the `account_id` / `minor_profile_id` / `guardian_profile_id` filled in once the account is opened. `expires_at` is 7 days.

Both tables have RLS enabled with an explicit deny-all policy for `anon` and `authenticated`, matching the pattern established in `003_rls_explicit_deny_policies.sql`. Every new function is `SECURITY DEFINER`, owned by `banking_functions`, revoked from `PUBLIC` and granted only to `service_role`.

## 018: closing an account by email

| # | File | What it changes |
|---|---|---|
| 018 | `018_account_closure_by_email.sql` | `request_joint_closure()` no longer auto-consents the requester, so a single-holder account can no longer be closed instantly by one unverified email; every holder confirms via the emailed `JNT-` code. `request_account_closure()` is the new customer-facing entry point and runs the blocking checks up front - non-zero balance (amount quoted), active holds, active standing orders, an outstanding or pending loan, frozen or already-closed status - returning plain language instead of creating a request destined to fail. |

The confirm-and-execute half required no new SQL: `respond_to_joint_action_by_ref()` and `finalize_joint_action_if_complete()` have handled `action_type = 'close_account'` since migration 014.

Note the loan check is new here and does not exist in `close_account()` itself - an outstanding loan is a debt to the bank, and the account it is repaid from cannot simply disappear.

## 019 - 026: closing the last gaps against the capstone brief

| # | File | What it adds |
|---|---|---|
| 019 | `019_joint_governance_completion.sql` | `remove_holder` and `set_authority` joint action types. `remove_account_holder()`, `request_holder_removal()` (refused while a loan or hold is outstanding, or if it would leave zero holders, or strip a guardian off a minor account), `request_holder_addition()` (discloses every encumbrance), `request_authority_change()` and `apply_authority_change()`. |
| 020 | `020_reversals_and_debt_tracking.sql` | `account_debts` plus `reverse_transaction()`, `sweep_outstanding_debts()` and `get_account_debt_summary()`. A reversal shortfall becomes an explicit receivable, never a negative balance - `CHECK (balance >= 0)` is untouched. |
| 021 | `021_business_day_calendar_and_so_notifications.sql` | `bank_holidays`, `is_business_day()`, `adjust_for_business_day()`. `execute_standing_order()` now honours all three `weekend_holiday_rule` values against a real calendar and returns the account numbers, amount and holder emails on failure so the customer can be told. |
| 022 | `022_interest_accrual_and_statements.sql` | `interest_rates`, `interest_accruals`, `accrue_monthly_interest()` (idempotent per account per month) and `generate_account_statement()`. |
| 023 | `023_disputes_and_reversal_approval.sql` | `disputes` table, `raise_dispute()`, `add_dispute_holder_input()`, `resolve_dispute()`. `resolve_ops_approval()` learns the `dispute` and `transfer_reversal` request types. |
| 024 | `024_fix_statement_entry_type_case.sql` | Fixes 022: `entry_type` is stored lowercase but was compared uppercase, so every statement reported zero credits and zero debits while listing the correct entries. |
| 025 | `025_incoming_holder_must_accept.sql` | `accept_holder_addition()`. The person being added to an account must agree, not just the existing holders - which needed its own mechanism because `record_joint_consent()` requires the consenter to already be a holder. |
| 026 | `026_joint_action_lookup_allows_invitee.sql` | Fixes 019/025: `get_joint_action_by_ref()` refused any non-holder, so an invited holder could not answer their own invitation. |

### New tables

**`account_debts`** - a receivable against an account, created when a reversal cannot be fully clawed back. `amount_original`, `amount_outstanding`, `status` (`outstanding` | `settled` | `written_off`), linked to both the original and the reversal transaction.

**`bank_holidays`** - `holiday_date`, `name`, `is_estimated`. Lunar Eid dates are flagged estimated because their Gregorian dates are announced close to the day and must be corrected each year.

**`interest_rates`** / **`interest_accruals`** - the rate schedule per account type, and one accrual row per account per month with a unique constraint on `(account_id, period_start)` that makes re-running the job safe.

**`disputes`** - `ref_code` (`DSP-`), the disputed transaction, who raised it, `holder_input` as a JSONB array of each co-holder position, and the resolution. `is_joint_account` drives whether co-holder input is collected.

All four have RLS enabled with an explicit deny-all policy for `anon` and `authenticated`. Every new function is `SECURITY DEFINER`, owned by `banking_functions`, revoked from `PUBLIC` and granted only to `service_role`.

## 027: bank staff, operator actions, loan withdrawal, recipients by email

| # | File | What it adds |
|---|---|---|
| 027 | `027_operator_authority_and_loan_withdrawal.sql` | `bank_staff` and `is_bank_staff()`. `operator_credit_account()` and `operator_decide_loan()`. `withdraw_loan_application()`. `resolve_destination_account()`. A trigger refusing customer profiles for staff addresses, and a rewritten `request_account_closure()` that tells a customer how to unblock a pending-loan refusal. |

### New table

**`bank_staff`** - `email`, `role` (`ops` | `admin`), `is_active`. The database had no concept of an address belonging to the bank rather than to a customer, so the operations mailbox went through account opening like anyone else and ended up holding a loan with a repayment schedule.

**Staff addresses are deliberately not seeded by the migration.** They are real addresses and this repository is public. After applying 027, run this once against the live project with the real address:

```sql
insert into bank_staff (email, role, note)
values ('<your-ops-mailbox>@example.com', 'ops', 'Banking operations mailbox')
on conflict (email) do update set is_active = true;
```

n8n must agree with it: the ops address is also defined in WF-00's `Detect Reference Reply` node, which is the single place the live workflow holds the bank's own two addresses (`opsTeamEmail` and `bankEmail`) and passes them to every node downstream. The repository copy of that workflow carries placeholders.

### Status vocabulary

`loans.status` gains `withdrawn`, and `ops_approvals.status` gains `cancelled`, so a withdrawn application and its now-pointless pending approval are both representable rather than being forced into `rejected` - which would claim the bank made a decision it never made.

### New functions

**`resolve_destination_account(p_lookup)`** - resolves an account number, a UUID, or a **registered email address** to an account. Reports `ambiguous_recipient` with the candidate account numbers when the recipient holds more than one active account, rather than choosing. Refuses a staff address outright.

**`withdraw_loan_application(p_profile_id, p_loan_id)`** - withdraws an application still in `pending_review` and cancels its pending ops approval in the same transaction. Refuses once the loan is `active`, distinguishing "already disbursed" from "nothing pending" because the two need completely different replies.

**`operator_credit_account(p_operator_email, p_target, p_amount, p_reason)`** - treasury to customer through `process_money_movement()`, audited as `admin`. A grant, not a loan: no `loans` row, no interest, no standing order, nothing to repay. Distinct from a deposit, which is the *customer* claiming to have paid money in and is therefore capped.

**`operator_decide_loan(p_operator_email, p_target, p_decision, p_reason)`** - lets ops decide a pending application by naming the account or customer instead of quoting an `OPS-` code. The reference-code round trip remains the normal path; this exists for clearing something stuck.

Both operator functions verify `is_bank_staff()` first and refuse everyone else.

## 028: staff enrolment, and naming the people who get paid

| # | File | What it adds |
|---|---|---|
| 028 | `028_staff_enrolment_and_recipient_details.sql` | `staff_passphrase` and `staff_enrolment_attempts`. `staff_check()`, `enrol_bank_staff()`, `change_staff_passphrase()`. `resolve_destination_account()` now also returns the destination's holder addresses. |

### New tables

**`staff_passphrase`** - a single row holding a **bcrypt hash** of the operations enrolment phrase. The plain text is not in this table, not in the repository, and not in any email the bank sends. Only whoever set it knows it.

**`staff_enrolment_attempts`** - every attempt, successful or not, with the reason. Five failures from one address in an hour locks that address out, and a phrase being guessed at leaves a trail rather than leaving nothing.

### Joining the operations team

An address emails the bank with a line reading `PASSPHRASE: <the phrase>` and becomes an operator. That is a privilege grant by shared secret, which is a genuinely risky shape, so four things bound it:

- **A customer address can never enrol.** This is the control that matters. An operator can credit any account; someone who is both customer and operator can credit their own. `enrol_bank_staff()` refuses any address with a profile, and the migration 027 trigger refuses to create a profile for an address that is already staff. The separation holds from both directions.
- **Five wrong guesses per address per hour**, checked before the phrase is examined so a near-miss and nonsense hit the same wall.
- **Every attempt is recorded**, right or wrong.
- **Every existing operator is emailed the moment someone joins.** A silent privilege grant is the dangerous one.

Enrolment requires an explicit `PASSPHRASE:` line rather than testing every unrecognised email against the phrase, which would spend an innocent sender's attempt budget and turn any stray message into a guess.

### Rotating the phrase

Any active operator emails `NEW PASSPHRASE: <the new phrase>`. Minimum eight characters. Every operator is told it changed and by whom, and none of them is sent the phrase itself. Rotation is what makes a shared secret survivable, so it must not need a developer.

Rotating also clears the recent failure counters, so an honest operator is not left serving out someone else's lockout.

### One team, not one address

`staff_check()` answers three things the routing layer needs: whether this sender is staff, which mailbox is the team inbox (the oldest active operator, so enrolling a second one does not redirect the bank's mail), and how many operators there are. Before this the team was a single hardcoded address in a Code node, which quietly meant a second operator could never have worked.

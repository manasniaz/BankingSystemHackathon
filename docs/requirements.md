# Requirements

## Functional

| Area | Requirement | Where it's implemented |
|---|---|---|
| Identity | Every inbound email must resolve to a registered `profiles.email` before any account data is disclosed. | WF-00 `Lookup Profile by Email` + `Customer Profile Exists?` |
| Authorization | A sender may only see or move money for accounts where they hold an `account_holders` row. Any reference to an account they don't hold is denied with zero data leakage. | WF-00 `Fetch Authorized Accounts`, `Resolve Transfer Target & Authorize` |
| Transfers | Every transfer is atomic (debit+credit or neither), idempotent (retries never double-move funds), and fraud-checked before execution. | `execute_transfer()` RPC (`supabase/migrations/001_initial_banking_schema.sql`), WF-01 |
| Fraud | Every transfer request is scored by a deterministic rules engine before funds move; a service outage fails safe (hold), never fails open (approve). | `python/main.py`, WF-03 `Validate & Evaluate Fraud Decision` |
| Standing orders | Recurring transfers execute on schedule, retry on transient failure up to a bounded count, and notify ops on permanent failure. | `execute_standing_order()`, WF-02 |
| Reconciliation | The ledger is checked nightly for internal consistency (debits=credits, balances=ledger sums), with an alert on any discrepancy. | `run_reconciliation()`, WF-06 |
| Support | Policy questions get a RAG-grounded draft. A grounded, confident (≥0.7) answer is sent to the customer automatically; anything the model isn't confidently grounded on requires explicit human approval before it reaches a customer. | WF-04, WF-05 |
| Auditability | Every financial mutation and every fraud/support decision writes an immutable audit record. | `audit_log` (append-only via trigger), `write_audit_log()` |

## Non-functional

- **Financial integrity over availability.** Any ambiguity (fraud service down, malformed payload, missing required field) resolves to *reject/hold*, never to a best-effort guess with real money. See the "no hardcoded fallback" fix applied to WF-00/WF-01/WF-04 during this review — a missing field must be a rejected request, never a default account.
- **All money is integer minor units (cents)**, `BIGINT`, to eliminate floating-point rounding entirely.
- **No secrets in source control.** Supabase `service_role` key, Groq/Pinecone/Gemini keys, and Gmail OAuth all live only in n8n's and Railway's credential/env stores — never in this repository.
- **Laptop independence.** Every scheduled and event-driven workflow runs entirely in n8n Cloud / Supabase Cloud / Railway; the developer's machine is only needed to edit code and push to GitHub.
- **Human-in-the-loop for anything irreversible or reputationally risky** — see `decisions.md` domain 6 for the explicit unsupervised vs. always-human action lists.

## Added in Session 9

| Area | Requirement | Where it's implemented |
|---|---|---|
| Human approval | Every decision that needs a human goes to a dedicated ops mailbox and is decided by **replying** to that email, not by calling a webhook. Only the real Gmail sender counts as authorisation. | `ops_approvals` + `resolve_ops_approval()` (`009`/`011`), WF-00 `Detect Reference Reply` → `Resolve Ops Approval` |
| Account opening | An account is only opened once we know the applicant's date of birth. Under 18 cannot proceed without a named guardian's explicit consent. | `open_account_with_details()`, `request_minor_account()` (`015`), WF-00 `Account Opening Eligibility` |
| Minor accounts | A minor holder may view the balance and receive money but may never move money out; the guardian can. Full access is restored automatically at 18. | `is_holder_transfer_authorized()` enforced by `initiate_transfer()` (`012`), `promote_minors_to_adult()` run nightly by WF-06 |
| Joint mandate | A joint account is either-or or all-signatures by the customers' explicit choice, and that choice is enforced on every transfer. | `accounts.authority_model`, `create_joint_account_invitation()` (`016`), `initiate_transfer()` (`012`), WF-00 `Resolve Joint Invitation Request` |
| Transfer authorization | The holder check, minor check and mandate live in the database next to the money movement, not only in an n8n Code node. | `initiate_transfer()` (`012`) — the single enforced entry point |

## Explicitly not a requirement for this submission

Multi-currency FX conversion, real interbank settlement/holiday calendars, interest accrual on deposit accounts, and reversal into a negative balance. See `mvp-scope.md`.

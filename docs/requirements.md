# Requirements

## Functional

| Area | Requirement | Where it's implemented |
|---|---|---|
| Identity | Every inbound email must resolve to a registered `profiles.email` before any account data is disclosed. | WF-00 `Lookup Profile by Email` + `Customer Profile Exists?` |
| Authorization | A sender may only see or move money for accounts where they hold an `account_holders` row. Any reference to an account they don't hold is denied with zero data leakage. | WF-00 `Fetch Authorized Accounts`, `Resolve Transfer Target & Authorize` |
| Transfers | Every transfer is atomic (debit+credit or neither), idempotent (retries never double-move funds), and fraud-checked before execution. | `execute_transfer()` RPC (`supabase/migrations/001_initial_banking_schema.sql`), WF-01 |
| Fraud | Every transfer request is scored by a deterministic rules engine before funds move; a service outage fails safe (hold), never fails open (approve). | `python/main.py`, WF-03 `Validate & Evaluate Fraud Decision` |
| Standing orders | Recurring transfers execute on a business-day-aware schedule, retry on transient failure up to a bounded count, and notify both ops **and the customer** on permanent failure. | `execute_standing_order()`, WF-02 |
| Reconciliation | The ledger is checked nightly for internal consistency (debits=credits, balances=ledger sums), with an alert on any discrepancy. | `run_reconciliation()`, WF-06 |
| Support | Policy questions get a RAG-grounded draft. An answer that is grounded, confident (≥0.7) and flagged as needing no human is sent to the customer automatically; anything else requires explicit human approval before it reaches a customer. A question our documents cover only in part is answered for the part we publish, not escalated whole. | WF-04, WF-00 (`OPS-` approval) |
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


## Added in Session 11

| Area | Requirement | Where it's implemented |
|---|---|---|
| Joint governance | Removing a holder requires every holder to agree, the removed party included, and is refused while the account is encumbered. Adding one discloses the encumbrance and requires the incoming holder's own acceptance. | `request_holder_removal()`, `request_holder_addition()`, `accept_holder_addition()` (`019`, `025`) |
| Mandate | The transfer mandate and closure rule are changeable after opening by unanimous consent; majority closure is refused below three holders. | `request_authority_change()` (`019`) |
| Reversals | A completed transfer is reversed only by human decision. Whatever cannot be clawed back is booked as an explicit receivable; no balance ever goes negative. | `reverse_transaction()`, `account_debts`, `sweep_outstanding_debts()` (`020`) |
| Scheduling | Standing orders respect a real business-day calendar, with all three weekend/holiday rules honoured. | `bank_holidays`, `adjust_for_business_day()` (`021`) |
| Notification | The customer, not just ops, is told when a recurring payment fails permanently. | `execute_standing_order()` (`021`), WF-02 |
| Interest | Savings accrue monthly from the treasury through double-entry, idempotently, for fully elapsed months only. | `accrue_monthly_interest()` (`022`), WF-06 |
| Statements | Reconstructable from the ledger alone, and never sent if the arithmetic does not close. | `generate_account_statement()` (`022`/`024`), Python `/generate-statement` |
| Disputes | Unilateral to raise, co-holder input collected, always resolved by a human. | `raise_dispute()`, `add_dispute_holder_input()`, `resolve_dispute()` (`023`) |
| RAG safety | An answer claiming to be grounded with no citations is forced to human review regardless of its stated confidence. An escalated answer keeps its draft and citations so the operator can act on it. Past cases are never indexed. | WF-04 `Parse Agent Draft Output`, `Hold Draft for Review` |
| Fraud patterns | Known typologies are retrieved semantically to inform the human reviewing a freeze, and never feed the deterministic score. | `fraud_patterns` namespace, WF-03 `Search Fraud Patterns` |

## Explicitly not a requirement for this submission

Multi-currency FX conversion and real interbank settlement. Everything else in the capstone brief is built — see `mvp-scope.md` for the short list of things genuinely still absent, and `decisions.md` for the item-by-item record.

(Earlier revisions of this page also listed holiday calendars, interest accrual and reversal-into-debt here. All three were built in Session 11; reversal in particular is handled as an explicit receivable rather than a negative balance, so the invariant that made it look impossible is still intact.)

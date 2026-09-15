# Digital Bank — Public Policy Documents

These are Digital Bank's official policy documents: the fictional (hackathon) bank's own published rules on fees, limits, privacy, and procedures. They serve two purposes:

1. **Human-readable reference** — what the bank's policies actually are, for anyone reading this repository.
2. **RAG source of truth** — the exact same text is embedded into Pinecone by [`WF-09 Seed Policy Documents`](../n8n/workflows/WF-09-seed-policy-documents.json), and is the *only* material the policy-support AI assistant (WF-04) is allowed to answer from. It never invents a policy that isn't written here.

> **Keep these in sync.** If you edit a policy's wording here, update the matching `doc_id` entry in WF-09's `Policy Documents` code node and re-run the workflow (it re-embeds and inserts — see the note on updates below), or the live assistant will keep citing the old text.

---

### `doc_privacy_policy` — Privacy Policy

Digital Bank collects only the information needed to operate your account — your email address (used as your account identity), full name, date of birth, and transaction history. Customer data is never sold or shared with third parties for marketing. Our AI policy assistant only ever receives your question text and retrieved policy documents — never your account number, balance, or transaction history. Account access is always verified against the actual sender of an email; an email address written inside a message body is never treated as identity.

### `doc_terms_and_conditions` — Terms and Conditions

By opening an account with Digital Bank you agree to conduct all banking activity by email from your registered address. Digital Bank may place a security hold on any account or transaction flagged by automated fraud screening pending manual review. Accounts must maintain a balance of Rs 0.00 or greater at all times; overdrafts are never permitted. Digital Bank may update these terms, its fee schedule, or transfer limits at any time; customers are notified of material changes by email.

### `doc_account_opening_policy` — Account Opening Policy

Digital Bank offers checking and savings accounts in PKR (Pakistani Rupees), opened by email request. No minimum opening deposit is required; new accounts start at a balance of Rs 0.00. This is a simplified account-opening process without formal KYC document verification.

### `doc_joint_account_policy` — Joint Account Policy

A joint account is opened by inviting another person by email. The invited person has exactly 5 minutes to accept or decline before the invitation expires. By default either holder may transfer funds unilaterally (either-or authority); an account can instead be configured so that every holder must approve a transfer before it executes (both-signatures authority). Closing a joint account requires consent from all named holders.

### `doc_account_closure_policy` — Account Closure Policy

An account can only be closed once its balance is exactly Rs 0.00 and it has no active holds or standing orders. Joint accounts require every holder to consent before closure is finalized.

### `doc_wire_transfer_policy` — Wire Transfer Policy

International wire transfers have a daily limit of Rs 500,000 per account for verified customers, with a flat fee of Rs 1,500 per outgoing international wire. Domestic wire transfers within Pakistan have no fee and are processed the same business day if submitted before 3:00 PM PKT.

### `doc_overdraft_policy` — Overdraft Policy

Digital Bank does not offer overdraft facilities on checking or savings accounts. Every transfer is validated against available balance before execution; a transaction that would take the balance below zero is automatically rejected, never allowed to create a negative balance.

### `doc_atm_fees` — ATM Fee Policy

ATM withdrawals at Digital Bank-branded ATMs are free of charge. Withdrawals at partner network ATMs within Pakistan incur a Rs 25 fee per transaction. Withdrawals at non-partner ATMs incur a Rs 50 fee per transaction.

### `doc_standing_orders_policy` — Standing Order Policy

Recurring standing order payments are checked hourly and executed automatically once due. If a scheduled payment falls on a weekend, it is processed on the next business day by default. If a payment fails due to insufficient funds, it is retried on subsequent runs up to 3 times before being marked permanently failed and the customer notified.

### `doc_dispute_fraud_policy` — Dispute and Fraud Policy

If a transaction was unauthorized or fraudulent, reply to our email immediately with the transaction date, amount, and recipient. Our fraud team places an immediate hold on suspicious activity pending investigation. Disputes are typically reviewed within 3-5 business days.

### `doc_fraud_scoring_policy` — Fraud Scoring Policy

Every transfer is automatically scored for fraud risk before execution. Risk factors include high transaction velocity (more than 5 transfers in 60 minutes), large transfer amounts (over Rs 500,000), and first-time transfers to a new recipient. Transactions scoring 75 or higher are blocked and the account is placed under a security hold pending human review.

### `doc_reconciliation_policy` — Reconciliation Policy

Digital Bank reconciles its full ledger every night at midnight UTC, verifying that system-wide debits equal credits and that every account balance matches its recorded double-entry transaction history.

### `doc_deposit_policy` — Deposit Policy

Customers may deposit funds into their account by email. Self-service deposits are limited to Rs 50,000 per request and no more than 3 deposits per account in a rolling 24-hour period. Larger deposits require visiting a branch.

### `doc_loan_policy` — Loan Policy

Digital Bank offers personal loans to existing account holders by email request, at a flat 10% interest rate over the loan term (not compounded). Loans up to Rs 200,000 are approved and disbursed instantly; loans up to a maximum of Rs 2,000,000 are reviewed by a specialist before disbursement. Approved loan funds are credited to the borrower's account immediately, and the total repayable amount is collected automatically in equal monthly installments via a standing order.

### `doc_support_hours_policy` — Support Policy

Digital Bank email support is available 24/7. Policy questions are answered by an AI assistant grounded strictly in official policy documents; grounded, confident answers are sent automatically — a human specialist only reviews requests the assistant could not confidently answer from policy documents before a response is sent.

---

## Where does the money come from?

Every account used to open at Rs 0.00 with no way to fund it — a transfer request had nothing to draw from. Fixed with a real, ledger-backed funding source rather than a shortcut:

- **`TREASURY-MAIN`**: an internal account (never customer-owned, never reachable by any email-authenticated intent) funded with Rs 500,000,000 of the bank's own capital. It's the counterparty for every deposit and loan disbursement, so money moving into a customer account is a genuine double-entry transfer, not a balance mutation — nightly reconciliation checks it exactly like every other account.
- **Self-service deposits**: capped at Rs 50,000/request, 3/day per account (`doc_deposit_policy`) — a claimed deposit by email is inherently unverifiable, so it's bounded rather than escalated to human review.
- **Loans**: up to Rs 200,000 auto-approved and disbursed instantly; up to Rs 2,000,000 reviewed by a specialist (`doc_loan_policy`). Approved loans are repaid automatically via a standing order, same mechanism as any other recurring payment.

See `decisions.md` → Session 7 for the full design, including a genesis-funding bug this surfaced and fixed (`BANK-CAPITAL`, the offsetting account for treasury's own starting balance).

## Why human review isn't on every answer

Earlier in this project, *every* policy question — no matter how well-grounded — sat in a human-approval queue before the customer got anything but a "we're looking into it" receipt. That defeats the point of a public policy chatbot and doesn't reflect how a real support desk would work. The current design (see `decisions.md` → "Session 5"):

- **Grounded and confident (≥ 0.7)**: the AI's answer is sent to the customer directly. No human in the loop.
- **Not grounded, low-confidence, or an agent error**: queued for a human via WF-05, and the customer gets a receipt saying a specialist will follow up — never a guess presented as fact.

This keeps the human approval gate for what it's actually for — genuinely ambiguous or unanswerable questions — instead of throttling every request through a person who isn't needed.

## Updating the seeded documents in Pinecone

`WF-09`'s `Policy Documents` code node is insert-only (no upsert/id-mapping configured), so re-running it with the full document list would duplicate everything already in the index. To add or correct a document without duplicating the rest:
1. Temporarily replace the code node's `docs` array with just the new/changed entries.
2. Run the workflow once (`Manual Seed Trigger`).
3. Restore the full canonical list (so a future full reindex — e.g. after recreating the Pinecone index — seeds everything correctly in one run).

If you need to fully wipe and reseed the index, delete all vectors in the `banking_policy` namespace first, then run WF-09 once with the complete list.

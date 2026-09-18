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

**Superseded, and it was never true.** This described international and domestic wire transfers, a daily limit and a per-wire fee. The bank has none of those: it moves money only between Digital Bank accounts, charges nothing, and enforces no daily limit. The live policy is [`policy-documents/02-payments-and-transfers.md`](policy-documents/02-payments-and-transfers.md) sections 5 and 6.

### `doc_overdraft_policy` — Overdraft Policy

Digital Bank does not offer overdraft facilities on checking or savings accounts. Every transfer is validated against available balance before execution; a transaction that would take the balance below zero is automatically rejected, never allowed to create a negative balance.

### `doc_atm_fees` — ATM Fee Policy

**Superseded, and it was never true.** There are no Digital Bank ATMs, no card and no cash withdrawal anywhere in this system, so there is nothing to charge for. See [`policy-documents/02-payments-and-transfers.md`](policy-documents/02-payments-and-transfers.md) section 6.

### `doc_standing_orders_policy` — Standing Order Policy

Recurring standing order payments are checked hourly and executed automatically once due. If a scheduled payment falls on a weekend, it is processed on the next business day by default. If a payment fails due to insufficient funds, it is retried on subsequent runs up to 3 times before being marked permanently failed and the customer notified.

### `doc_dispute_fraud_policy` — Dispute and Fraud Policy

If a transaction was unauthorized or fraudulent, reply to our email immediately with the transaction date, amount, and recipient. Our fraud team places an immediate hold on suspicious activity pending investigation. **Superseded:** the live policy is a decision by a human specialist, normally within one business day. See `policy-documents/05-security-fraud-and-disputes.md`.

### `doc_fraud_scoring_policy` — Fraud Scoring Policy

Every transfer is automatically scored for fraud risk before execution. Risk factors include high transaction velocity (more than 5 transfers in 60 minutes), large transfer amounts (over Rs 500,000), and first-time transfers to a new recipient. Transactions scoring 75 or higher are blocked and the account is placed under a security hold pending human review.

### `doc_reconciliation_policy` — Reconciliation Policy

Digital Bank reconciles its full ledger every night at midnight UTC, verifying that system-wide debits equal credits and that every account balance matches its recorded double-entry transaction history.

### `doc_deposit_policy` — Deposit Policy

Customers may deposit funds into their account by email. Self-service deposits are limited to Rs 50,000 per request and no more than 3 deposits per account in a rolling 24-hour period. **Superseded:** there is no branch. A request over the cap is simply refused with the limit stated.

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

- **Grounded, confident (≥ 0.7), and needing no human**: the AI's answer is sent to the customer directly. No human in the loop.
- **Not grounded, low-confidence, needing a human, or an agent error**: queued for a human via the `OPS-` approval email in WF-00, and the customer gets a receipt saying a specialist will follow up — never a guess presented as fact.

The three conditions are separate on purpose, because they fail for different reasons. *Grounded* is about the draft's sourcing: every factual claim in it came from a retrieved document. *Confidence* is how sure the model is that it read those documents correctly. *Needs-human* is about whether the draft is safe to send at all — a question needing the customer's own account data, a decision, an exception, or a complaint handled is escalated no matter how well-sourced the policy half of the answer is.

Collapsing those into one flag is what broke this gate once already: a question that was only *partly* covered by our documents was treated as unanswerable in full, and a correct, cited answer was discarded (`decisions.md` → "Session 12, fourth pass"). A question our documents cover in part now gets an answer to that part and a plain sentence about the rest.

This keeps the human approval gate for what it's actually for — genuinely ambiguous or unanswerable questions, and anything touching a specific customer's money — instead of throttling every request through a person who isn't needed.

## Updating the seeded documents in Pinecone

`WF-09`'s `Policy Documents` code node is insert-only (no upsert/id-mapping configured), so re-running it with the full document list would duplicate everything already in the index. To add or correct a document without duplicating the rest:
1. Temporarily replace the code node's `docs` array with just the new/changed entries.
2. Run the workflow once (`Manual Seed Trigger`).
3. Restore the full canonical list (so a future full reindex — e.g. after recreating the Pinecone index — seeds everything correctly in one run).

If you need to fully wipe and reseed the index, delete all vectors in the `banking_policy` namespace first, then run WF-09 once with the complete list.

## Added in Session 9

These four were seeded into Pinecone on 2026-09-15 alongside the original 15.

### Minor and Guardian Accounts

`doc_minor_guardian_accounts`

Minor and Guardian Account Policy: Digital Bank opens accounts for applicants under 18, but only with the explicit consent of a parent or guardian. Every account application must include a date of birth; we accept 2010-05-14, 14/05/2010, 14 May 2010 or May 14, 2010, and where the numeric form is ambiguous we read it day first. An applicant under 18 must also give a parent or guardian email address. We then email that guardian a consent request with a reference code beginning MIN-, and the account is only opened once the guardian replies APPROVE from that same address. Only the named guardian can answer; a reply from any other address is refused. On a guardian-supervised account the minor is the primary holder and the guardian is added as a joint holder with guardian authority. The minor can check the balance and receive money into the account at any time, but cannot transfer money out and cannot take out a loan; only the guardian can move money out. The restriction is enforced in the banking database itself, not only in the email workflow. The account converts automatically to full adult access on the holder’s 18th birthday, at which point the guardian’s control ends; no request or paperwork is needed for that conversion. If the guardian does not reply within 7 days the request expires and the applicant can simply ask again. If the guardian replies REJECT, no account is opened and the applicant is told.

### Joint Account Mandates

`doc_joint_account_mandate`

Joint Account Mandate Policy: A joint account at Digital Bank operates under one of two mandates, chosen by the customers when the account is opened. Either-or (the default) means any single holder can transfer money out on their own. All-signatures, also called both-signatures or dual control, means every holder must approve each individual transfer before it is carried out. To choose the stricter mandate, say so when inviting the other person, for example "both of us must approve every transfer"; to choose the default, say "either of us can act alone". The invitation and confirmation emails both state which mandate was applied. On an all-signatures account, a requested transfer moves no money immediately: it is held, the person who asked for it is told how many approvals are outstanding, and every other holder is emailed a reference code beginning JNT- which they answer by replying APPROVE or REJECT. Only a holder of that account can answer. When the last approval arrives we run a fresh fraud check at that moment and then carry out the transfer, because the original fraud assessment expires after ten minutes. A single REJECT closes the request immediately and no money moves. An unanswered request expires after 7 days. Closing a joint account is separate from the transfer mandate and always requires the agreement of all holders, except on accounts configured for majority closure with three or more holders, where a simple majority is enough. A transfer that is fully approved but then fails, for example for insufficient funds, does not silently disappear: it stays open with the reason recorded and everyone involved is told what happened.

### Loan Approval Process

`doc_loan_approval_process`

Loan Approval Policy: Digital Bank offers personal loans by email at a flat 10 percent interest rate, for a term between 1 and 60 months. A loan of Rs 200,000 or less is approved automatically and the funds are credited to your account immediately. A loan above Rs 200,000 and up to the Rs 2,000,000 email ceiling is referred to our credit review team; you will receive an email confirming the principal, the term, the total repayable and the monthly repayment, and a separate email with the decision once it is made, usually within one business day. Loans above Rs 2,000,000 cannot be arranged by email and require a branch visit. Repayment is automatic: a monthly standing order is created when the loan is disbursed, and the loan is marked paid off once the outstanding balance reaches zero. You may hold one loan at a time; a further application is refused until the existing loan is repaid or the review decision on it is made. A minor account holder cannot take out a loan; a guardian must apply in their own name. If a loan is declined you are told the reason and are welcome to apply again later.

### What Needs a Human, and What Does Not

`doc_human_review_policy`

Human Review Policy: Most requests at Digital Bank are handled end to end automatically, and we deliberately do not send everything to a person. Handled without any human step: balance enquiries, transfers from accounts you hold that pass our fraud checks, deposits within the published limits, loans of Rs 200,000 or less, opening a single or joint account, scheduled standing order payments, and any policy question we can answer confidently from these published documents. A person is involved only where the decision genuinely needs judgement: a loan above Rs 200,000, a policy question our assistant cannot answer confidently from published policy, and releasing an account freeze placed by our fraud checks. In those cases nothing is sent to you until a member of our operations team has reviewed it, and you are told that a review is under way rather than being given a guess. Some decisions are not ours to make at all and are referred to you instead: a co-holder approving a transfer on an all-signatures joint account, and a parent or guardian approving an account for someone under 18. A fraud freeze cannot be lifted by the customer, by email or otherwise; that always requires a human operator, which is deliberate. Every decision, automatic or human, is written to an immutable audit record.


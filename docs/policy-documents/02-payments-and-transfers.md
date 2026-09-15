# Digital Bank — Payments, Transfers and Fees Policy

**Document ID:** `doc_payments_and_transfers`
**Currency:** All amounts are Pakistani Rupees (PKR).
**Last reviewed:** 2026-09-15

---

## 1. Making a transfer

Email us with the amount and the destination account number, for example:

> Please transfer 5000 rupees to account TEST-BOB-001.

We take the amount from the **body** of your email, not the subject line. Subject lines get reused and forwarded and are a bad source of truth for how much money to move. Amounts are read as whole rupees — "5000" means Rs 5,000.00.

We need the destination **account number**. We cannot send money to a person's name or email address, because we have no safe way to resolve a name to an account. If you don't include an account number, we reply asking for one rather than guessing.

**A transfer is only ever made from an account you hold.** If you reference an account that isn't yours, the request is refused with no information disclosed about that account — we will not confirm or deny that it exists.

## 2. What happens to a transfer

Every transfer passes through these stages before any money moves:

1. **Authorization** — you must be a registered holder of the source account. A minor holder cannot transfer out (see the Accounts policy).
2. **Mandate check** — on a joint account set to all-signatures, the transfer is parked until every holder approves (see the Joint Accounts policy).
3. **Fraud scoring** — every transfer is scored by our fraud engine before execution (see the Security and Fraud policy).
4. **Balance check** — you cannot transfer more than the account's available balance.
5. **Execution** — the money moves as a single atomic operation.

If any stage fails, no money moves at all, and you are told why.

## 3. Insufficient funds

We do not offer overdrafts. A transfer that would take the balance below zero is rejected outright. It is never partially completed, and the account can never go negative.

## 4. Atomicity, duplicates and retries

A transfer either completes fully or does not happen at all. There is no state in which money leaves one account without arriving in the other — both sides are written in the same database transaction, and any failure rolls the whole thing back.

Every transfer carries an **idempotency key** derived from your email. If the same email is processed twice — a retry, a duplicate delivery, a network hiccup — the second attempt returns the original result instead of moving money again. **Sending the same instruction twice will not send the money twice.**

If you genuinely want to send the same amount to the same person again, send a new email. It gets its own key and is treated as a new instruction.

## 5. Transfer limits and fees

| Item | Amount |
|---|---|
| Domestic transfer between Digital Bank accounts | **Free**, settled instantly |
| International wire, daily limit per account | Rs 500,000 |
| International wire fee | Rs 1,500 per outgoing wire |
| Domestic wire within Pakistan | No fee, same business day if submitted before 3:00 PM PKT |
| Transfer above Rs 500,000 | Scored as high-value by our fraud engine and may be held for review |

## 6. ATM fees

| Where | Fee |
|---|---|
| Digital Bank ATMs | Free |
| Partner network ATMs in Pakistan | Rs 25 per withdrawal |
| Non-partner ATMs | Rs 50 per withdrawal |

## 7. Standing orders (recurring payments)

A standing order is a transfer that repeats on a schedule. They are created automatically when a loan is disbursed, to collect the monthly repayment.

- Orders are checked **every hour** and execute when due.
- If an execution fails — most commonly insufficient funds — we retry. After **3 failed attempts** the order is stopped permanently and our operations team is alerted to look at it.
- A standing order that is edited or deleted while an execution is in flight is handled safely; the in-flight execution completes or rolls back cleanly, it never half-runs.
- **Weekend and holiday handling:** this system settles instantly and internally rather than over interbank rails, so there is no clearing delay to work around. Orders execute on their due date whatever day of the week it falls on.

An account with an active standing order paying out of it cannot be closed until that order is cancelled.

## 8. Reversals and chargebacks

There is no automated reversal. Once a transfer has completed, the money is in the recipient's account and only they can send it back.

If a transfer was fraudulent, raise a dispute (see the Security and Fraud policy) and a human will investigate. We deliberately do not offer a self-service "undo" on a completed transfer, because that would be trivially abusable.

## 9. Currency

Every account is in PKR and we do not convert between currencies. A transfer between two accounts of different currencies is refused rather than converted at a rate we haven't published.

Internally, all amounts are stored as whole **paisa** (1 PKR = 100 paisa) using integers, so no rounding error can ever accumulate across transactions.

# Digital Bank — Payments, Transfers and Fees Policy

**Document ID:** `doc_payments_and_transfers`
**Currency:** All amounts are Pakistani Rupees (PKR).
**Last reviewed:** 2026-09-15

---

## 1. Making a transfer

Email us with the amount and the destination account number, for example:

> Please transfer 5000 rupees to account TEST-BOB-001.

We take the amount from the **body** of your email, not the subject line. Subject lines get reused and forwarded and are a bad source of truth for how much money to move. Amounts are read as whole rupees — "5000" means Rs 5,000.00.

We only read what *you* typed. The quoted original underneath a reply is ignored entirely, so an account number or address that appears in the text you are replying to is never mistaken for your instruction.

### Naming the recipient

You can name the destination two ways:

| | Example |
|---|---|
| **Account number** | `send 5000 to ACC-1234567890` |
| **Registered email address** | `send 5000 to someone@example.com` |

An email address works because it is exactly what we authenticate on — your address is your identity here, and so is theirs. A **name** is not, and never will be: names are not unique and prove nothing.

If the address you give holds **more than one** account with us, we do not pick one. We reply listing the account numbers and ask which you meant.

If we cannot identify a recipient at all, we say so and move no money.

### Both sides are told

When a transfer completes we email **you** and we email **the person who received it** — every holder, if the destination is a joint account. The sender is never emailed twice for moving money between two accounts they hold themselves.

The arrival notice names the amount, the account it landed in, and the sender's name and account number. It does not include the sender's email address. If a recipient does not recognise the sender, replying to that notice opens a dispute.

A transfer that did not complete is announced to nobody but you.

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
| Transfer between Digital Bank accounts | **Free**, settled instantly |
| Transfer above Rs 500,000 | Scored as high-value by our fraud engine. Held for review if it is also going to a recipient you have not paid before |

We move money **between Digital Bank accounts only**. Every transfer here is a
book transfer settled against our own ledger in a single database transaction,
which is why it is free and why it arrives immediately rather than on a
clearing cycle.

There is no daily cap and no per-transfer cap on what you may send within the
bank, beyond your own available balance. A large transfer is not refused by a
limit; it is **scored**, and may be held for a person to review (see the
Security, Fraud and Disputes policy for the rules and the thresholds).

## 6. What we do not offer, and what we charge

Stated plainly, so that nobody plans around a service that is not here:

- **No cash, no cards and no ATMs.** There is no Digital Bank card, no ATM
  network and no way to withdraw cash.
- **No payments to or from other banks.** We cannot send money to an account
  held at another institution, in Pakistan or anywhere else, and we cannot
  receive one.
- **No international wires and no foreign currency.** Every account is in PKR
  (see section 9).
- **No overdrafts and no credit cards.** See the Accounts and the Borrowing
  policies.

Because none of those exist here, none of them carries a fee.

**What we charge: nothing.** There is no account maintenance fee, no monthly or
annual service charge, no minimum-balance fee, no dormancy fee, no transfer fee
and no account-closure fee. Holding and using an account with Digital Bank costs
nothing.

The only amounts ever taken out of your account are:

1. money you asked us to transfer,
2. a loan repayment collected by the standing order created when your loan was
   disbursed (see the Borrowing and Deposits policy),
3. money returned to someone else because a dispute against you was upheld (see
   the Security, Fraud and Disputes policy).

**If a charge is not listed in this document, we do not make it.** We will not
introduce a charge and apply it to an existing account without telling you
first.

## 7. Standing orders (recurring payments)

A standing order is a transfer that repeats on a schedule. They are created automatically when a loan is disbursed, to collect the monthly repayment.

- Orders are checked **every hour** and execute when due.
- If an execution fails — most commonly insufficient funds — we retry. After **3 failed attempts** the order is stopped permanently and our operations team is alerted to look at it.
- A standing order that is edited or deleted while an execution is in flight is handled safely; the in-flight execution completes or rolls back cleanly, it never half-runs.
- **Weekend and holiday handling.** Each standing order carries one of three rules:
  - `next_business_day` (the default) — a payment due on a weekend or a public holiday moves forward to the next working day.
  - `process_early` — it moves backward to the previous working day instead.
  - `allow_weekend` — it settles on the calendar date whatever day that is. This is a legitimate choice here, not an oversight: we settle instantly against our own ledger, so unlike a real interbank payment there is no clearing window to miss.
  
  Our calendar covers Pakistan's public holidays. The Islamic-calendar holidays (Eid al-Fitr, Eid al-Adha, Ashura, Eid Milad un-Nabi) are lunar and their exact dates are confirmed close to the day, so we review them each year rather than treating our estimates as fixed.
- If a payment fails permanently, **you are told directly** — not just our operations team. We email every holder of the paying account with what failed, why, and what to do about it, and we say plainly if it was a loan repayment, because your loan is still owed.

An account with an active standing order paying out of it cannot be closed until that order is cancelled.

## 8. Reversals and chargebacks

**There is no self-service undo.** You cannot reverse your own completed transfer by asking, and no automated process will do it for you. That is deliberate: a self-service undo on a completed payment would be trivially abusable.

A completed transfer is reversed only through a **human decision** — either a dispute that a specialist upholds, or a reversal an operator authorises directly. Raise a dispute (see the Security and Fraud policy) and a person will investigate.

**What happens when a reversal is approved:**

1. We take back whatever the recipient still holds, using the same double-entry mechanism as any transfer, and return it to you.
2. **If they have already spent some or all of it**, we recover what is there and record the remainder as a **debt owed to the bank by the recipient**. Their balance is never pushed below zero — a shortfall is tracked as a debt, not as a negative balance.
3. That debt is then collected automatically from money the recipient receives later, until it is cleared.

So a reversal may return your money in stages rather than all at once, depending on what the recipient still had. You are told what was recovered immediately and what is being collected.

## 9. Currency

Every account is in PKR and we do not convert between currencies. A transfer between two accounts of different currencies is refused rather than converted at a rate we haven't published.

Internally, all amounts are stored as whole **paisa** (1 PKR = 100 paisa) using integers, so no rounding error can ever accumulate across transactions.

## 10. Statements

Ask us for a statement any time and we will email it to you.

- **Default period:** the last full calendar month.
- Say *"this month"* for month-to-date, *"this year"* for year-to-date, or give explicit dates: *"statement from 2026-08-01 to 2026-08-31"*.
- If you hold more than one account, tell us which — we will ask rather than guess.

A statement shows your opening balance, everything that came in, everything that went out, your closing balance, and every individual transaction with the running balance after it. Any outstanding debt on the account is shown too.

The figures are rebuilt from the ledger itself rather than from any running total, and we check that the statement adds up — opening plus money in, minus money out, must equal closing — before it is sent. If it does not, we do not send it; our team is alerted instead.

If you see something on a statement you do not recognise, reply and tell us. We will open a dispute and a specialist will investigate.

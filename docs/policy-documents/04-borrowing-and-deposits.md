# Digital Bank — Borrowing and Deposits Policy

**Document ID:** `doc_borrowing_and_deposits`
**Currency:** All amounts are Pakistani Rupees (PKR).
**Last reviewed:** 2026-09-15

---

## 1. Getting money into an account

A new account opens at Rs 0.00. There are two ways to fund it: a deposit, or a loan.

Both are paid out of **`TREASURY-MAIN`**, the bank's own capital account, using the same double-entry mechanism as any customer transfer. Money is never created out of nothing — every rupee that appears in a customer account has a matching debit against the treasury, and the nightly reconciliation checks that this still balances.

## 2. Deposits

Email us asking to deposit an amount into your account.

| Limit | Value |
|---|---|
| Maximum per deposit | Rs 50,000 |
| Maximum deposits per account | 3 per rolling 24 hours |

A deposit is credited immediately, with no human approval step.

**Why the caps:** a deposit claimed in an email is unverifiable — there is no cash, no cheque and no incoming wire behind it in this system. Rather than escalate every deposit to a person, which would make the feature useless, we bound how much damage an unverifiable claim can do. A request over the cap is refused with the limit stated, not partially fulfilled.

## 3. Loans

Digital Bank offers personal loans to existing account holders by email.

| Term | Value |
|---|---|
| Interest rate | **10% flat** over the term — not compounded |
| Loan term | 1 to 60 months |
| Instant approval | Up to **Rs 200,000** |
| Human review | Above Rs 200,000, up to **Rs 2,000,000** |
| Maximum by email | Rs 2,000,000 — above that requires a branch visit |
| Concurrent loans | **One at a time** per customer |

### How to apply

Email us the amount and the term:

> I'd like to borrow 30000 rupees for 12 months please.

If you don't state a term we assume **12 months**. Terms can be given in days, weeks, months or years; anything shorter than a month rounds **up** to one month, since repayment is monthly.

### What happens next

**Rs 200,000 or less** — approved automatically. The funds are credited to your account immediately and a monthly repayment standing order is created in the same operation. You get one email confirming the principal, the total repayable, the term and the monthly amount.

**Above Rs 200,000** — the application is recorded and referred to our credit review team. You get an email confirming the figures and telling you it's under review, then a second email with the decision, usually within one business day. Nothing is disbursed until a person has approved it.

**Above Rs 2,000,000** — refused by email, with an explanation that a branch visit is required.

### Worked example

A loan of Rs 100,000 over 12 months at 10% flat:

- Total repayable: Rs 110,000
- Monthly repayment: Rs 9,167 (the final instalment absorbs the rounding)
- Collected automatically by standing order on the same date each month

### Repayment

Repayment is automatic. The standing order created at disbursement collects each monthly instalment from the account the loan was paid into. Each payment reduces the outstanding balance, and when it reaches zero the loan is marked **paid off** and the standing order is cancelled automatically.

You do not need to do anything to repay a loan except keep enough in the account. If an instalment fails for insufficient funds, it is retried; after three failures the standing order stops and our operations team is alerted.

### Who cannot borrow

- **Anyone who already has an open loan.** A second application is refused until the existing loan is repaid, or until the review decision on it is made. We tell you this explicitly rather than silently rejecting.
- **A minor account holder.** A guardian must apply in their own name.
- **A closed or frozen account.**

### Cancelling an application you have already sent

If you applied for a loan and changed your mind, email us and say so — *"please cancel my loan application"*. While the application is still awaiting a decision we withdraw it immediately, no questions asked. Nothing is owed, your account is unaffected, and you can apply again whenever you like. Any pending review with our credit team is cancelled at the same time, so nobody is asked to decide something you no longer want.

**Once a loan has been approved and the money paid out, there is nothing left to cancel.** The application is finished; what exists now is a debt. Cancelling the paperwork would not cancel the obligation, so we tell you plainly that the balance is still owed and is being collected by standing order. This is the one case where we will not do what you asked, and we say why rather than quietly failing.

This also unblocks closing an account: an account cannot be closed while a loan application is awaiting a decision, so if you want the account gone, cancel the application first and then ask us to close it.

### If a loan is declined

You are told, and you are told why. You are welcome to apply again later. A declined loan does not affect your account in any other way.

## 4. Credits from the bank

Occasionally the bank itself puts money into a customer's account — to put right a mistake we made, to settle a dispute in your favour, or as a goodwill payment. Our operations team issues these directly.

**A credit is not a loan.** There is no interest, no term, no repayment schedule and nothing to repay. The money is yours the moment it arrives and you can spend or transfer it like any other balance. The email you receive says so explicitly, because the difference matters and "the bank sent me money" should never leave you wondering whether you now owe something.

A credit is paid out of `TREASURY-MAIN` by the same double-entry mechanism as everything else, appears on your statement as a normal credit with the reason attached, and is included in the nightly reconciliation.

Only bank staff can issue one. A customer asking us to credit their own account is a deposit request, and deposit caps apply.

## 5. Interest on deposits

| Account type | Annual rate |
|---|---|
| **Savings** | **5.00%** |
| Checking | 0% |
| Business | 0% |

Interest on a savings account is calculated monthly at one twelfth of the annual rate, applied to the closing balance of the month, and credited automatically. You do not need to ask for it or claim it.

**Detail worth knowing:**

- Interest is only ever paid for a month that has **fully ended**. A month in progress is never paid as though it were complete.
- Amounts are rounded **down** to the whole paisa. We never pay a fraction of a paisa we did not actually compute.
- Each month is paid exactly once. Our systems can safely re-run the calculation without paying you twice, and equally without skipping a month if a run is missed.
- Interest appears on your statement as a normal credit, from the bank, described as the month it covers.

If your balance is small enough that a month of interest rounds to less than one paisa, nothing is credited that month.

## 6. Overdrafts

Digital Bank does not offer overdrafts on any account type. Every transfer is validated against the available balance before execution, and a transaction that would take the balance below zero is rejected rather than allowed to create a negative balance.

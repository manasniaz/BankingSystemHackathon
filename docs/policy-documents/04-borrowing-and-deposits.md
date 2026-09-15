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

### If a loan is declined

You are told, and you are told why. You are welcome to apply again later. A declined loan does not affect your account in any other way.

## 4. Interest on deposits

Digital Bank does not currently pay interest on checking or savings balances. There is no interest-bearing product, and no rate schedule. Interest applies only to loans, as the cost of borrowing.

## 5. Overdrafts

Digital Bank does not offer overdrafts on any account type. Every transfer is validated against the available balance before execution, and a transaction that would take the balance below zero is rejected rather than allowed to create a negative balance.

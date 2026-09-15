# Digital Bank — Joint Accounts Policy

**Document ID:** `doc_joint_accounts`
**Currency:** All amounts are Pakistani Rupees (PKR).
**Last reviewed:** 2026-09-15

---

## 1. Opening a joint account

Email us naming the person you want to open it with, and their email address:

> I want to open a joint account with bob@example.com. Both of us must approve every transfer.

We email them an invitation. They have **exactly 5 minutes** to reply "I accept" or "I decline" before the invitation expires. The window is deliberately short: an invitation to be jointly liable for an account should be answered while the conversation is fresh, not days later.

If it expires, nothing is created and you are told. You can simply ask again.

If the person you invite isn't a Digital Bank customer yet, accepting the invitation makes them one — we create their profile as part of accepting.

You cannot invite yourself.

## 2. The mandate: who is allowed to act alone

Every joint account runs under one of two mandates, and **you choose which when you open it**:

| Mandate | What it means |
|---|---|
| **Either-or** (default) | Any single holder can transfer money out on their own, without asking anyone. |
| **All-signatures** (also called both-signatures or dual control) | Every holder must approve each individual transfer before it executes. |

Say which you want in plain English when you invite the other person:

- *"both of us must approve every transfer"* → all-signatures
- *"either of us can act alone"* → either-or

If you say nothing, the account is **either-or**. Both the invitation email and your confirmation email state which mandate was applied, so there is no ambiguity about what you agreed to. If we got it wrong, reply and we'll send a fresh invitation with the other setting.

## 3. How an all-signatures transfer works

On an all-signatures account, a requested transfer moves **no money immediately**:

1. The transfer is held as a pending request. The person who asked is told how many approvals are still outstanding.
2. Every other holder is emailed a reference code beginning `JNT-`, showing the amount, the source and destination accounts, and who asked for it.
3. Each holder replies `APPROVE` or `REJECT`. Only a holder of that account can answer — we check that against the account, not just against the email address it came from.
4. When the final approval arrives, we **re-run the fraud check at that moment** and then execute the transfer. This matters: the fraud assessment taken when the transfer was first requested expires after ten minutes, and approvals can take days, so a stale assessment would be meaningless.
5. Everyone involved is emailed the outcome.

**A single `REJECT` from any holder closes the request immediately** and no money moves.

**If nobody answers**, the request expires after **7 days** and no money moves.

**If the fraud check fails at the final approval**, the transfer is stopped, the request stays open, and both the approving holder and our operations team are told. Your approval is not recorded as a rejection — you approved it, our checks stopped it, and those are different things.

**If the transfer fails for another reason** — most commonly the balance dropped between the request and the last approval — the request stays open with the reason recorded rather than silently disappearing, so it can be retried once the cause is fixed.

## 4. Adding and removing holders

Adding a holder to an existing account is supported, and requires the consent of the existing holders. If the account has an active hold on it, adding a holder additionally requires an explicit acknowledgement of that hold — you should not be able to join yourself to an encumbered account without being told it is encumbered.

**Removing a holder from an account that stays open is not supported.** It raises questions this system does not answer — who inherits the departing holder's share of any hold or standing order, and what happens to their liability — and we would rather refuse it than implement a guess. The supported route is to close the account (see below) and open a new one.

## 5. Closing a joint account

Closing requires **every** holder to agree, including the one who asked. The process is the same reference-code confirmation used everywhere else in this bank:

1. Any holder emails us asking to close the account.
2. We check the account is eligible — zero balance, no active holds, no active standing orders, no outstanding loan.
3. Every holder, requester included, is emailed a `JNT-` reference code.
4. The account closes only once **all** of them have replied `APPROVE`.

A single `REJECT` stops it. If nobody replies within 7 days the request expires and the account stays open.

**Where holders disagree, the account stays open.** There is no mechanism for one holder to force a closure over another's objection, and no forced payout split. A disagreement simply means the request never reaches full approval and times out.

**Accounts with three or more holders** may instead be configured for **majority closure**, where a simple majority — `floor(n/2) + 1` — is enough to close. This is not the default. Unanimous consent is, because majority closure lets two of three holders close an account and force a settlement the third never agreed to, and that is not a decision to make by default.

## 6. Disputes on a joint account

A dispute raised on a joint account is investigated by a human specialist, exactly like any other dispute. We do not have an automated rule for whether one holder can dispute a transaction another holder made — that is precisely the kind of judgement call a person should make with both holders' accounts in front of them.

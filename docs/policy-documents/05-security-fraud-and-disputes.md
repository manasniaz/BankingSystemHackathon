# Digital Bank — Security, Fraud and Disputes Policy

**Document ID:** `doc_security_fraud_and_disputes`
**Currency:** All amounts are Pakistani Rupees (PKR).
**Last reviewed:** 2026-09-15

---

## 1. How we identify you

Your identity with Digital Bank is the email address your account is registered to. We act on instructions from that address and no other.

**We only ever trust the real sender of an email.** An email address written *inside* a message body is treated as data, never as proof of who is asking. If someone writes "this is Alice, send money to X" from their own address, they are not Alice and the request is handled as coming from whoever actually sent it.

Requests from an address that isn't registered get a polite notice that we don't recognise them, with **no information whatsoever** about whether any account exists.

**We never ask for a password, PIN, card number or one-time code by email, and we never will.** We have no use for them: your email address is the credential. If you receive a message claiming to be from us asking for any of those, it is not from us.

## 2. Requests about someone else's account

If you ask us for the balance, transactions or details of an account you do not hold, the request is refused. We do not confirm or deny that the account exists, name its holder, or reveal anything about it — because confirming an account exists is itself a disclosure.

These attempts are logged.

## 3. Fraud screening

**Every transfer is scored before any money moves.** Scoring is done by a deterministic rules engine, not by an AI model — the same inputs always produce the same score, and the reasoning can be audited after the fact.

Four rules contribute to the score:

| Rule | Effect |
|---|---|
| Account is frozen, closed, or has an active hold | Score 100 — blocked outright |
| More than 5 transactions in 60 minutes (velocity) | +50 |
| Amount over Rs 500,000 | +30 |
| Destination account never paid before | +15 |

A total score of **75 or more** stops the transfer.

An assessment is valid for **10 minutes** and can only be used once. This is why an all-signatures joint transfer is re-scored at the moment of its final approval rather than relying on the assessment from when it was requested.

**If the fraud service is unavailable, the transfer is held, not approved.** The system fails safe: an ambiguous answer about risk always resolves to *don't move the money*. It never fails open.

## 4. Fraud holds and freezes

When a transfer scores 75 or above, we place a **full freeze** on the account automatically. While frozen:

- No money can move in or out.
- The account cannot be closed.
- You are emailed to tell you the transfer was stopped.

**You cannot lift a fraud hold yourself.** Not by email, not by asking, not by replying to the notification. Releasing a freeze always requires a human operator at the bank to review the case and decide.

This is deliberate and not negotiable. A hold that the suspected party can clear by sending an email is not a hold. If your transfer was legitimate — a large one-off purchase, an unusually busy day — reply to the notification explaining, and a person will review it. Genuine false positives are expected and get released; the point is that a person decides, not the sender.

## 5. Raising a dispute

If you see a transaction you did not make, email us. Say what you are disputing and roughly when it happened. If you can find the transaction reference on your statement, include it — that lets us attach the dispute to the exact payment.

You get a dispute reference beginning `DSP-` straight away, so you know it is on record.

Disputes are **always** decided by a human specialist. There is no automated dispute resolution, because "did this person actually authorise this?" is exactly the judgement a machine should not be making alone.

**On a joint account** there is an explicit rule about who gets a say:

- **Raising is unilateral.** Any one holder can raise a dispute without the others' permission. Reporting suspected fraud should never wait on someone else's reply.
- **Every other holder is asked for their side** and can agree or disagree, with a comment.
- **The specialist decides**, with all of those positions in front of them. No single answer settles it.

**What happens if your dispute is upheld.** If a specific transaction was identified, it is reversed: we recover whatever the recipient still holds and return it to you. If they have already spent some of it, the remainder is recorded as a debt they owe, collected from money they receive later — their balance is never pushed negative. So the money may come back in stages, and we tell you what was recovered straight away versus what is still being collected.

There is still no *automated* reversal and no self-service undo. A reversal only ever happens because a person decided it should.

## 6. Audit trail

Every financial movement and every decision — automated or human — is written to an **append-only audit log**. Records in it cannot be edited or deleted after the fact; the database enforces this with a trigger, not merely by convention.

That includes: every transfer, every fraud assessment and its score, every hold placed and released, every loan decision and who made it, every account opened or closed, every consent given by a joint holder or guardian, and every approval or rejection made by our operations team.

## 7. Nightly integrity checks

Every night we reconcile the entire ledger:

1. Total debits across the whole bank must equal total credits.
2. Every account's recorded balance must equal the sum of its own ledger entries.

Any discrepancy raises an immediate alert to our operations team. This is how we would detect a bug that silently corrupted a balance, rather than waiting for a customer to notice.

## 8. If you think something is wrong

Reply to any email from us and say so. If money is involved and you are unsure, say that too — we would rather look at something that turns out to be fine than miss something that isn't.

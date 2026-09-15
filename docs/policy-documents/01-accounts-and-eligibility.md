# Digital Bank — Accounts and Eligibility Policy

**Document ID:** `doc_accounts_and_eligibility`
**Currency:** All amounts are Pakistani Rupees (PKR).
**Last reviewed:** 2026-09-15

---

## 1. What accounts we offer

Digital Bank offers three account types, all denominated in PKR:

| Type | Purpose |
|---|---|
| **Checking** | Everyday payments and transfers. The default if you don't specify. |
| **Savings** | For money you don't need day to day. Same transfer rules as checking. |
| **Business** | For a registered business. Opened the same way. |

There is no minimum opening deposit. Every new account starts at a balance of **Rs 0.00**.

We do not currently offer overdrafts, credit cards, or foreign-currency accounts.

## 2. How to open an account

Email the bank and say you'd like to open an account. Tell us:

- **Your date of birth** — required, no exceptions (see section 3)
- Which account type you want — checking, savings or business. If you don't say, we open a checking account.
- Optionally, a contact phone number

You do not need to visit a branch, upload documents, or complete a form. We accept your email address as your identity: the account is tied to the address you write to us from, and from then on we only act on instructions from that address.

**This is a simplified account-opening process without formal KYC document verification.** A real bank would verify your identity documents before opening an account. This one does not, which is a deliberate simplification of this system and not a model of regulatory compliance.

## 3. Date of birth is mandatory

We will not open an account without a date of birth. It decides whether the account needs a guardian, and it is what lets a guardian-supervised account convert to full access automatically.

We accept any of these formats:

- `2010-05-14`
- `14/05/2010`
- `14 May 2010`
- `May 14, 2010`

Where a numeric date is ambiguous (for example `05/06/1998`) we read it **day first**, which is the convention in Pakistan.

If you ask to open an account without giving a date of birth, we reply asking for it rather than opening the account.

## 4. Applicants under 18

Anyone under 18 can hold an account with us, but never on their own. A parent or guardian must consent first.

**How it works:**

1. The applicant emails us asking to open an account, giving their date of birth **and** a parent or guardian's email address.
2. We do not open anything yet. We create a pending request and email the named guardian a consent request carrying a reference code that begins `MIN-`.
3. The guardian replies with the single word `APPROVE` or `REJECT`. Only the named guardian can answer, and only from that same email address — a reply from anyone else is refused.
4. On `APPROVE`, the account is opened. On `REJECT`, or if nobody replies within **7 days**, no account is opened and the request expires.

**What a guardian-supervised account means in practice:**

- The minor is the primary holder. The guardian is added as a joint holder with guardian authority.
- The minor **can** check the balance and receive money into the account at any time.
- The minor **cannot** transfer money out, and **cannot** take out a loan.
- Only the guardian can move money out of the account.
- This restriction is enforced inside the banking database itself, not merely in the email system, so it cannot be bypassed by wording a request differently.

**Conversion at 18:** on the holder's 18th birthday the account converts automatically to full adult access and the guardian's control ends. No request, paperwork or reminder is needed — a scheduled job checks every night.

## 5. Opening more than one account

An existing customer can open additional accounts by email at any time, subject to the same rules. Your date of birth is already on file, so you only need to say which type you want.

## 6. Closing an account

An account can only be closed when **all** of the following are true:

- The balance is exactly **Rs 0.00**. We will not close an account holding money, because doing so would strand the funds. Transfer the balance out first.
- There are **no active holds** on the account, including fraud holds.
- There are **no active standing orders** paying out of the account.
- There is **no outstanding loan** against the account, and no loan application awaiting a decision. A loan is a debt to the bank; the account it is repaid from cannot simply disappear.

If any of these blocks the closure, we tell you which one and what to do about it. Nothing is changed on your account.

**Closure is irreversible.** We cannot reopen a closed account, and the account number is never reissued. Because of that, a request to close is never acted on immediately:

1. You email us asking to close the account. If you hold more than one open account, tell us which — we will not guess, and will ask you if it isn't clear.
2. We run the checks above. If they pass, we email a confirmation request carrying a reference code beginning `JNT-`.
3. You reply `APPROVE` to confirm, or `REJECT` to cancel.
4. **On a joint account, every holder must approve**, not just the one who asked. A single `REJECT` from any holder stops the closure and the account stays open.
5. If nobody confirms within **7 days** the request expires by itself and the account stays open.

A minor cannot request closure of a guardian-supervised account; the guardian must ask, from their own address.

## 7. Account status

An account is always in one of three states:

- **Active** — normal operation.
- **Frozen** — a fraud hold has been placed. Money cannot move in or out. Only a member of our operations team can lift it; you cannot clear it yourself by email. A frozen account cannot be closed until the review is resolved.
- **Closed** — permanently closed, as described above.

# Policy Documents

These six documents are the bank's published policy. They are the **source of truth** for every answer the RAG assistant gives to a policy question, and they are written to be read by a person, not just chunked by a retriever.

| File | Document ID | Covers |
|---|---|---|
| [`01-accounts-and-eligibility.md`](01-accounts-and-eligibility.md) | `doc_accounts_and_eligibility` | Account types, opening, date of birth, minors and guardians, closure rules, account status |
| [`02-payments-and-transfers.md`](02-payments-and-transfers.md) | `doc_payments_and_transfers` | Making transfers, atomicity and idempotency, limits, wire and ATM fees, standing orders, reversals |
| [`03-joint-accounts.md`](03-joint-accounts.md) | `doc_joint_accounts` | Joint opening, either-or vs all-signatures mandate, co-holder approval, adding/removing holders, joint closure |
| [`04-borrowing-and-deposits.md`](04-borrowing-and-deposits.md) | `doc_borrowing_and_deposits` | Deposits and caps, loans, interest, approval thresholds, repayment, who cannot borrow |
| [`05-security-fraud-and-disputes.md`](05-security-fraud-and-disputes.md) | `doc_security_fraud_and_disputes` | Identity, fraud scoring rules, holds and freezes, disputes, audit trail, nightly integrity checks |
| [`06-privacy-terms-and-service-standards.md`](06-privacy-terms-and-service-standards.md) | `doc_privacy_terms_and_service` | Privacy, terms, what is automated vs what needs a person, service standards |

## How these reach the assistant

The assistant does not read these files directly. They are embedded into a Pinecone vector index, and the assistant searches that index and answers only from what it retrieves.

There are two paths into the index, and they are separate on purpose:

**Path A — the original (live).** WF-09's `Policy Documents` Code nodes hold nineteen shorter policy snippets as string literals. These are what the bank is answering from today, in Pinecone namespace `banking_policy`.

**Path B — Google Drive (built, not yet run).** WF-09's `Sync From Drive Trigger` branch reads the six documents above out of a Google Drive folder, extracts their text, and seeds them into namespace **`banking_policy_v2`**. This is how policy should be maintained going forward: edit a document in Drive, re-run the sync, done — no code change, no n8n knowledge required.

### Why a separate namespace

These six documents are a rewritten consolidation of the original nineteen. Seeding them into the same namespace would leave both versions retrievable, so the assistant could surface an old chunk that contradicts a new one — a fee or a limit that disagrees with itself. In a bank, that is worse than having no answer.

So `v2` is populated alongside the live namespace, verified, and only then switched to. The switch is one field, and so is the rollback.

## Setting up the Drive sync

1. Create a folder in Google Drive, e.g. **Digital Bank Policy Documents**.
2. Upload all six `.md` files from this directory into it. (Native Google Docs work too — the download step exports them as plain text.)
3. Copy the folder ID from the URL: `drive.google.com/drive/folders/`**`<THIS_PART>`**
4. In n8n, open **WF-09 Seed Policy Documents** → the **`Drive Folder Config`** node → replace `PASTE_GOOGLE_DRIVE_FOLDER_ID_HERE` with that ID. This is the only place the folder is configured.
5. Run the workflow from the **`Sync From Drive Trigger`** node.
6. Confirm six documents landed in `banking_policy_v2`.
7. Switch the assistant over: **WF-04 RAG Support** → **`Policy Knowledge Base`** node → change the namespace from `banking_policy` to `banking_policy_v2`. Publish.
8. Ask the bank a policy question by email and check the answer is grounded and correct.

To roll back at any point, set that namespace field back to `banking_policy`.

The Drive credential (`Google Drive account`) is already connected in n8n.

## Editing policy afterwards

Edit the document in Drive, then re-run the Drive sync.

**One caveat:** the sync currently *adds* to the namespace rather than replacing it, so re-running after an edit leaves the old version of that document in the index alongside the new one. Until that is addressed, the safe sequence for a material change (a fee, a limit, a rule) is to clear the `banking_policy_v2` namespace in the Pinecone console first, then re-run the sync. Automatic clear-and-reseed was deliberately not built: wiping a vector namespace is destructive, and it was not worth adding untested against a component that currently works.

Keep these files and the Drive copies in step. The repository copy is what a reviewer reads; the Drive copy is what the bank actually answers from.

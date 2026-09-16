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

**Google Drive → `banking_policy_v2` → the assistant.** WF-09's `Sync From Drive Trigger` branch reads these six documents out of a Google Drive folder, extracts their text, and seeds them into Pinecone namespace **`banking_policy_v2`**. WF-04 answers from that namespace. This is how policy is maintained: edit a document in Drive, re-run the sync, done — no code change, no n8n knowledge required.

The older path still exists: WF-09's `Policy Documents` Code nodes hold nineteen shorter snippets as string literals, seeded into namespace `banking_policy`. That namespace is **no longer what the bank answers from**. It is kept as a rollback target, not as a second source of truth.

### Why a separate namespace

These six documents are a rewritten consolidation of the original nineteen. Seeding them into the same namespace would leave both versions retrievable, so the assistant could surface an old chunk that contradicts a new one — a fee or a limit that disagrees with itself. In a bank, that is worse than having no answer.

So `v2` was populated alongside the live namespace, verified, and only then switched to. The switch is one field in WF-04's `Policy Knowledge Base` node, and so is the rollback.

## Editing policy

1. Edit the document **in Drive** (or edit it here and re-upload — see below).
2. In n8n, run **WF-09 Seed Policy Documents** from the **`Sync From Drive Trigger`** node.
3. Ask the bank the question by email and check the answer.

The sync **clears `banking_policy_v2` before seeding**, so a re-run replaces the namespace rather than adding to it. Without that, an edited document sat in the index beside its own previous version and the assistant could retrieve either — which made the pipeline useless for exactly the case it exists for: correcting a fee, a limit or a rule.

The clear targets `banking_policy_v2` and nothing else. The live `banking_policy` namespace is never touched by it.

There is a window during the sync where the namespace is empty. If a question arrives then, retrieval finds nothing, the assistant does not guess, and the question goes to a human — the same safe failure as any ungrounded question.

`README.md` and any file named `notes`, `changelog` or `todo` are skipped rather than embedded. This file explains Pinecone namespaces and folder IDs; it is setup documentation, not bank policy, and a customer's question should never retrieve it.

## Keeping the repository and Drive in step

The repository copy is what a reviewer reads. The Drive copy is what the bank actually answers from. They are two copies of the same text and they will drift unless you keep them together.

**After editing any of these six files here, re-upload it to the Drive folder and re-run the sync.** Nothing enforces this automatically, so it is worth doing in the same sitting as the edit.

The folder ID lives in exactly one place — WF-09's **`Drive Folder Config`** node — and the Drive credential (`Google Drive account`) is already connected in n8n.

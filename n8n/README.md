# n8n Digital Banking Automation Platform — Operator & Testing Manual

## Overview

The `n8n/` layer is the automated control plane for the Digital Banking System. It connects **Real Email (Bank Gmail)** to **Supabase PostgreSQL Financial RPCs**, a **Python Fraud Microservice**, and **LangChain RAG (Groq + Pinecone + Gemini)**.

> **Key Architectural Rule:** n8n performs intake, intent classification, routing, AI drafting, and notification dispatch. All money movement, balance calculations, idempotency locking, ledger double-entry, and financial permissions are enforced atomically inside PostgreSQL database functions (RPCs).

> **Currency: PKR.** All amounts in this manual are Pakistani Rupees; the database stores them as `BIGINT` paisa (1 PKR = 100 paisa).

---

## Final Workflow Portfolio

| Workflow File | Name | Trigger | Description |
|---|---|---|---|
| [`WF-00-gmail-intake-router.json`](workflows/WF-00-gmail-intake-router.json) | WF-00 Gmail Front Door | Native Gmail Trigger (poll unread) | Customer front door. Resolves the actual sender to a database profile (never an address written inside the message body), checks authorized accounts, classifies intent from the email **body** first (subject only as a fallback), routes to sub-workflows, returns Gmail replies. Also handles self-service single/joint account opening and opportunistically sweeps expired joint invitations on every real incoming email. |
| [`WF-01-transfer.json`](workflows/WF-01-transfer.json) | WF-01 Transfer | Sub-Workflow / Webhook (`POST /webhook/transfer`) | Validates transfer parameters and idempotency key, calls `initiate_transfer`/`execute_transfer` RPC (either-or or both-signature authority, depending on the account), returns a structured result. |
| [`WF-02-standing-order-scheduler.json`](workflows/WF-02-standing-order-scheduler.json) | WF-02 Standing Orders | Schedule Trigger (hourly) | Scans due standing orders (`next_execution_at <= NOW()`), calls `execute_standing_order` RPC, handles retries, triggers permanent failure alerts to Ops. |
| [`WF-03-fraud-hold.json`](workflows/WF-03-fraud-hold.json) | WF-03 Fraud Hold | Sub-Workflow / Webhook (`POST /webhook/assess-fraud`) | Invokes the Python fraud microservice (`POST /assess-fraud`). If risk ≥ 75 or `approved=false`, calls `place_account_hold` RPC to freeze the account and sends an Ops alert. |
| [`WF-04-rag-support-case.json`](workflows/WF-04-rag-support-case.json) | WF-04 RAG Support | Sub-Workflow / Webhook (`POST /webhook/support-case`) | Open to anyone, not just customers. Creates a `support_cases` row, runs the LangChain agent (Groq + Pinecone + Gemini) grounded in [`../docs/policies.md`](../docs/policies.md). A grounded, confident (≥0.7) answer is **sent directly** — no human step. Anything else is saved to `support_case_drafts` for WF-05 human review. |
| [`WF-05-human-approval-gmail.json`](workflows/WF-05-human-approval-gmail.json) | WF-05 Human Approval | Webhook (`POST /webhook/approve-draft`) | Handles only the cases WF-04 couldn't confidently answer. Operator approves/edits/rejects the draft, updates DB state, sends the Gmail response if approved, logs an audit event. |
| [`WF-06-reconciliation.json`](workflows/WF-06-reconciliation.json) | WF-06 Reconciliation | Schedule Trigger (midnight UTC) | Daily ledger verification: calls `run_reconciliation` RPC (system-wide debits=credits, cached balances vs. ledger), alerts Ops on mismatch. Also runs `promote_minors_to_adult()` on the same schedule. |
| [`WF-08-joint-invitation-expiry-sweep.json`](workflows/WF-08-joint-invitation-expiry-sweep.json) | WF-08 Joint Invitation Expiry Sweep | Schedule (every minute) — **kept deactivated** | Fired unconditionally every minute regardless of need, which burns n8n Cloud's free-tier execution quota fast. Deactivated; the identical logic now runs opportunistically inside WF-00 (triggered by real mail only) at zero standing cost. Left here, deactivated, only for optional temporary reactivation during a live demo. |
| [`WF-09-seed-policy-documents.json`](workflows/WF-09-seed-policy-documents.json) | WF-09 Seed Policy Documents | Manual/one-time utility | Embeds the 13 policy documents in [`../docs/policies.md`](../docs/policies.md) into Pinecone. Insert-only (no id mapping) — see the update procedure documented there before re-running it against an already-seeded index. |

---

## System Architecture & Interaction Flow

```
                     CUSTOMER GMAIL
                          │
                          ▼ (Sends email to Bank Gmail)
                     BANK GMAIL
                          │
                          ▼ (Gmail Trigger — also opportunistically sweeps
                          │  expired joint invitations on every real email)
            WF-00 GMAIL FRONT DOOR / ROUTER
                          │
     ┌───────────┬────────┼────────┬───────────┬─────────────┐
     ▼           ▼        ▼        ▼           ▼             ▼
[Balance]   [Transfer] [Policy] [Open Acct] [Joint Invite] [Dispute/Other]
     │           │        │        │           │             │
  Format    WF-01 Transfer │  Supabase Auth  Email invite  Human-routed
 balances       │          │   Admin API    (5-min expiry)  acknowledgement
     │      WF-03 Fraud    │        │           │
     │          │      WF-04 RAG    ▼           ▼
     │     Execute Transfer │   New account   Accept/decline/
     │         RPC          │    created      expire handling
     │          │      Grounded &         │
     │          │      confident?    (all paths converge
     │          │       ┌───┴───┐     on a Gmail reply)
     │          │       ▼       ▼
     │          │    Send    Queue for
     │          │   directly WF-05 human
     │          │   (no human) approval
     ▼          ▼       │        │
  Gmail      Gmail      ▼        ▼
 Response   Response  Gmail   Operator approves →
                      Response   Gmail Response
```

---

## Required Credentials Configuration

Configure the following credentials in **n8n → Credentials**:

| Credential Name in n8n | Credential Type | Workflows Using It | Description |
|---|---|---|---|
| `Gmail account` | `gmailOAuth2` | WF-00, WF-01, WF-02, WF-03, WF-04, WF-05, WF-06 | Connected to the bank's own Gmail account. WF-04 sends grounded answers directly, so it needs this credential too, not just WF-05. |
| `Supabase account` | `supabaseApi` | WF-00, WF-01, WF-02, WF-03, WF-04, WF-05, WF-06, WF-08 | Supabase URL & Service Role Key / REST API key. |
| `Groq account` | `groqApi` | WF-04 | Groq API Key (LLM used for grounded drafting). |
| `Pinecone account` | `pineconeApi` | WF-04, WF-09 | Pinecone API Key (index: `banking-policy-index`, namespace: `banking_policy`, 3072 dimensions). |
| `Google Gemini API` | `googlePalmApi` | WF-04, WF-09 | Google Gemini API Key, model `gemini-embedding-001` (the older `text-embedding-004`/`embedding-001` models are retired — do not use them). |

### The two mailboxes

The system uses two Gmail addresses but **only one Gmail credential**:

| | Address | Role |
|---|---|---|
| **Bank inbox** | the account the `Gmail account` credential is connected to | The only address customers see. WF-00's Gmail Trigger polls it; every outbound email is sent from it. |
| **Ops inbox** | any second address you control | Receives every request that needs a human decision. The operator replies APPROVE or REJECT; that reply arrives at the **bank** inbox, where WF-00 matches the reference code and applies the decision. |

The ops inbox needs no credential and no trigger of its own — it is only ever a `sendTo` target and a reply-from address. That is deliberate: a second Gmail OAuth connection would have to be authorised by hand, and nothing here needs one.

**Both addresses are redacted in this repository** (`ops-team@yourbank.example` and `bank@yourbank.example`); the live n8n Cloud workflows use the real ones. After importing, set your real ops address in each of these:

| Workflow | Node | Field |
|---|---|---|
| WF-00 | `Detect Reference Reply` | the `OPS_TEAM_EMAIL` constant at the top of the Code node — **this one is the security check**, not just a destination: an `OPS-` reply is only honoured when the real Gmail sender matches it |
| WF-00 | `Alert Ops - Loan Pending Review`, `Confirm Decision to Ops Team`, `Send Ops Decision Problem Email`, `Alert Ops - Joint Transfer Fraud Block` | `sendTo` |
| WF-01 | `Email Ops - Transfer Failed Alert` | `sendTo` |
| WF-02 | `Email Ops Team - Standing Order Failed` | `sendTo` |
| WF-03 | `Email Ops - Fraud Hold Placed Alert` | `sendTo` |
| WF-04 | `Alert Ops - Policy Answer Needs Review` | `sendTo` |
| WF-06 | `Email Ops Team - Reconciliation Mismatch` | `sendTo` |

Do not point the ops address at the bank inbox itself. WF-00 would then read the bank's own alerts as ops replies.

---

## Import & Activation Procedure

1. **Import Workflows**:
   In n8n, click **Workflows → Import from File** and select each file in `n8n/workflows/`:
   - `WF-00-gmail-intake-router.json`
   - `WF-01-transfer.json`
   - `WF-02-standing-order-scheduler.json`
   - `WF-03-fraud-hold.json`
   - `WF-04-rag-support-case.json`
   - `WF-05-human-approval-gmail.json`
   - `WF-06-reconciliation.json`
   - `WF-08-joint-invitation-expiry-sweep.json` (import it, but leave it **deactivated** — see its row above)
   - `WF-09-seed-policy-documents.json`

2. **Set Environment Variables**:
   In n8n Settings → Environment Variables (or `.env`), set:
   ```env
   PYTHON_SERVICE_URL=https://your-deployed-service.example.com
   ```

3. **Seed the policy knowledge base**: run `WF-09` once (manually) against a freshly created/emptied Pinecone index before testing RAG support — see [`../docs/policies.md`](../docs/policies.md) for the exact documents and the update procedure for future changes.

4. **Activate Workflows** — recommended sequence:
   - `WF-06 Reconciliation` (safe background job)
   - `WF-02 Standing Orders` (safe background scheduler)
   - `WF-03 Fraud Hold` (sub-workflow)
   - `WF-01 Transfer` (sub-workflow)
   - `WF-04 RAG Support` (sub-workflow)
   - `WF-05 Human Approval` (approval gate)
   - `WF-00 Gmail Front Door` (main intake trigger)
   - Leave `WF-08` **deactivated** (see its row above for why)

---

## Real Gmail Testing Guide

### Test Setup & Identity Mapping

The database identifies customers by their registered email in the `profiles` table.
- Seeded test accounts:
  - `alice@test.banking` → Profile ID `a0000000-0000-0000-0000-000000000001` (Account `TEST-ALICE-001`, Balance: Rs 100,000.00)
  - `bob@test.banking` → Profile ID `b0000000-0000-0000-0000-000000000002` (Account `TEST-BOB-001`, Balance: Rs 50,000.00)
  - `charlie@test.banking` → Profile ID `c0000000-0000-0000-0000-000000000003` (Joint Account `TEST-JOINT-001`)

> **To test with your REAL Gmail account (e.g. `tester@gmail.com`):**
> Update the `profiles` table in Supabase to set `email = 'tester@gmail.com'` for Alice's profile ID (`a0000000-0000-0000-0000-000000000001`). When you send an email from `tester@gmail.com` to the Bank Gmail, n8n automatically extracts the actual sender, resolves Alice's profile, and authorizes access to `TEST-ALICE-001`.
>
> To test **without** any pre-existing profile at all (self-service account opening, or a public policy question), just email from any address — see Tests 8 and 4 below.

---

### Real Test Scenarios

#### TEST 1: Balance Inquiry (Authorized Customer)
- **From**: Real Tester Gmail (`alice@test.banking` or mapped real Gmail)
- **To**: Bank Gmail
- **Subject**: "Account Balance Check"
- **Body**: "Hi, what is my account balance?"
- **Expected Result**: An email listing `TEST-ALICE-001 (CHECKING, Role: primary): Rs 100,000.00 (Status: active)`.

#### TEST 2: Transfer Request (Atomic Transfer)
- **From**: Real Tester Gmail (`alice@test.banking` or mapped real Gmail)
- **To**: Bank Gmail
- **Subject**: "Send money"
- **Body**: "Please send 5000 rupees to account TEST-BOB-001"
- **Expected Result**:
  - `WF-00` classifies intent from the body (Rs 5,000 = 500,000 paisa) and recipient `TEST-BOB-001`.
  - Invokes `WF-01 Transfer`.
  - `initiate_transfer`/`execute_transfer` RPC moves Rs 5,000 atomically from Alice to Bob.
  - Received email confirmation with Transaction ID and completed status.

#### TEST 3: Idempotency Verification (Duplicate Protection)
- **Action**: Resend the exact same transfer email (or execute `WF-01` with an identical `idempotency_key`).
- **Expected Result**: The database idempotency table returns the existing completed transaction result without moving money a second time.

#### TEST 4: Policy & RAG Support Query — answered instantly, no account needed
- **From**: Any Gmail address, registered or not
- **To**: Bank Gmail
- **Subject**: "Wire Transfer Policy Inquiry"
- **Body**: "What are the wire transfer fee policies and daily limits?"
- **Expected Result**:
  - `WF-00` routes to `WF-04 RAG Support`.
  - LangChain agent searches Pinecone index `banking-policy-index`, finds `doc_wire_transfer_policy`.
  - Grounded, confident (≥0.7) → the customer receives the verified answer **directly, in one email** — no human step, no separate "we'll get back to you" receipt.

#### TEST 5: Human Approval Gate (only for what WF-04 couldn't confidently answer)
- **Setup**: Ask something the policy documents don't cover (e.g. "Do you offer mortgages?") so WF-04 returns `grounded=false`.
- **Expected Result**: Customer gets a receipt saying a specialist will follow up; a row appears in `support_case_drafts` with `human_review_state = 'pending'`.
- **Operator Action**: `POST /webhook/approve-draft`:
  ```json
  {
    "draft_id": "UUID_OF_PENDING_DRAFT",
    "action": "approve"
  }
  ```
- **Expected Result**: `WF-05` updates draft state to `approved` and case status to `resolved`, sends the final reply via Gmail, logs audit event `support_case_resolved`.

#### TEST 6: Unauthorized Access Attempt (Privacy Protection)
- **From**: Alice's Gmail
- **To**: Bank Gmail
- **Subject**: "Customer B Inquiry"
- **Body**: "Please tell me Customer B's balance for account TEST-BOB-001"
- **Expected Result**: `WF-00` checks authorization, detects Alice is NOT an account holder on `TEST-BOB-001`, rejects the request and sends a Security Denial email strictly to Alice. Zero data regarding Bob is disclosed.

#### TEST 7: Unregistered Sender — Self-Service Account Opening
- **From**: An unregistered Gmail address
- **To**: Bank Gmail
- **Subject**: "Account opening" (or similar)
- **Body**: "I'd like to open an account please"
- **Expected Result**: A new profile and PKR account are created (no manual KYC), and a welcome email is sent confirming the new account number and starting balance of Rs 0.00.

#### TEST 8: Unregistered Sender — Anything Else
- **From**: An unregistered Gmail address
- **To**: Bank Gmail
- **Subject**: "My Balance"
- **Expected Result**: "Your email address is not registered with any active customer account" (unless the body is actually a policy question, in which case it's routed to WF-04 instead — see TEST 4).

---

## Background Scheduled Processes

1. **WF-02 Standing Order Scheduler**: Runs hourly. Automatically executes recurring payments due for the current timestamp via `execute_standing_order` RPC.
2. **WF-06 Nightly Reconciliation**: Runs daily at midnight UTC. Executes `run_reconciliation` RPC to verify system debits equal credits and account cached balances match double-entry ledger totals; also promotes minors to adult accounts where due. Sends an email alert to Ops if a discrepancy is detected.
3. **Joint invitation expiry sweep**: no longer a standalone schedule (see WF-08's row above) — it runs opportunistically inside WF-00 on every real incoming email, at zero standing execution cost.

---

## Dependencies Summary

1. **Real Gmail Mapping**: Map a tester Gmail address to a row in Supabase's `profiles` table, or just email in unregistered to test self-service account opening / public RAG support.
2. **Python Fraud Service**: Reachable at `PYTHON_SERVICE_URL`. If unavailable, `WF-03` fails safe (a hold), never open (an approval).
3. **Pinecone Policy Documents**: The `banking-policy-index` (namespace `banking_policy`, 3072 dimensions) must be seeded via `WF-09` before RAG support queries will return grounded answers — see [`../docs/policies.md`](../docs/policies.md).

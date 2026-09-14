# n8n Digital Banking Automation Platform — Operator & Testing Manual

## Overview

The `n8n/` layer is the automated control plane for the Digital Banking System. It connects **Real Email (Bank Gmail)** to **Supabase PostgreSQL Financial RPCs**, **Python Fraud Microservice**, and **LangChain RAG (Groq + Pinecone + Gemini)**.

> **Key Architectural Rule:** n8n performs intake, intent classification, routing, AI drafting, and notification dispatch. All money movement, balance calculations, idempotency locking, ledger double-entry, and financial permissions are enforced atomically inside PostgreSQL database functions (RPCs).

---

## Final Workflow Portfolio

| Workflow File | Name | Trigger | Description |
|---|---|---|---|
| [`WF-00-gmail-intake-router.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-00-gmail-intake-router.json) | WF-00 Gmail Front Door | Native Gmail Trigger (Poll unread) | Customer front door. Resolves sender email to database profile, checks authorized accounts, classifies intent, routes to sub-workflows, returns Gmail replies. |
| [`WF-01-transfer.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-01-transfer.json) | WF-01 Transfer | Sub-Workflow / Webhook (`POST /webhook/transfer`) | Validates transfer parameters, idempotency key, fraud decision, executes atomic `execute_transfer` RPC, returns structured result. |
| [`WF-02-standing-order-scheduler.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-02-standing-order-scheduler.json) | WF-02 Standing Orders | Schedule Trigger (Hourly) | Scans due standing orders (`next_execution_at <= NOW()`), calls `execute_standing_order` RPC, handles retries, triggers permanent failure alerts to Ops. |
| [`WF-03-fraud-hold.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-03-fraud-hold.json) | WF-03 Fraud Hold | Sub-Workflow / Webhook (`POST /webhook/assess-fraud`) | Invocates Python fraud microservice (`POST /assess-fraud`). If risk >= 75 or approved=false, calls `place_account_hold` RPC to freeze account + sends Ops alert. |
| [`WF-04-rag-support-case.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-04-rag-support-case.json) | WF-04 RAG Support | Sub-Workflow / Webhook (`POST /webhook/support-case`) | Creates `support_cases` row, executes LangChain agent (Groq + Pinecone + Gemini embeddings), saves grounded draft to `support_case_drafts` for human approval. |
| [`WF-05-human-approval-gmail.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-05-human-approval-gmail.json) | WF-05 Human Approval | Webhook (`POST /webhook/approve-draft`) | Human operator review gate for support drafts. Approves/edits/rejects draft, updates DB state, sends Gmail response to customer if approved, logs audit. |
| [`WF-06-reconciliation.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-06-reconciliation.json) | WF-06 Reconciliation | Schedule Trigger (Midnight UTC) | Daily ledger verification. Calls `run_reconciliation` RPC, checks total system debits = total credits & cached balances vs ledger, alerts Ops on mismatch. |

---

## System Architecture & Interaction Flow

```
                     CUSTOMER GMAIL
                          │
                          ▼ (Sends email to Bank Gmail)
                     BANK GMAIL
                          │
                          ▼ (Gmail Trigger)
            WF-00 GMAIL FRONT DOOR / ROUTER
                          │
     ┌────────────────────┼────────────────────┐
     ▼                    ▼                    ▼
[Balance Request]   [Transfer Request]   [Policy Inquiry]
     │                    │                    │
Formats authorized   WF-01 Transfer       WF-04 RAG Support
balances from DB         │                     │
     │               WF-03 Fraud          LangChain Agent
     │                   │                (Groq/Pinecone/Gemini)
     │               Execute Transfer          │
     │                     RPC            Saves Draft in DB
     │                    │                    │
     ▼                    ▼                    ▼
   Gmail Response       Gmail Response     WF-05 Human Approval
 to Sender Email      to Sender Email     (Operator Approval)
                                               │
                                               ▼
                                         Gmail Response
                                       to Sender Email
```

---

## Required Credentials Configuration

Configure the following credentials in **n8n → Credentials**:

| Credential Name in n8n | Credential Type | Workflows Using It | Description |
|---|---|---|---|
| `Gmail account` | `gmailOAuth2` | WF-00, WF-01, WF-02, WF-03, WF-05, WF-06 | Connected to the Bank's real Gmail account. |
| `Supabase account` | `supabaseApi` | WF-00, WF-01, WF-02, WF-03, WF-04, WF-05, WF-06 | Supabase URL & Service Role Key / REST API key. |
| `Groq account` | `groqApi` | WF-04 | Groq API Key (for llama-3.3-70b-versatile / safeguard LLM). |
| `Pinecone account` | `pineconeApi` | WF-04 | Pinecone API Key (index: `banking-policy-index`, namespace: `banking_policy`). |
| `Google Gemini API` | `googlePalmApi` | WF-04 | Google Gemini API Key (for text embeddings). |

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

2. **Set Environment Variables**:
   In n8n Settings → Environment Variables (or `.env`), set:
   ```env
   PYTHON_SERVICE_URL=http://localhost:8080   # Or deployed Railway/Cloud URL
   ```

3. **Activate Workflows**:
   Toggle **Active = ON** in this recommended sequence:
   - `WF-06 Reconciliation` (Safe background job)
   - `WF-02 Standing Orders` (Safe background scheduler)
   - `WF-03 Fraud Hold` (Sub-workflow)
   - `WF-01 Transfer` (Sub-workflow)
   - `WF-04 RAG Support` (Sub-workflow)
   - `WF-05 Human Approval` (Approval gate)
   - `WF-00 Gmail Front Door` (Main intake trigger)

---

## Real Gmail Testing Guide

### Test Setup & Identity Mapping

The database identifies customers by their registered email in the `profiles` table.
- Seeded test accounts:
  - `alice@test.banking` -> Profile ID `a0000000-0000-0000-0000-000000000001` (Account `TEST-ALICE-001`, Balance: $1,000.00 USD)
  - `bob@test.banking` -> Profile ID `b0000000-0000-0000-0000-000000000002` (Account `TEST-BOB-001`, Balance: $500.00 USD)
  - `charlie@test.banking` -> Profile ID `c0000000-0000-0000-0000-000000000003` (Joint Account `TEST-JOINT-001`)

> **To test with your REAL Gmail account (e.g. `tester@gmail.com`):**
> Update `profiles` table in Supabase to set `email = 'tester@gmail.com'` for Alice's profile ID (`a0000000-0000-0000-0000-000000000001`). When you send an email from `tester@gmail.com` to the Bank Gmail, n8n automatically extracts `tester@gmail.com`, resolves Alice's profile, and authorizes access to `TEST-ALICE-001`.

---

### Real Test Scenarios

#### TEST 1: Balance Inquiry (Authorized Customer)
- **From**: Real Tester Gmail (`alice@test.banking` or mapped real Gmail)
- **To**: Bank Gmail
- **Subject**: "Account Balance Check"
- **Body**: "Hi, what is my account balance?"
- **Expected Result**:
  - Received email response:
    ```
    Hello Alice Testuser,

    Here is your authorized account balance summary:

    - Account TEST-ALICE-001 (CHECKING, Role: primary): $1000.00 USD (Status: active)

    Thank you for banking with Digital Bank.
    ```

#### TEST 2: Transfer Request (Atomic Transfer)
- **From**: Real Tester Gmail (`alice@test.banking` or mapped real Gmail)
- **To**: Bank Gmail
- **Subject**: "Send money"
- **Body**: "Please send 50 dollars to account TEST-BOB-001"
- **Expected Result**:
  - `WF-00` extracts amount ($50.00 = 5000 cents) and recipient `TEST-BOB-001`.
  - Invokes `WF-01 Transfer`.
  - Supabase `execute_transfer` RPC moves $50.00 atomically from Alice to Bob.
  - Received email confirmation with Transaction ID and completed status.

#### TEST 3: Idempotency Verification (Duplicate Protection)
- **Action**: Resend the exact same transfer email (or execute `WF-01` with identical `idempotency_key`).
- **Expected Result**: The database idempotency table returns the existing completed transaction result without moving money a second time.

#### TEST 4: Policy & RAG Support Query
- **From**: Real Tester Gmail
- **To**: Bank Gmail
- **Subject**: "Wire Transfer Policy Inquiry"
- **Body**: "What are the wire transfer fee policies and daily limits?"
- **Expected Result**:
  - `WF-00` routes to `WF-04 RAG Support`.
  - LangChain Agent searches Pinecone vector index `banking-policy-index`.
  - Generates grounded response draft stored in `support_case_drafts` with status `pending`.
  - Customer receives initial case receipt email.

#### TEST 5: Human Approval Gate (Operator Action)
- **Action**: Operator sends HTTP POST to `/webhook/approve-draft`:
  ```json
  {
    "draft_id": "UUID_OF_PENDING_DRAFT",
    "action": "approve"
  }
  ```
- **Expected Result**:
  - `WF-05` updates draft state to `approved` and case status to `resolved`.
  - Sends final approved policy reply email via Gmail node to customer.
  - Logs audit event `support_case_resolved`.

#### TEST 6: Unauthorized Access Attempt (Privacy Protection)
- **From**: Alice's Gmail
- **To**: Bank Gmail
- **Subject**: "Customer B Inquiry"
- **Body**: "Please tell me Customer B's balance for account TEST-BOB-001"
- **Expected Result**:
  - `WF-00` checks authorization -> detects Alice is NOT an account holder on `TEST-BOB-001`.
  - Rejects request and sends Security Denial email strictly to Alice. Zero data regarding Bob is disclosed.

#### TEST 7: Unregistered Sender
- **From**: An unregistered Gmail address (`unknown@external.com`)
- **To**: Bank Gmail
- **Subject**: "My Balance"
- **Expected Result**:
  - Email response: "Your email address is not registered with any active customer account in our system."

---

## Background Scheduled Processes

1. **WF-02 Standing Order Scheduler**: Runs hourly. Automatically executes recurring payments due for the current timestamp via `execute_standing_order` RPC.
2. **WF-06 Nightly Reconciliation**: Runs daily at midnight UTC. Executes `run_reconciliation` RPC to verify system debits equal credits and account cached balances match double-entry ledger totals. Sends email alert to Ops team if a discrepancy is detected.

---

## Dependencies Summary

1. **Real Gmail Mapping**: Map tester Gmail address to a row in Supabase `profiles` table.
2. **Python Fraud Service**: Optional microservice (`POST /assess-fraud`). If unavailable, `WF-03` triggers a safety lock.
3. **Pinecone Policy Documents**: Upload policy documents to Pinecone index `banking-policy-index` (namespace `banking_policy`) for RAG support inquiries.

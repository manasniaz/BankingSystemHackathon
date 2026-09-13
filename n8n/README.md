# n8n Workflows — Digital Banking Backend & Ops Automation

This directory contains the production-grade **n8n Cloud MVP workflows** for the Digital Banking Backend & Ops Automation system.

> [!CAUTION]
> **SECURITY NOTICE — TRUSTED ORCHESTRATION LAYER ONLY**
> Webhook endpoints in these workflows trigger high-privilege financial PostgreSQL RPC operations (such as `execute_transfer` and `place_account_hold`).
> These webhooks are intended solely for **internal/trusted orchestration** within the banking architecture.
> **DO NOT** expose these webhooks directly to the public internet as unauthenticated APIs. All public client access must pass through API Gateway authentication, rate limiting, and RBAC authorization guards.

---

## 1. Architecture & Non-Negotiable Financial Rules

1. **Financial Source of Truth**: Supabase PostgreSQL (`001_initial_banking_schema.sql`, `002_security_hardening.sql`) is the sole financial source of truth. n8n workflows **never** calculate balances, perform credit/debit logic, or execute direct DML on financial tables (`accounts`, `ledger_entries`, `transactions`).
2. **PostgreSQL RPC Contract**: Money movement and account state mutations are executed exclusively via atomic PostgreSQL RPC functions (`execute_transfer`, `execute_standing_order`, `place_account_hold`, `run_reconciliation`).
3. **No Hardcoded Secrets / Credentials Unconfigured**: Workflows contain zero hardcoded service_role keys, database passwords, or API tokens. Credential properties in all JSON workflows are left unconfigured so you can attach your credentials manually in n8n Cloud after importing.
4. **Deterministic Fraud Scoring**: LLMs are **NEVER** used to assess fraud. Fraud scoring is calculated deterministically by Python services (`PYTHON_SERVICE_URL`), and holds are placed via `place_account_hold` RPC.
5. **Human Approval Safety Boundary**: AI draft responses (Groq) for customer support cases **MUST** pass through explicit human approval (WF-05). No AI draft is ever dispatched automatically to Gmail.
6. **Reconciliation Safety**: Nightly reconciliation (WF-06) checks system-wide debits vs. credits and account balance integrity. It alerts ops on mismatches and **NEVER** alters balances automatically to hide discrepancies.

---

## 2. Complete Workflow Inventory

| ID | Workflow File | Description | Status |
|---|---|---|---|
| **WF-01** | [`WF-01-transfer.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-01-transfer.json) | Orchestrates atomic funds transfer via Supabase `execute_transfer()` RPC with input validation, business error classification, and idempotency guarantees. | ✅ Implemented & Statically Validated |
| **WF-02** | [`WF-02-standing-order-scheduler.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-02-standing-order-scheduler.json) | Hourly scheduler fetching due active standing orders and executing them via `execute_standing_order()` RPC. Enforces 3-retry max policy, stale-lock safety, and real alert dispatch. | ✅ Implemented & Statically Validated |
| **WF-03** | [`WF-03-fraud-hold.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-03-fraud-hold.json) | Triggers Python deterministic fraud service (`PYTHON_SERVICE_URL`). Validates response schema. If risk threshold is exceeded, places full account freeze via `place_account_hold()` RPC. | ✅ Implemented & Statically Validated |
| **WF-04** | [`WF-04-rag-support-case.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-04-rag-support-case.json) | RAG Support Case Desk. Generates query vector, queries Pinecone vector index for policy docs. If similarity >= 0.75, drafts reply via Groq LLM; otherwise uses human-review fallback draft. Saves to `support_case_drafts`. | ✅ Implemented & Statically Validated |
| **WF-05** | [`WF-05-human-approval-gmail.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-05-human-approval-gmail.json) | Mandatory human approval gate. Fetches actual draft from DB, verifies pending state, fetches trusted customer email from DB. If approved, resolves case and emails customer via Gmail. If rejected, updates case status to closed without sending email. | ✅ Implemented & Statically Validated |
| **WF-06** | [`WF-06-reconciliation.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-06-reconciliation.json) | Scheduled nightly reconciliation calling `run_reconciliation()` RPC. Logs pass or dispatches real ops alert on debit/credit mismatch. | ✅ Implemented & Statically Validated |

---

## 3. n8n Cloud Configuration & Credentials Setup

### Environment Variables (`$vars`)
Configure these in n8n Cloud under **Settings → Environment Variables**:

| Variable Name | Description | Example Value |
|---|---|---|
| **`SUPABASE_URL`** | Base URL of your Supabase Cloud project | `https://xyzcompany.supabase.co` |
| **`PYTHON_SERVICE_URL`** | Base URL of the Python deterministic fraud service | `https://fraud-service.railway.app` |
| **`EMBEDDING_SERVICE_URL`** | URL of text embedding service (e.g. OpenAI / Python service) | `https://api.openai.com/v1/embeddings` |
| **`PINECONE_INDEX_URL`** | Base URL of the Pinecone vector search index | `https://banking-policy-index.pinecone.io` |
| **`ALERT_WEBHOOK_URL`** | External webhook endpoint for Ops failure/mismatch alerts | `https://alerts.ops.internal/notify` |

### Required Credentials to Manually Connect After Import

1. **Supabase Service Role Credential** (`httpCustomAuth`):
   - **Header 1**: `apikey` = `<SUPABASE_SERVICE_ROLE_KEY>`
   - **Header 2**: `Authorization` = `Bearer <SUPABASE_SERVICE_ROLE_KEY>`
   - Attach to HTTP nodes querying/updating Supabase REST API or calling RPCs in WF-01, WF-02, WF-03, WF-04, WF-05, WF-06.

2. **Embedding API Credential** (`httpCustomAuth` or OpenAI):
   - **Header 1**: `Authorization` = `Bearer <OPENAI_API_KEY>` (or embedding provider key).
   - Attach to `Generate Inquiry Embedding Vector` node in WF-04.

3. **Pinecone Credential** (`httpCustomAuth`):
   - **Header 1**: `Api-Key` = `<PINECONE_API_KEY>`
   - Attach to `Query Pinecone Vector Index` node in WF-04.

4. **Groq API Credential** (`httpCustomAuth`):
   - **Header 1**: `Authorization` = `Bearer <GROQ_API_KEY>`
   - Attach to `Generate Policy Grounded Draft via Groq` node in WF-04.

5. **Gmail OAuth2 Credential** (`gmailOAuth2`):
   - Configured via n8n Gmail OAuth setup.
   - Attach to `Send Customer Email via Gmail` node in WF-05.

---

## 4. Workflow Import & Activation Instructions

1. **Log in to n8n Cloud**.
2. For each JSON workflow file in `n8n/workflows/`:
   - Click **Workflows → Import from File**.
   - Select the desired workflow JSON file (e.g. `WF-01-transfer.json`).
3. **Manually Select & Attach Credentials**:
   - Open HTTP Request & Gmail nodes in the imported workflow.
   - Select your configured credentials from the dropdown.
4. **Set Activation State**:
   - Toggle the workflow switch to **Active**.

---

## 5. Testing & Verification Procedures

### WF-01: Transfer Webhook
```bash
curl -X POST "https://<your-n8n-instance>.app.n8n.cloud/webhook/transfer" \
  -H "Content-Type: application/json" \
  -d '{
    "source_account_id": "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    "destination_account_id": "b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22",
    "amount": 1000,
    "currency": "USD",
    "idempotency_key": "idem-key-001",
    "initiated_by_profile_id": "c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33",
    "fraud_assessment_id": "d0eebc99-9c0b-4ef8-bb6d-6bb9bd380a44"
  }'
```

### WF-03: Fraud Hold Webhook
```bash
curl -X POST "https://<your-n8n-instance>.app.n8n.cloud/webhook/assess-fraud" \
  -H "Content-Type: application/json" \
  -d '{
    "account_id": "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    "amount": 500000,
    "currency": "USD",
    "profile_id": "c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33"
  }'
```

### WF-04: RAG Support Case Webhook
```bash
curl -X POST "https://<your-n8n-instance>.app.n8n.cloud/webhook/support-case" \
  -H "Content-Type: application/json" \
  -d '{
    "profile_id": "c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33",
    "subject": "Wire Transfer Limits",
    "inquiry": "What is the daily maximum limit for international wire transfers?"
  }'
```

### WF-05: Human Approval Webhook
```bash
curl -X POST "https://<your-n8n-instance>.app.n8n.cloud/webhook/approve-draft" \
  -H "Content-Type: application/json" \
  -d '{
    "draft_id": "e0eebc99-9c0b-4ef8-bb6d-6bb9bd380a55",
    "action": "approve",
    "reviewer_profile_id": "c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33"
  }'
```

---

## 6. Implementation & Validation Disclosure

- **Status**: Implemented & Statically Validated.
- All 6 workflows have undergone static schema analysis, JSON syntax parsing, node connectivity verification, and secret scans via `validate_n8n.py`.
- *Note: Live execution in an active n8n Cloud tenant requires manual import and credential binding as detailed above.*

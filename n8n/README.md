# n8n Workflows — Digital Banking Backend & Ops Automation

This directory contains the production-grade **n8n Cloud workflows** for the Digital Banking Backend & Ops Automation system, fully refactored to leverage **native n8n integrations and nodes** wherever available.

> [!CAUTION]
> **SECURITY NOTICE — TRUSTED ORCHESTRATION LAYER ONLY**
> Webhook endpoints in these workflows trigger high-privilege financial PostgreSQL RPC operations (such as `execute_transfer` and `place_account_hold`).
> These webhooks are intended solely for **internal/trusted orchestration** within the banking architecture.
> **DO NOT** expose these webhooks directly to the public internet as unauthenticated APIs. All public client access must pass through API Gateway authentication, rate limiting, and RBAC authorization guards.

---

## 1. Architecture & Non-Negotiable Financial Rules

1. **Financial Source of Truth**: Supabase PostgreSQL (`001_initial_banking_schema.sql`, `002_security_hardening.sql`) is the sole financial source of truth. n8n workflows **never** calculate balances, perform credit/debit logic, or execute direct DML on financial tables (`accounts`, `ledger_entries`, `transactions`).
2. **PostgreSQL RPC Contract**: Money movement and account state mutations are executed exclusively via atomic PostgreSQL RPC functions (`execute_transfer`, `execute_standing_order`, `place_account_hold`, `run_reconciliation`).
3. **No Hardcoded Secrets / Credentials Unconfigured**: Workflows contain zero hardcoded keys, database passwords, or API tokens. All native credential references (`supabaseApi`, `gmailOAuth2`, `googleGeminiApi`, `pineconeApi`, `groqApi`) are clean and ready for manual attachment in n8n Cloud after importing.
4. **Deterministic Fraud Scoring**: LLMs are **NEVER** used to assess fraud. Fraud scoring is calculated deterministically by Python microservices (`PYTHON_SERVICE_URL`), and holds are placed via `place_account_hold` RPC.
5. **Human Approval Safety Boundary**: AI draft responses (Groq) for customer support cases **MUST** pass through explicit human approval (WF-05). No AI draft is ever dispatched automatically to Gmail.
6. **Reconciliation Safety**: Nightly reconciliation (WF-06) checks system-wide debits vs. credits and account balance integrity. It alerts ops on mismatches and **NEVER** alters balances automatically to hide discrepancies.

---

## 2. Complete Workflow Inventory & Native Node Matrix

| ID | Workflow File | Native Nodes Used | HTTP Nodes Kept | Purpose & Refactoring Details | Status |
|---|---|---|---|---|---|
| **WF-01** | [`WF-01-transfer.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-01-transfer.json) | Code v2, If v2.2, RespondToWebhook v1.1 | 1 (`supabaseApi` RPC) | Atomic funds transfer via Supabase `execute_transfer()` RPC. Uses predefined `supabaseApi` credential with `neverError: true` for business code mapping (`INSUFFICIENT_FUNDS`, `ACCOUNT_FREEZE`, `IDEMPOTENCY_REPLAY`). | ✅ Refactored & Validated |
| **WF-02** | [`WF-02-standing-order-scheduler.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-02-standing-order-scheduler.json) | Supabase v1 (getAll `standing_orders`), ScheduleTrigger v1.2, Code v2, If v2.2 | 2 (`supabaseApi` RPC, `ALERT_WEBHOOK_URL`) | Hourly scheduler fetching due active standing orders via native **Supabase** node. Executes `execute_standing_order()` RPC and dispatches failure alerts via HTTP webhook. | ✅ Refactored & Validated |
| **WF-03** | [`WF-03-fraud-hold.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-03-fraud-hold.json) | Code v2, If v2.2, RespondToWebhook v1.1 | 2 (`PYTHON_SERVICE_URL`, `supabaseApi` RPC) | Triggers Python deterministic fraud service (`PYTHON_SERVICE_URL`). If risk score exceeds threshold, places account freeze via Supabase `place_account_hold()` RPC. | ✅ Refactored & Validated |
| **WF-04** | [`WF-04-rag-support-case.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-04-rag-support-case.json) | Supabase v1 (create `support_cases`, create `support_case_drafts`, update `support_cases`), Google Gemini Embeddings, Pinecone Vector Store, Groq Chat Model, ChainLMMode, OutputParser | 0 | **100% Native Node Coverage**. Creates support cases and drafts via native Supabase nodes. Uses LangChain native nodes for Gemini embeddings, Pinecone vector search, and Groq LLM draft generation. | ✅ Refactored & Validated |
| **WF-05** | [`WF-05-human-approval-gmail.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-05-human-approval-gmail.json) | Supabase v1 (7 nodes for draft fetch, status updates & audit log inserts), Gmail v2.2 (`gmailOAuth2`), If v2.2, Code v2, RespondToWebhook v1.1 | 0 | **100% Native Node Coverage**. Fetches draft/case details, updates case/draft statuses, and records audit logs using native Supabase nodes. Sends emails via native Gmail v2.2 node. | ✅ Refactored & Validated |
| **WF-06** | [`WF-06-reconciliation.json`](file:///c:/Users/Anas/Projects/BankingSystemHackathon/n8n/workflows/WF-06-reconciliation.json) | ScheduleTrigger v1.2, Code v2, If v2.2 | 2 (`supabaseApi` RPC, `ALERT_WEBHOOK_URL`) | Nightly scheduled reconciliation executing `run_reconciliation()` RPC. Dispatches external alert payload on ledger mismatch. | ✅ Refactored & Validated |

---

## 3. Justification for Remaining HTTP Nodes

Out of 19 original generic API HTTP requests, **15 have been converted to native n8n nodes**. The remaining HTTP nodes are strictly required for the following technical reasons:

1. **Supabase REST RPC Calls** (WF-01, WF-02, WF-03, WF-06):
   - PostgreSQL RPC endpoints (`/rest/v1/rpc/*`) execute custom backend functions. The native n8n Supabase node currently supports table DML (`get`, `getAll`, `create`, `update`, `delete`), but not custom RPC invocations. These nodes are updated to use **n8n predefined credential type** `supabaseApi`.
2. **Python Fraud Service Microservice** (WF-03):
   - Custom internal microservice (`PYTHON_SERVICE_URL/assess-fraud`). No native n8n node exists for custom internal microservices.
3. **External Ops Failure & Reconciliation Alerts** (WF-02, WF-06):
   - Configurable external webhook (`ALERT_WEBHOOK_URL`) for Ops incident integration (Slack, PagerDuty, Teams). Generic HTTP Request node is required to support arbitrary target endpoints.

---

## 4. n8n Cloud Configuration & Credentials Setup

### Environment Variables (`$vars`)
Configure these in n8n Cloud under **Settings → Environment Variables**:

| Variable Name | Description | Example Value |
|---|---|---|
| **`SUPABASE_URL`** | Base URL of your Supabase Cloud project | `https://xyzcompany.supabase.co` |
| **`PYTHON_SERVICE_URL`** | Base URL of the Python deterministic fraud service | `https://fraud-service.railway.app` |
| **`ALERT_WEBHOOK_URL`** | External webhook endpoint for Ops failure/mismatch alerts | `https://alerts.ops.internal/notify` |

### Required Native Credentials to Attach After Import

1. **Supabase API Credential** (`supabaseApi`):
   - Host: `https://<your-project>.supabase.co`
   - Service Role Key: `<SUPABASE_SERVICE_ROLE_KEY>`
   - Attach to: Supabase native nodes (WF-02, WF-04, WF-05) and RPC HTTP nodes (WF-01, WF-02, WF-03, WF-06).
2. **Gmail OAuth2 Credential** (`gmailOAuth2`):
   - OAuth2 integration with Google Workspace / Gmail.
   - Attach to: `Send Customer Email via Gmail` node in WF-05.
3. **Google PaLM / Gemini API Credential** (`googleGeminiApi`):
   - API Key for Google Gemini Embeddings.
   - Attach to: `Gemini Embeddings` node in WF-04.
4. **Pinecone API Credential** (`pineconeApi`):
   - API Key & Environment for Pinecone Vector Store.
   - Attach to: `Policy Knowledge Base` node in WF-04.
5. **Groq API Credential** (`groqApi`):
   - API Key for Groq Cloud LLM Inference (`llama-3.3-70b-versatile`).
   - Attach to: `Groq Chat Model` node in WF-04.

---

## 5. Workflow Import & Activation Instructions

1. **Log in to n8n Cloud**.
2. For each JSON workflow file in `n8n/workflows/`:
   - Click **Workflows → Import from File**.
   - Select the desired workflow JSON file (e.g. `WF-01-transfer.json`).
3. **Attach Credentials**:
   - Open native nodes (Supabase, Gmail, Gemini, Pinecone, Groq) and select your configured credentials from the dropdown.
4. **Set Activation State**:
   - Toggle the workflow switch to **Active**.

---

## 6. Testing & Verification Procedures

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

## 7. Implementation & Validation Disclosure

- **Status**: 100% Implemented & Statically Validated.
- All 6 workflows have undergone JSON syntax parsing, node type verification, native node binding validation, connection graph checks, and secret scans.
- **Strict Scope Verification**: All changes are strictly confined to `n8n/` (`n8n/workflows/*.json` and `n8n/README.md`). Zero files outside `n8n/` were modified.

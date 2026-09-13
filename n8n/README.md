# n8n Workflows — Digital Banking & Ops Automation

This directory contains the n8n Cloud orchestration workflows for the Digital Banking Backend & Ops Automation system.

> [!CAUTION]
> **SECURITY NOTICE — INTERNAL / TRUSTED USE ONLY**
> Webhook endpoints in these workflows trigger high-privilege financial PostgreSQL RPC operations (such as `execute_transfer`).
> These webhooks are intended solely for **internal/trusted orchestration** within the banking backend architecture.
> **DO NOT** expose these webhooks directly to the public internet as unauthenticated banking APIs. All public client access must go through API Gateway authentication, rate limiting, and RBAC authorization guards.

---

## Architecture & Principles

1. **Financial Source of Truth**: Supabase PostgreSQL is the sole financial source of truth. n8n workflows **never** calculate balances, determine transfer validity, or perform direct DML on financial tables.
2. **PostgreSQL RPC Contract**: Money movement is executed exclusively via atomic PostgreSQL RPC functions (`execute_transfer`).
3. **No Hardcoded Secrets**: Workflows contain zero hardcoded service_role keys, database passwords, or API tokens. All credentials must be configured within n8n Cloud.

---

## Workflow Inventory

| ID | Workflow Name | Description | Status |
|---|---|---|---|
| **WF-01** | `WF-01-transfer.json` | Orchestrates atomic funds transfers via Supabase `execute_transfer()` RPC | ✅ Implemented |
| **WF-02** | `WF-02-standing-order.json` | Standing Order Scheduler & Execution | ⏳ Planned |
| **WF-03** | `WF-03-fraud-hold.json` | Deterministic Fraud Scoring & Account Hold Trigger | ⏳ Planned |
| **WF-04** | `WF-04-rag-support.json` | Pinecone RAG + Groq Support Ticket Case Handling | ⏳ Planned |
| **WF-05** | `WF-05-human-approval-gmail.json` | Human Approval & Gmail Customer Notifications | ⏳ Planned |
| **WF-06** | `WF-06-reconciliation.json` | Nightly Reconciliation Trigger & Ledger Balance Verification | ⏳ Planned |

---

## WF-01 Transfer Details

### Webhook Endpoint
* **HTTP Method**: `POST`
* **Path**: `/webhook/transfer`

### Expected Webhook Request Payload
```json
{
  "source_account_id": "UUID",
  "destination_account_id": "UUID",
  "amount": 1000,
  "currency": "USD",
  "idempotency_key": "unique-key-12345",
  "initiated_by_profile_id": "UUID",
  "fraud_assessment_id": "UUID"
}
```
*Note: `amount` must be a positive integer in minor units/cents (e.g. 1000 = $10.00) matching PostgreSQL `BIGINT`.*

### Supabase RPC Call
* **Endpoint**: `POST {{ $vars.SUPABASE_URL }}/rest/v1/rpc/execute_transfer`
* **Target Function**: `public.execute_transfer(p_source_account_id, p_destination_account_id, p_amount, p_currency, p_idempotency_key, p_initiated_by_profile_id, p_fraud_assessment_id)`

### Returned Structure from `execute_transfer()`
* **Success Payload** (`HTTP 200`):
  ```json
  {
    "success": true,
    "transaction_id": "<UUID>",
    "status": "completed",
    "amount": 1000,
    "currency": "USD",
    "source_account_id": "<UUID>",
    "destination_account_id": "<UUID>"
  }
  ```
* **Business Error Payload** (`HTTP 422`):
  ```json
  {
    "success": false,
    "error": "Fraud assessment has expired or is invalid",
    "idempotency_key": "unique-key-12345"
  }
  ```

---

## Error Classification Policy

| HTTP Status | Error Type | Cause / Trigger |
|---|---|---|
| **200 OK** | Success | Transfer executed & committed successfully by PostgreSQL function |
| **400 Bad Request** | Schema/Validation Error | Malformed input body, missing fields, invalid UUID formats, or non-positive amount |
| **422 Unprocessable Entity** | Business Rule Rejection | Valid input schema, but PostgreSQL function rejected transfer (e.g., fraud expired, insufficient balance, active hold, idempotency key mismatch, concurrent transaction lock) |
| **500 Internal Server Error** | System/Infrastructure Error | Unexpected HTTP 5xx network failure, unhandled node exception, or unconfigured `SUPABASE_URL` |

---

## n8n Cloud Configuration Requirements

### 1. Variables
* **`SUPABASE_URL`**: Your Supabase project URL (e.g. `https://<project-ref>.supabase.co`).
  * *No fallback URL is provided; missing variable causes immediate clean failure.*

### 2. Credentials
Create a Custom Auth credential in n8n Cloud named `Supabase Service Role Credential` (`httpCustomAuth`):
* **Header 1**: `apikey` = `<SUPABASE_SERVICE_ROLE_KEY>`
* **Header 2**: `Authorization` = `Bearer <SUPABASE_SERVICE_ROLE_KEY>`

---

## How to Import & Test WF-01

1. **Import Workflow**:
   - In n8n Cloud, go to **Workflows** → **Import from File** → Select `n8n/workflows/WF-01-transfer.json`.
   - Attach your `Supabase Service Role Credential` to the **Execute Supabase RPC execute_transfer** node.
   - Activate the workflow.

2. **Trigger Webhook**:
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

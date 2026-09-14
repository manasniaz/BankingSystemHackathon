# n8n Workflows — Digital Banking Backend + Ops Automation

## Overview

This directory contains 6 n8n workflows that orchestrate the banking system.
**n8n is the control plane only — it never performs financial calculations or holds financial state.**

All money movement, balance updates, ledger entries, idempotency, and audit logging
happen inside Supabase PostgreSQL functions (RPCs). n8n calls those RPCs and handles
scheduling, routing, notifications, and the RAG support pipeline.

---

## Architecture Principle

```
Customer / Schedule / Event
        ↓
      n8n
        ↓ (Supabase RPC or Supabase node)
  PostgreSQL function
        ↓
  Ledger + Balance + Audit (all atomic)
```

n8n **never** directly updates `accounts`, `ledger_entries`, `transactions`, or `audit_log`.

---

## Workflow Summary

### WF-01 — Transfer
**Trigger:** POST webhook at `/webhook/transfer`

**What it does:**
1. Validates all 7 required fields (source/dest account UUIDs, amount, currency, idempotency key, profile ID, fraud assessment ID)
2. Calls the `execute_transfer` PostgreSQL RPC — this is where the money actually moves
3. The RPC handles: idempotency check, row locking, fraud assessment verification, balance check, debit + credit ledger entries, cached balance update, audit log — all atomically
4. On success: returns `{ success: true, transaction_id, status: "completed" }`
5. On business error (e.g. insufficient funds): returns HTTP 422, sends Gmail notification to ops
6. On system error: returns HTTP 500, sends Gmail notification to ops

**Where transactions are processed:** Inside `execute_transfer()` PostgreSQL function — never in n8n.

**Required input:**
```json
{
  "source_account_id": "UUID",
  "destination_account_id": "UUID",
  "amount": 1000,
  "currency": "USD",
  "idempotency_key": "unique-string",
  "initiated_by_profile_id": "UUID",
  "fraud_assessment_id": "UUID"
}
```

---

### WF-02 — Standing Order Scheduler
**Trigger:** Schedule (every hour)

**What it does:**
1. Queries Supabase for all standing orders where `status = active` AND `next_execution_at <= now`
2. Processes each due order one at a time (batch size 1)
3. Calls `execute_standing_order` RPC for each — the RPC handles locking, idempotency, money movement, retry count, and permanent failure marking
4. If an order reaches 3 failed retries and is marked `failed`, sends a Gmail alert to ops

**Where transactions are processed:** Inside `execute_standing_order()` PostgreSQL function.

**Note:** Weekend/holiday rules can be added by inserting an IF node after the schedule trigger that checks `$now.weekday` before querying. Not implemented for MVP.

---

### WF-03 — Fraud Assessment & Account Hold
**Trigger:** POST webhook at `/webhook/assess-fraud`

**What it does:**
1. Validates account_id and amount
2. Calls the **Python fraud service** at `$vars.PYTHON_SERVICE_URL/assess-fraud`
3. Validates the Python response schema (must return `approved`, `risk_score`, `fraud_assessment_id`)
4. If `approved === false` OR `risk_score >= 75`: calls `place_account_hold` RPC to freeze the account, then sends a Gmail alert to ops
5. If approved: returns `{ approved: true, fraud_assessment_id }` — caller passes this ID to WF-01

**Where fraud is calculated:** Python service (deterministic rules). n8n routes the result. PostgreSQL enforces the hold.

**Python dependency:** This workflow requires the Python service to be deployed. Until then, calling `/webhook/assess-fraud` will fail at the Python call step. See "Python Service" below.

---

### WF-04 — RAG Support Case Handling
**Trigger:** POST webhook at `/webhook/support-case`

**What it does:**
1. Validates profile_id, subject, and inquiry text
2. Creates a `support_cases` record in Supabase (status: `open`)
3. Sends the inquiry to a LangChain AI Agent that uses:
   - **Groq** (llama-3.3-70b-versatile) as the language model
   - **Pinecone** (`banking-policy-index`, namespace `banking_policy`) as the policy knowledge base
   - **Gemini** for embeddings
   - A **Structured Output Parser** requiring `{ draft, grounded, confidence, citations, needs_human }`
4. If confidence >= 0.7 AND grounded AND NOT needs_human: saves the draft as a grounded response
5. If below threshold OR needs_human: saves a fallback draft routing to human specialist
6. Saves draft to `support_case_drafts`, updates case status to `awaiting_human_review`
7. Returns the case ID — human reviewer then calls WF-05 with the draft ID

**RAG safety:** The AI is strictly instructed to only use retrieved policy documents. Historical cases from Pinecone may inform tone/format only, never policy. If retrieval is weak, the workflow routes to human review rather than hallucinating.

**LLM role:** Drafting only. Never authorizes financial actions.

**Where Pinecone is used:** Inside the AI Agent as a tool subnode.
**Where Groq is used:** Inside the AI Agent as the language model.

---

### WF-05 — Human Approval Gate & Gmail Send
**Trigger:** POST webhook at `/webhook/approve-draft`

**What it does:**
1. Validates `draft_id` (UUID) and `action` (must be `approve`, `reject`, or `edit`)
2. Fetches the draft and associated support case + customer profile from Supabase
3. Verifies draft is still in `pending` state (prevents double-processing)
4. **Approve/Edit path:** Updates draft state → updates case to `resolved` → **sends email via Gmail** to the customer's address from their `profiles` record → logs to audit_log
5. **Reject path:** Updates draft state to `rejected` → updates case to `closed` → logs to audit_log → **no email sent**

**The human approval gate is the only path to Gmail send.** There is no automated path that bypasses this step.

**Where Gmail sends:** Only after explicit human approval via this webhook.

---

### WF-06 — Nightly Reconciliation & Ledger Verification
**Trigger:** Schedule (daily at midnight UTC)

**What it does:**
1. Gets today's date
2. Calls `run_reconciliation` PostgreSQL RPC
3. The RPC checks: (a) system-wide total debits = total credits, (b) per-account cached balance matches sum of ledger entries for all active/frozen accounts
4. On pass: logs summary (no alert)
5. On fail: formats discrepancy details and sends Gmail alert to ops

**Where reconciliation is calculated:** Inside `run_reconciliation()` PostgreSQL function.

**Tested:** This workflow was manually executed and produced `passed: true, total_debits: 300000, total_credits: 300000, discrepancies: []`.

---

## Credentials Required

| Credential | Type | Used By | Status |
|---|---|---|---|
| Supabase account | `supabaseApi` | WF-01,02,03,04,05,06 | ✅ Connected |
| Gmail account | `gmailOAuth2` | WF-01,02,03,05,06 | ✅ Connected |
| Groq account | `groqApi` | WF-04 | ✅ Connected |
| Pinecone account | `pineconeApi` | WF-04 | ✅ Connected |
| Google Gemini API | `googlePalmApi` | WF-04 | ✅ Connected |

---

## Python Service Integration

The Python fraud service is **not yet deployed**. WF-03 is structurally complete and ready.

**When you deploy the Python service:**
1. In n8n → Settings → Variables, set: `PYTHON_SERVICE_URL = https://your-railway-url.railway.app`
2. The Python service must accept `POST /assess-fraud` with body:
   ```json
   {
     "account_id": "UUID",
     "amount": 1000,
     "currency": "USD",
     "profile_id": "UUID or null",
     "transaction_context": {}
   }
   ```
3. It must return:
   ```json
   {
     "approved": true,
     "risk_score": 12.5,
     "reason": "Low risk",
     "fraud_assessment_id": "UUID"
   }
   ```
   The `fraud_assessment_id` must be a UUID of a row already written to the `fraud_assessments` table in Supabase by the Python service before returning.

---

## Workflow Communication

| From | To | Mechanism |
|---|---|---|
| Caller (API/frontend) | WF-01 | POST to `/webhook/transfer` |
| Caller | WF-03 | POST to `/webhook/assess-fraud` — returns `fraud_assessment_id` |
| WF-03 result | WF-01 caller | Caller passes the `fraud_assessment_id` from WF-03 into WF-01 |
| Caller | WF-04 | POST to `/webhook/support-case` — returns `support_case_id` |
| Human reviewer | WF-05 | POST to `/webhook/approve-draft` with `draft_id` and `action` |
| n8n Schedule | WF-02 | Internal schedule trigger |
| n8n Schedule | WF-06 | Internal schedule trigger |

---

## How to Activate

1. Ensure all credentials above are connected in n8n → Credentials
2. Set `PYTHON_SERVICE_URL` in n8n → Settings → Variables (once Python service is deployed)
3. Load banking policy documents into Pinecone index `banking-policy-index` (namespace `banking_policy`)
4. Activate workflows in this order:
   - WF-06 (reconciliation — safe, read-only)
   - WF-02 (standing orders — only fires when orders are due)
   - WF-04 (RAG support)
   - WF-05 (human approval)
   - WF-03 (fraud — requires Python service)
   - WF-01 (transfer — requires fraud assessment from WF-03 first)

---

## What Cannot Work Until Python is Deployed

- WF-03 fraud scoring (the entire workflow stops at the Python call)
- WF-01 transfers that require a fraud assessment (all production transfers)

**For testing WF-01 without Python:** Manually insert a `fraud_assessments` row in Supabase with `approved=true` and a future `expires_at`, then use its ID in the transfer request.

---

## HTTP Request Nodes — Why Not Native Supabase Node?

The native Supabase node supports table CRUD but does not support calling PostgreSQL RPC functions.
All financial operations go through RPCs, so HTTP Request nodes are used to call `POST /rest/v1/rpc/<function_name>`.
This is the correct and documented approach for Supabase RPC from external clients.

The Supabase node is used for all direct table reads and writes (fetching standing orders, creating support cases, updating draft states, writing to audit_log).

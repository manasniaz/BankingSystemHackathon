# Autonomous Digital Banking & AI Automation Platform

[![n8n Cloud](https://img.shields.io/badge/n8n-Automation%20Engine-FF6D5A?logo=n8n&logoColor=white)](https://n8n.io/)
[![Supabase](https://img.shields.io/badge/Supabase-PostgreSQL%20%26%20RPCs-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com/)
[![Python](https://img.shields.io/badge/Python-FastAPI%20Fraud%20Engine-3776AB?logo=python&logoColor=white)](https://fastapi.tiangolo.com/)
[![LangChain](https://img.shields.io/badge/LangChain-RAG%20Support%20Desk-121212?logo=chainlink&logoColor=white)](https://python.langchain.com/)
[![Pinecone](https://img.shields.io/badge/Pinecone-Vector%20Database-000000?logo=pinecone&logoColor=white)](https://www.pinecone.io/)
[![Groq](https://img.shields.io/badge/Groq-LLM%20Inference-F04E23)](https://groq.com/)

> **An event-driven, production-grade automated digital banking control plane.**  
> Processes real customer email inquiries, executes zero-trust double-entry financial transactions via strict PostgreSQL database RPCs, computes real-time fraud risk scores via a dedicated FastAPI microservice, and grounds customer support inquiries using RAG — sending confident, well-grounded answers directly, and escalating only genuinely ambiguous ones to a human operator.

---

## 🏛️ Executive Summary

Modern banking demands seamless email interaction without sacrificing financial integrity or regulatory security. This project implements a **zero-trust automated core banking platform** where **n8n Cloud** acts as the orchestration control plane, **Supabase PostgreSQL** enforces immutable transactional ledger logic, a **Python FastAPI service** evaluates deterministic fraud risk scores, and a **LangChain RAG pipeline (Groq + Pinecone + Gemini)** drafts policy support responses.

### 🔑 Core Architectural Philosophy
1. **Zero-Trust Money Movement**: AI and n8n *never* mutate account balances or insert ledger lines directly. All financial transactions, balance checks, holds, and idempotency validations are strictly encapsulated inside atomic PostgreSQL `SECURITY DEFINER` functions (RPCs).
2. **Deterministic Fraud Boundaries**: High-risk transactions trigger automated account freezes before ledger execution based on velocity, amount, and recipient history.
3. **Grounded-First RAG, Human-in-the-Loop for the Rest**: a policy answer the model is confidently grounded on (`grounded=true`, `confidence >= 0.7`) is sent directly. Anything else is saved to an internal approval queue (`support_case_drafts`) and requires explicit human operator validation before it ever reaches a customer.

> 📋 **This capstone is graded on justified engineering judgment, not just working code.** [`docs/decisions.md`](docs/decisions.md) walks through all 32 edge cases from the assignment brief — what's built, what's deliberately scoped out, and the reasoning for each call. See the doc's **Session 2 Addendum** for self-service + joint account opening, either-or vs. both-signature transfer authority, majority-vote governance, minor/guardian accounts, and a public (non-customer) RAG chatbot — all added after the initial audit.

> 💱 **Currency: PKR (Pakistani Rupees).** All accounts, transfers, standing orders, and fraud thresholds are denominated in PKR; amounts are stored as `BIGINT` paisa (1 PKR = 100 paisa), the same integer-minor-unit design the schema always used for USD cents. A handful of legacy `$`/USD examples remain further down this README from before the currency switch — the live system and every current code path use PKR.

---

## 📊 Deployment & Implementation Matrix

| Component / Layer | Implementation Status | Deployment Environment | Live / Active Target |
|---|---|---|---|
| **Bank Gmail Intake** | ✅ Implemented | Live Google Workspace / Gmail | Shared privately with evaluators — see "Live Demo & Judge Testing Guide" |
| **n8n Orchestration Plane** | ✅ Implemented | n8n Cloud | 9 Workflows Active (WF-00 to WF-06, WF-08, WF-09) |
| **Financial Database & Ledger** | ✅ Implemented | Supabase Cloud PostgreSQL | 17 Tables + 25+ Atomic RPCs, currency: PKR |
| **Fraud Scoring Engine** | ✅ Implemented | Python FastAPI Microservice | `POST /assess-fraud` |
| **Self-Service Account Opening** | ✅ Implemented | n8n (WF-00) + Supabase Auth Admin API | Single + joint accounts, no manual KYC |
| **Joint Account Invitations** | ✅ Implemented | n8n (WF-00, WF-08) + Supabase | 5-minute accept/decline window, auto-expiry |
| **Money-In: Deposits & Loans** | ✅ Implemented | n8n (WF-00, WF-05) + Supabase Treasury account | Self-service deposits (capped), loans ≤ Rs 200k instant, ≤ Rs 2M human-reviewed |
| **Public RAG Support Chatbot** | ✅ Implemented | n8n (WF-04) | Answers anyone, not just customers |
| **Policy RAG Vector Search** | ✅ Implemented, seeded & verified | Pinecone Vector Database | Index: `banking-policy-index` (3072-dim, ns: `banking_policy`), 15 docs loaded — see [`docs/policies.md`](docs/policies.md) |
| **LLM Support Drafting** | ✅ Implemented | Groq Cloud | `llama-3.3-70b-versatile` |
| **Text Embeddings Engine** | ✅ Implemented | Google Gemini API | `gemini-embedding-001` |
| **Human Approval Queue** | ✅ Implemented | n8n Webhook Gate | `POST /webhook/approve-draft`, `POST /webhook/approve-loan` |

---

## 🏗️ End-to-End System Architecture

```mermaid
flowchart TD
    subgraph Client Layer
        A[Customer Email] -->|Sends email| B(Bank Gmail Inbox)
    end

    subgraph n8n Control Plane
        B -->|Gmail Trigger| WF0[WF-00 Gmail Intake Router]
        
        WF0 -->|1. Authenticate Sender| DB_Auth[(Supabase Profiles & Account Holders)]
        
        WF0 -->|Balance Inquiry| WF0_BAL[Format Authorized Balances]
        WF0 -->|Transfer Intent| WF1[WF-01 Transfer Engine]
        WF0 -->|Policy Inquiry| WF4[WF-04 RAG Support Case]
        
        WF1 -->|Fraud Check| WF3[WF-03 Fraud Hold Engine]
        WF4 -->|Generate Grounded Response| RAG[LangChain RAG Agent]
    end

    subgraph Intelligence & Fraud Layer
        WF3 -->|POST /assess-fraud| PY[Python FastAPI Microservice]
        PY -->|Evaluate 4 Scoring Rules| PY
        PY -->|Write Assessment| DB_FRAUD[(fraud_assessments)]
        
        RAG -->|Vector Search| PINECONE[(Pinecone Index: banking-policy-index)]
        RAG -->|Generate Draft| GROQ[Groq LLM: llama-3.3-70b]
        RAG -->|Save Draft| DB_DRAFT[(support_case_drafts)]
    end

    subgraph Ledger & Financial Database
        WF1 -->|Call execute_transfer RPC| RPC_TX[execute_transfer]
        RPC_TX -->|Check Idempotency| DB_IDEMP[(idempotency_keys)]
        RPC_TX -->|Verify Fraud Assessment| DB_FRAUD
        RPC_TX -->|Write Double-Entry Ledger| DB_LEDGER[(ledger_entries & transactions)]
        RPC_TX -->|Atomic Balance Update| DB_ACC[(accounts)]
        RPC_TX -->|Append Audit Trail| DB_AUDIT[(audit_log)]
    end

    subgraph Human Oversight & Response
        RAG -->|Grounded & Confident >= 0.7| DIRECT[WF-04 Sends Answer Directly]
        DIRECT --> B
        RAG -->|Not Grounded / Low Confidence| DB_DRAFT
        DB_DRAFT -->|Pending Review| WF5[WF-05 Human Approval Gate]
        OPERATOR[Ops Specialist] -->|POST /webhook/approve-draft| WF5
        WF5 -->|Update Status & Send Email| B
        WF0_BAL -->|Direct Reply| B
        RPC_TX -->|Transaction Receipt| B
    end

    subgraph Background Schedulers
        SO_CRON[Hourly Trigger] --> WF2[WF-02 Standing Order Scheduler]
        WF2 -->|Call execute_standing_order| RPC_SO[execute_standing_order]
        
        REC_CRON[Midnight UTC Trigger] --> WF6[WF-06 Reconciliation]
        WF6 -->|Call run_reconciliation| RPC_REC[run_reconciliation]
        RPC_REC -->|Ledger Balance Match Check| DB_REC[(reconciliation_runs)]

        MAIL_TRIGGER[Gmail Trigger, opportunistic] --> WF0
        WF0 -->|On every real email| SWEEP[expire_stale_joint_invitations]
    end
```

> Human review is the exception path, not the default — see "RAG Policy Support Engine & Human Approval" below.

---

## ⚡ Core Banking & Business Rules

### 1. Atomic Double-Entry Financial Ledger
* All financial transactions create **exactly two ledger entries** (`ledger_entries`): one debit (`DEBIT`) and one credit (`CREDIT`), linked to a single transaction record (`transactions`).
* Account balances in `accounts.balance` are cached counters updated exclusively by `SECURITY DEFINER` SQL functions.
* All financial amounts are stored as **64-bit integers (`BIGINT`) representing paisa** (e.g., `Rs 50.00` = `5000` paisa; 1 PKR = 100 paisa) to prevent floating-point rounding errors.

### 2. Idempotency Gatekeeping
* Every financial transfer requires a unique `idempotency_key`.
* `idempotency_keys` uses an atomic `INSERT ON CONFLICT DO NOTHING` design.
* Duplicate incoming requests return the stored historical execution result without re-executing money movement.

### 3. Joint Accounts & Multi-Signatory Governance
* Accounts can have multiple profile associations via `account_holders` with roles (`primary`, `joint`).
* Closure of a joint account requires explicit consent recorded in `joint_account_actions` and `joint_account_consents`. The account is locked for withdrawal and closed only when 100% of joint holders approve.

### 4. Background Reconciliation Audit
* **WF-06 Reconciliation** executes nightly at midnight UTC.
* Invokes `run_reconciliation()` RPC to verify:
  1. System-wide sum of all debits equals sum of all credits ($\sum \text{Debits} = \sum \text{Credits}$).
  2. Every account's cached `balance` matches the sum of its double-entry ledger lines.
* Any mismatch flags a discrepancy in `reconciliation_runs` and triggers an urgent notification to Operations.

---

## 🛡️ Security & Authorization Model

```
                    ┌──────────────────────────────────────────────┐
                    │               Supabase Cloud                 │
                    │                                              │
                    │   ┌──────────────────────────────────────┐   │
                    │   │    Row-Level Security (RLS) Policies │   │
                    │   └──────────────────┬───────────────────┘   │
                    │                      │                       │
                    │   ┌──────────────────▼───────────────────┐   │
                    │   │    SECURITY DEFINER Database RPCs    │   │
                    │   │    (Owned by banking_functions)      │   │
                    │   └──────────────────┬───────────────────┘   │
                    │                      │                       │
                    │   ┌──────────────────▼───────────────────┐   │
                    │   │  Immutable Financial Tables          │   │
                    │   │  (accounts, ledger_entries, audit)   │   │
                    │   └──────────────────────────────────────┘   │
                    └──────────────────────────────────────────────┘
```

* **Email Identity Verification**: The **actual sender** of an incoming email is extracted and checked against `profiles.email` — never an email address that merely appears written inside the message body. Unregistered senders receive immediate denial notifications (or, for policy questions, are simply answered as a member of the public — see the RAG section below).
* **Account-Level Authorization**: `WF-00` queries `account_holders` to ensure the sender is an authorized owner of the account before processing balances or transfers. Unauthorized inquiries for third-party accounts are rejected instantly with zero data leakage.
* **Role-Based Access Control**:
  * `anon` / Customer JWT: Restricted by RLS to read-only access on their own records.
  * `service_role` (n8n/Python): Bypasses RLS to call trusted RPC endpoints. Cannot mutate balances or ledger tables without passing through RPC assertions.
  * `banking_functions` SQL Role: Sole owner of financial mutation procedures (`execute_transfer`, `place_account_hold`, etc.).

---

## 🕵️ Deterministic Fraud Detection Microservice

Located in [`python/main.py`](python/main.py), the Python FastAPI service evaluates transactions against four deterministic risk rules prior to database execution:

```
                  Incoming Transfer Payload
                             │
                             ▼
               ┌───────────────────────────┐
               │    FastAPI /assess-fraud   │
               └─────────────┬─────────────┘
                             │
       ┌─────────────────────┼─────────────────────┬─────────────────────┐
       ▼                     ▼                     ▼                     ▼
[Rule 1: Account Status] [Rule 2: Velocity]  [Rule 3: High Amount] [Rule 4: New Recipient]
  Frozen/Closed/Hold?    > 5 tx in 60 mins?  > Rs 500,000 (5M paisa)?  First time sender?
    (Score: 100)            (Score: +50)         (Score: +30)          (Score: +15)
       │                     │                     │                     │
       └─────────────────────┼─────────────────────┴─────────────────────┘
                             │
                             ▼
                     Calculate Total Risk
                   (Threshold >= 75.0 Risk)
                             │
            ┌────────────────┴────────────────┐
            ▼                                 ▼
      Score < 75.0                       Score >= 75.0
      [Approved]                       [Rejected & Frozen]
            │                                 │
     Proceed to Transfer              Call place_account_hold RPC
                                      Send Alert to Ops Team
```

Assessments are stored in `fraud_assessments` with a 10-minute TTL (`expires_at`). `execute_transfer()` verifies that a valid, approved assessment exists before committing funds.

---

## 🤖 RAG Policy Support Engine & Human Approval

Anyone can ask Digital Bank a policy question by email — you don't need to be a customer. For general policy inquiries (fees, limits, terms, wire rules, privacy, account opening), **WF-04** activates a LangChain RAG pipeline grounded strictly in [`docs/policies.md`](docs/policies.md) (the same 13 documents embedded in Pinecone by WF-09):

1. **Retrieval**: Queries Pinecone index `banking-policy-index` (namespace `banking_policy`) using Google Gemini embeddings (`gemini-embedding-001`), capped at 2 search attempts.
2. **Grounded Generation**: Groq synthesizes a response strict to retrieved policy citations, returning `{draft, grounded, confidence, citations, needs_human}`.
3. **The confidence fork** — this is the part that changed after an early design mistake (see `docs/decisions.md` → Session 5):
   - **Grounded and confident (`grounded=true`, `confidence >= 0.7`)**: WF-04 sends the answer to the customer **directly**. No human step. The case is marked `answered`.
   - **Not grounded, low confidence, or an agent error**: the draft is written to `support_case_drafts` (`human_review_state = 'pending'`), the case is marked `awaiting_human_review`, and the customer gets a receipt saying a specialist will follow up — never a guess presented as fact.
4. **Human Gate (WF-05)** — only for the second path above. An Ops specialist reviews the draft and posts approval via `/webhook/approve-draft`:
   ```json
   {
     "draft_id": "c1a8d294-81e3-4f2a-b72e-9d8a1e49b812",
     "action": "approve"
   }
   ```
   `WF-05` updates draft status to `approved` and sends the final answer to the customer.

Human review exists for what's genuinely ambiguous or unanswerable from policy — not as a bottleneck on every question a confident, grounded model could already answer correctly.

---

## 💵 Where the Money Comes From

Every account used to open at Rs 0.00 with no way to fund it. Fixed with a real, ledger-backed source instead of a shortcut that would have broken the double-entry invariant this schema enforces everywhere else:

- **`TREASURY-MAIN`**: an internal account (never customer-owned, never reachable by any email-authenticated intent) holding Rs 500,000,000 of the bank's own capital — the counterparty for every deposit and loan disbursement, via the same `process_money_movement()` primitive `execute_transfer()` uses. Nightly reconciliation checks it like any other account.
- **Self-service deposits**: `deposit_funds` RPC, capped at Rs 50,000/request and 3/account/24h — a claimed deposit by email is inherently unverifiable, so it's bounded rather than escalated to a human.
- **Loans**: `apply_for_loan` at a flat 10% interest rate. Up to Rs 200,000 → auto-approved and disbursed instantly. Up to a Rs 2,000,000 ceiling → reviewed by a specialist via `/webhook/approve-loan` (WF-05). Repayment happens automatically via a standing order, same mechanism as any other recurring payment.

Full design and the two bugs it took to get here (a reconciliation-breaking genesis-funding mistake, and a pair of CHECK-constraint violations that had silently broken the RAG auto-answer feature since it was written): [`docs/policies.md`](docs/policies.md) and [`docs/decisions.md`](docs/decisions.md) → Session 7.

---

## 📂 Final Workflow Portfolio

| Workflow File | Name | Trigger | Key Function |
|---|---|---|---|
| [`WF-00-gmail-intake-router.json`](n8n/workflows/WF-00-gmail-intake-router.json) | Gmail Front Door Intake | Native Gmail Polling | Resolves sender email to profile, checks account authorization, classifies intent from the email **body** (subject is only a fallback, now including loan applications and deposits), routes to sub-workflows. Also opportunistically sweeps expired joint invitations on every real incoming email. |
| [`WF-01-transfer.json`](n8n/workflows/WF-01-transfer.json) | Transfer Engine | Webhook (`/webhook/transfer`) | Invokes fraud scoring, executes `initiate_transfer`/`execute_transfer` RPC, sends transaction receipt email. |
| [`WF-02-standing-order-scheduler.json`](n8n/workflows/WF-02-standing-order-scheduler.json) | Standing Orders | Cron (Hourly) | Finds due recurring transfers (`next_execution_at <= NOW()`), calls `execute_standing_order` RPC. |
| [`WF-03-fraud-hold.json`](n8n/workflows/WF-03-fraud-hold.json) | Fraud Hold Processor | Webhook (`/webhook/assess-fraud`) | Evaluates Python service response. Places full account hold via `place_account_hold` RPC if fraud detected. |
| [`WF-04-rag-support-case.json`](n8n/workflows/WF-04-rag-support-case.json) | RAG Policy Support | Sub-workflow + webhook (`/webhook/support-case`) | Queries Pinecone policy vectors, drafts answer via Groq LLM. Sends grounded/confident answers directly; queues everything else in `support_case_drafts` for human review. Open to non-customers too. |
| [`WF-05-human-approval-gmail.json`](n8n/workflows/WF-05-human-approval-gmail.json) | Human Approval Gate | Webhook (`/webhook/approve-draft`, `/webhook/approve-loan`) | Two independent webhook triggers: RAG cases WF-04 couldn't confidently answer, and loan applications over Rs 200,000. Operator approves/edits/rejects, dispatches email reply via Bank Gmail. |
| [`WF-06-reconciliation.json`](n8n/workflows/WF-06-reconciliation.json) | Ledger Reconciliation | Cron (Midnight UTC) | Performs system-wide debit/credit integrity audit via `run_reconciliation` RPC. Also runs `promote_minors_to_adult()`. Alerts Ops on mismatch. |
| [`WF-08-joint-invitation-expiry-sweep.json`](n8n/workflows/WF-08-joint-invitation-expiry-sweep.json) | Joint Invitation Expiry Sweep | Schedule (every minute) — **deactivated** | Superseded: fired unconditionally every minute regardless of need, burning n8n Cloud free-tier execution quota. Kept, deactivated, for optional temporary use during a live demo. The same logic now runs opportunistically inside WF-00 at zero standing cost. |
| [`WF-09-seed-policy-documents.json`](n8n/workflows/WF-09-seed-policy-documents.json) | Seed Policy Documents | Manual/one-time utility | Embeds the 13 PKR policy documents ([`docs/policies.md`](docs/policies.md)) into Pinecone via Gemini embeddings. Re-run after any Pinecone index recreation. |

---

## 🗄️ Database & Financial Schema Design

The system relies on 15 specialized tables in PostgreSQL ([`supabase/migrations/001_initial_banking_schema.sql`](supabase/migrations/001_initial_banking_schema.sql)):

```
                                  ┌──────────────┐
                                  │ auth.users   │
                                  └──────┬───────┘
                                         │ (1:1 Trigger)
                                  ┌──────▼───────┐
                                  │   profiles   │
                                  └──────┬───────┘
                                         │
                        ┌────────────────┴────────────────┐
                        │                                 │
              ┌─────────▼──────────┐            ┌─────────▼──────────┐
              │  account_holders   │            │   support_cases    │
              └─────────┬──────────┘            └─────────┬──────────┘
                        │                                 │
              ┌─────────▼──────────┐            ┌─────────▼──────────┐
              │      accounts      │            │support_case_drafts │
              └─────────┬──────────┘            └────────────────────┘
   ┌────────────────────┼────────────────────┬────────────────────┐
   │                    │                    │                    │
┌──▼───────────┐ ┌──────▼──────┐   ┌─────────▼──────────┐ ┌───────▼──────────┐
│ledger_entries│ │account_holds│   │  standing_orders   │ │joint_acc_actions │
└──┬───────────┘ └─────────────┘   └────────────────────┘ └───────┬──────────┘
   │                                                              │
┌──▼───────────┐                                          ┌───────▼──────────┐
│ transactions │                                          │joint_acc_consents│
└──┬───────────┘                                          └──────────────────┘
   │
┌──▼────────────────┐  ┌──────────────────┐  ┌───────────────────┐  ┌───────────┐
│ fraud_assessments │  │ idempotency_keys │  │reconciliation_runs│  │ audit_log │
└───────────────────┘  └───────────────────┘  └───────────────────┘  └───────────┘
```

---

## 🛠️ Technology Stack

* **Workflow Orchestration**: n8n Cloud (JavaScript / Node.js Engine)
* **Database & BaaS**: Supabase Cloud PostgreSQL (SQL, PL/pgSQL, RLS, PostgREST API)
* **Fraud Microservice**: Python 3.11+, FastAPI, Uvicorn, Pydantic, Supabase Python SDK
* **Vector Database**: Pinecone Cloud (`banking-policy-index`)
* **LLM Engine**: Groq Cloud (`llama-3.3-70b-versatile`)
* **Embeddings**: Google Gemini API (`gemini-embedding-001`)
* **Email Protocols**: Google Workspace OAuth2 (Gmail API)

---

## 📁 Repository Structure

```
BankingSystemHackathon/
├── README.md                           # Master Architecture & Operating Manual
├── docs/                               # System Specs & Architecture Documents
│   ├── architecture.md                 # Table schemas, RPC function signatures, security matrix
│   ├── database.md                     # Migration-by-migration history + minimal ER overview
│   ├── decisions.md                    # Item-by-item edge case checklist + session-by-session change log
│   ├── mvp-scope.md                    # Short version of decisions.md: in-scope vs. out-of-scope summary
│   ├── policies.md                     # The bank's actual policy documents (also the RAG source of truth)
│   ├── requirements.md                 # Functional & Non-Functional Specifications
│   ├── security.md                     # RLS rules, role model & credential handling
│   ├── testing.md                      # How to run the SQL test suite + what was live-verified
│   └── workflows.md                    # n8n workflow quick reference + audit changelog
├── n8n/                                # Automation Control Plane
│   ├── README.md                       # Operator & Manual Execution Guide
│   ├── validate_workflows.js           # Workflow syntax & node configuration validator
│   ├── validate_workflows.py           # Python schema validator for n8n JSON exports
│   └── workflows/                      # Production Workflow Blueprints
│       ├── WF-00-gmail-intake-router.json
│       ├── WF-01-transfer.json
│       ├── WF-02-standing-order-scheduler.json
│       ├── WF-03-fraud-hold.json
│       ├── WF-04-rag-support-case.json
│       ├── WF-05-human-approval-gmail.json
│       ├── WF-06-reconciliation.json
│       ├── WF-08-joint-invitation-expiry-sweep.json  # Deactivated — see docs/workflows.md
│       └── WF-09-seed-policy-documents.json
├── python/                             # Fraud Microservice Engine
│   ├── main.py                         # FastAPI service with 4-rule fraud scoring engine
│   ├── test_main.py                    # Pytest test suite for fraud rules
│   ├── Procfile                        # Cloud deployment runner (Uvicorn)
│   ├── requirements.txt                # Python dependencies (FastAPI, Supabase, Uvicorn)
│   └── .env.example                    # Placeholder env vars — copy to .env, never commit real values
├── supabase/                           # Core Banking Ledger Database
│   └── migrations/
│       ├── 001_initial_banking_schema.sql              # 15 tables, double-entry triggers, first RPCs
│       ├── 002_security_hardening.sql                  # RLS policies & permission hardening
│       ├── 003_rls_explicit_deny_policies.sql          # Explicit deny-all RLS on internal-only tables
│       ├── 004_governance_and_account_opening.sql      # Self-service opening, joint governance, minors
│       └── 005_pkr_currency_joint_invitations_public_rag.sql  # PKR conversion, invitations, public RAG
└── tests/                              # Comprehensive SQL Test Suite
    ├── seed_test_data.sql              # Test customer profiles, accounts & initial balances
    ├── phase1_smoke_tests.sql          # DB schema & constraint validation tests
    ├── test_transfer_flow.sql          # Transfer, idempotency & fraud integration tests
    └── test_concurrency.sql            # Concurrency & lock isolation test scripts
```

---

## ⚙️ Setup & Installation Guide

### 1. Supabase Database Setup
1. Create a project in [Supabase Cloud](https://supabase.com/).
2. Open the SQL Editor and execute:
   - [`supabase/migrations/001_initial_banking_schema.sql`](supabase/migrations/001_initial_banking_schema.sql)
   - [`supabase/migrations/002_security_hardening.sql`](supabase/migrations/002_security_hardening.sql)
   - [`tests/seed_test_data.sql`](tests/seed_test_data.sql)

### 2. Python Fraud Microservice Setup
```bash
cd python
python -m venv venv
# On Windows:
.\venv\Scripts\activate
# On Linux/macOS:
source venv/bin/activate

pip install -r requirements.txt
```

Create `python/.env`:
```env
SUPABASE_URL=https://your-supabase-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key
PORT=8080
```

Run locally or deploy to Railway/Render:
```bash
python main.py
```

### 3. n8n Workflows Setup
1. Import all workflow JSON files from `n8n/workflows/` into your n8n Cloud workspace.
2. Set Environment Variable in n8n Settings:
   ```env
   PYTHON_SERVICE_URL=http://localhost:8080  # Or your deployed public Python microservice URL
   ```
3. Configure the required n8n Credentials:
   - `Gmail account` (`gmailOAuth2` connected to the bank's own inbox — see note below on obtaining test access)
   - `Supabase account` (`supabaseApi` with Supabase URL & Service Role Key)
   - `Groq account` (`groqApi` with Groq API Key)
   - `Pinecone account` (`pineconeApi` with Pinecone API Key)
   - `Google Gemini API` (`googlePalmApi` with Gemini API Key)
4. Activate all 9 workflows in n8n (WF-08 is deliberately kept **deactivated** — see its row in [`docs/workflows.md`](docs/workflows.md)).

---

## 🧪 Live Demo & Judge Testing Guide

This repository intentionally does not publish the live Bank Gmail inbox address — a real, working Gmail address in a public repo invites spam and abuse of a live test system. **The address is shared privately with the evaluator/instructor.** If you're grading this project and don't have it, ask the author directly.

> 💡 **Seed Test Identities** (Configured in [`tests/seed_test_data.sql`](tests/seed_test_data.sql)):
> - **Alice Testuser**: `alice@test.banking` (Primary holder of account `TEST-ALICE-001`, Balance: `Rs 100,000.00`)
> - **Bob Testuser**: `bob@test.banking` (Primary holder of account `TEST-BOB-001`, Balance: `Rs 50,000.00`)
>
> *To run tests with your own email address:* In Supabase SQL Editor, update Alice's email to your personal email address:
> ```sql
> UPDATE profiles SET email = 'your.email@gmail.com' WHERE id = 'a0000000-0000-0000-0000-000000000001';
> ```

---

### 📩 Test Scenarios & Sample Emails

Send each of these to the Bank Gmail address you were given privately.

#### Scenario 1: Account Balance Inquiry
* **Subject**: `Account Balance Inquiry`
* **Body**:
  ```text
  Hello, please provide my current checking account balance details.
  ```
* **Expected Response**: Receives an email listing authorized account `TEST-ALICE-001` with an accurate `Rs 100,000.00` available balance.

---

#### Scenario 2: Instant Atomic Transfer
* **Subject**: `Send Money`
* **Body**:
  ```text
  Please transfer 5000 rupees to account TEST-BOB-001.
  ```
* **System Execution**:
  1. `WF-00` classifies intent from the email **body** (Rs 5,000 = 500,000 paisa) and recipient `TEST-BOB-001`.
  2. Invokes `WF-01 Transfer` → calls Python Fraud Service `POST /assess-fraud`.
  3. Fraud Engine approves (Score: Low Risk).
  4. Calls `execute_transfer`/`initiate_transfer` RPC → debits Alice Rs 5,000, credits Bob Rs 5,000, writes 2 ledger entries atomically.
* **Expected Response**: Receives a transaction confirmation email with Transaction ID and updated balance.

---

#### Scenario 3: High-Risk Fraud Detection & Account Freeze
* **Subject**: `Urgent Large Transfer`
* **Body**:
  ```text
  Please transfer 600000 rupees to account TEST-BOB-001.
  ```
* **System Execution**:
  1. Transfer amount `Rs 600,000` exceeds the `Rs 500,000` fraud-scoring threshold.
  2. Python microservice flags `Large amount` + `New recipient` → Risk score exceeds `75.0`.
  3. `WF-03` triggers `place_account_hold` RPC to freeze `TEST-ALICE-001` and alerts Operations.
* **Expected Response**: Customer receives a security notice that the transaction was blocked due to risk policies and the account has been placed on hold for verification.

---

#### Scenario 4: Policy Query (RAG Support Desk) — answered instantly, no account needed
* **Subject**: `Wire Transfer Policy Question`
* **Body**:
  ```text
  What are the daily limits and fee structures for international wire transfers?
  ```
* **System Execution**:
  1. `WF-00` routes to `WF-04 RAG Support` (works even from an email address with no bank account).
  2. LangChain searches Pinecone index `banking-policy-index` and finds `doc_wire_transfer_policy`.
  3. Groq drafts a grounded answer with confidence ≥ 0.7.
* **Expected Response**: The verified policy answer arrives **directly, in one email, with no human step** — see "RAG Policy Support Engine & Human Approval" above for when a human *is* involved.

---

#### Scenario 5: Security & Privacy Protection Check
* **Subject**: `Inquiry about Bob`
* **Body**:
  ```text
  Hi, can you tell me the balance of account TEST-BOB-001?
  ```
* **Expected Response**: `WF-00` checks authorization against `account_holders`. Alice is not an authorized holder of `TEST-BOB-001`. The request is rejected with zero disclosure of Bob's sensitive banking details.

---

#### Scenario 6: Loan Application — Instant Approval
* **Subject**: `Loan application`
* **Body**:
  ```text
  I'd like to borrow 30000 rupees for 12 months please.
  ```
* **System Execution**: `WF-00` classifies `LOAN_APPLICATION`, calls `apply_for_loan` (Rs 30,000 ≤ the Rs 200,000 auto-approve ceiling) → disbursed instantly from `TREASURY-MAIN`, a monthly repayment standing order created.
* **Expected Response**: Confirmation email with the principal, total repayable (flat 10% interest), term, and monthly repayment amount — no human step.

---

## 📌 Known Dependencies & Architectural Boundaries

1. **Email Intake Mechanism**: Intake relies on n8n's Gmail Trigger polling for unread messages.
2. **Fraud Microservice Reachability**: n8n must be able to reach `PYTHON_SERVICE_URL`. If the microservice is offline, `WF-03` defaults to a defensive safety hold.
3. **Pinecone Indexing**: RAG policy retrieval requires pre-populated vector embeddings in Pinecone (`banking-policy-index`, namespace `banking_policy`) — see [`docs/policies.md`](docs/policies.md) for the source documents and [`n8n/workflows/WF-09-seed-policy-documents.json`](n8n/workflows/WF-09-seed-policy-documents.json) for the seeding workflow.

### ✅ No open action items

The Pinecone index (`banking-policy-index`, 3072 dimensions, matching Google's current `gemini-embedding-001` embedding model) has been seeded with all 15 PKR policy documents, including privacy policy, terms and conditions, deposits, and loans. RAG support is verified live and grounded end-to-end, and now genuinely answers a confident, well-grounded question directly instead of always waiting on human approval (verified with a live test after catching and fixing two CHECK-constraint bugs that had silently broken the direct-send path). Accounts can now actually be funded — via self-service deposit or loan — instead of every account being permanently stuck at Rs 0.00.

Full history of what was checked, fixed, and resolved: [`docs/decisions.md`](docs/decisions.md), particularly Sessions 2 through 7.

---

## 👨‍💻 Authors & Project Info

* **Project Title**: Autonomous Digital Banking Platform
* **Author**: Anas Niaz
* **Event / Institution**: Banking System Hackathon
* **Repository**: Hackathon Submission Codebase

---

*This README reflects the exact, verified code and architecture implemented across n8n workflows, PostgreSQL Supabase RPCs, and the Python FastAPI microservice.*
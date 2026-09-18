# TASK 1 — LOCKED ARCHITECTURE

> **Note:** this is the original pre-build architecture snapshot, kept as-is for history. **The 15 tables below were the schema at build time; there are now 27.** Twelve were added afterward, not two as this note previously said: `joint_account_invitations` (005); `loans` plus the `TREASURY-MAIN` account (006–007); `ops_approvals` (009); `minor_account_requests` (015); `account_debts` (020); `bank_holidays` (021); `interest_rates` and `interest_accruals` (022); `disputes` (023); `bank_staff` (027); `staff_passphrase` and `staff_enrolment_attempts` (028).
>
> For the **current** table list see [`database.md`](database.md); for why each was added see [`decisions.md`](decisions.md). Do not update the table below — it is a record of what was designed before any code was written, and its value is in showing what changed.

---

## 1. FINAL TABLE LIST

| # | Table | Purpose |
|---|---|---|
| 1 | `profiles` | 1:1 with `auth.users`. Holds banking-specific user data. Created by trigger on auth signup. |
| 2 | `accounts` | Bank accounts. Cached `balance` (BIGINT). Modified only by trusted PostgreSQL functions. |
| 3 | `account_holders` | Junction: which profiles hold which accounts. Supports joint accounts. |
| 4 | `transactions` | High-level record of each financial event. Status lifecycle. No `idempotency_key` column. |
| 5 | `ledger_entries` | Double-entry lines. Append-only. FK to `transactions.id`. Debit or credit, always positive BIGINT. |
| 6 | `idempotency_keys` | Sole idempotency gatekeeper. Atomic insert-or-ignore. Stores result snapshot for retries. |
| 7 | `account_holds` | Holds/freezes on accounts. `is_full_freeze` distinguishes account freeze from partial reservation. |
| 8 | `standing_orders` | Recurring payment instructions. Uses `execution_locked_at` (timestamp) for stale-lock safety. |
| 9 | `joint_account_actions` | Pending multi-holder decisions (closure). Tracks status and expiry. |
| 10 | `joint_account_consents` | Individual holder responses to joint actions. One row per holder per action. |
| 11 | `fraud_assessments` | Deterministic Python fraud scoring output. Includes `approved`, `expires_at`. Required before transfer. |
| 12 | `support_cases` | Customer-visible: inquiry, status, final sent response only. |
| 13 | `support_case_drafts` | Internal only: RAG doc IDs, similarity scores, threshold flag, Groq draft, human review state. |
| 14 | `reconciliation_runs` | Record of every nightly reconciliation: pass/fail, discrepancies, system-wide debit/credit totals. |
| 15 | `audit_log` | Append-only. `seq BIGSERIAL` for unambiguous ordering. Records all significant system events. |

**Total: 15 tables**

---

## 2. FINAL RELATIONSHIPS

```
auth.users (Supabase-managed)
    │  [trigger on INSERT]
    ▼
profiles
    │
    └──< account_holders >──── accounts
                                  │
              ┌───────────────────┼────────────────────┬──────────────────┐
              │                   │                    │                  │
        ledger_entries      account_holds      standing_orders   joint_account_actions
              │                                                          │
        transactions                                          joint_account_consents
              │
        fraud_assessments ◄── (Python writes, execute_transfer() reads)
        idempotency_keys  ◄── (checked/written at start of execute_transfer())

support_cases
    └── support_case_drafts (internal only, never exposed to customer)

reconciliation_runs (reads accounts + ledger_entries; writes own table)

audit_log ◄── written by every PostgreSQL financial function, append-only
```

**Key relationship rules:**
- `ledger_entries.transaction_id` → `transactions.id` (hard FK, not a string reference)
- Every completed transfer produces exactly 2 `ledger_entries` (one debit, one credit), same `transaction_id`
- `account_holders` unique on `(account_id, profile_id)` — a person cannot appear twice on the same account
- `joint_account_consents` unique on `(joint_action_id, profile_id)` — one response per holder per action

---

## 3. FINAL RPC / FUNCTION LIST

| Function | Caller | Purpose |
|---|---|---|
| `create_profile_for_user()` | DB trigger (internal) | Inserts `profiles` row when `auth.users` row is created |
| `get_available_balance(account_id)` | Internal only | Returns `accounts.balance` minus sum of active partial holds |
| `check_fraud_assessment(fraud_assessment_id, account_id, amount)` | Internal only (called by `execute_transfer`) | Verifies assessment exists, belongs to account, is approved, is unexpired |
| `execute_transfer(source_account_id, destination_account_id, amount, currency, idempotency_key, initiated_by_profile_id, fraud_assessment_id)` | n8n via RPC | Full atomic transfer: idempotency → lock → fraud check → hold check → balance check → ledger → balance update → audit |
| `execute_standing_order(standing_order_id)` | n8n via RPC | Locks order via `execution_locked_at`, executes transfer logic, updates retry count or marks permanently failed, writes audit |
| `place_account_hold(account_id, hold_type, is_full_freeze, amount_held, reason, placed_by_profile_id)` | n8n via RPC | Inserts hold, updates account status if full freeze, writes audit |
| `release_account_hold(hold_id, released_by_profile_id)` | n8n via RPC | Verifies human actor, releases hold, restores account status if no remaining freezes, writes audit |
| `request_joint_closure(account_id, requested_by_profile_id)` | n8n via RPC | Creates `joint_account_actions` record, auto-consents initiator, writes audit |
| `record_joint_consent(joint_action_id, profile_id, consent)` | n8n via RPC | Records consent, checks if all holders have responded, triggers `close_account()` if all approved |
| `close_account(account_id)` | Internal only (called by `record_joint_consent`) | Verifies zero balance, no active holds, no active standing orders, sets status to closed, writes audit |
| `run_reconciliation(run_date)` | Python service via RPC | Compares cached balances to ledger sums, checks system-wide debit/credit equality, writes `reconciliation_runs`, flags discrepancies |
| `write_audit_log(event_type, actor_type, actor_id, target_type, target_id, details)` | Internal only | Appended by every financial function. Not directly callable by any application role. |

**All financial functions are `SECURITY DEFINER`, owned by the `banking_functions` role.**

---

## 4. FINAL SECURITY / PERMISSION MODEL

### Roles and what they can do

| Actor | Credential | RLS applies? | Permitted operations |
|---|---|---|---|
| Customer (future) | Supabase Auth JWT (`anon` key) | ✅ Yes | Read own accounts, transactions, support cases. No financial writes. |
| n8n Cloud | `service_role` key | ❌ Bypassed | Read any table via Supabase node. Call RPCs via HTTP POST. Never raw DML on financial tables. |
| Python service | `service_role` key | ❌ Bypassed | Write `fraud_assessments`. Call `run_reconciliation` RPC. No direct ledger/balance writes. |
| `banking_functions` role | DB-internal only | N/A | INSERT on `ledger_entries`, `audit_log`, `transactions`. UPDATE `accounts.balance` and `accounts.status`. Never exposed externally. |

### Hard rules
- `ledger_entries`: INSERT only, from `banking_functions` role only. No UPDATE, no DELETE, ever.
- `audit_log`: INSERT only, from `banking_functions` role only. No UPDATE, no DELETE, ever.
- `accounts.balance`: UPDATE only by `banking_functions` role inside `SECURITY DEFINER` functions.
- `service_role` key: stored in n8n Cloud credential store and Python host environment variables only. Never in source code, never in GitHub.
- Groq/LLMs: may only receive text for drafting. Never receive financial parameters to decide on. Never write to any financial table.

---

## 5. FINAL CLOUD ARCHITECTURE

```
[Developer Laptop]
  Git → GitHub (no secrets)
  Supabase dashboard (schema management, during dev)
  n8n Cloud dashboard (workflow building, during dev)

[Supabase Cloud]
  PostgreSQL database (all 15 tables)
  PostgreSQL functions / RPCs (all financial logic)
  Supabase Auth (auth.users, JWTs)
  PostgREST API (used by n8n Supabase node for reads)
  RPC endpoint (used by n8n HTTP Request node for financial operations)

[n8n Cloud]
  Scheduled workflows (standing orders, reconciliation trigger)
  Event workflows (fraud alert, support case routing, notifications)
  Supabase node → PostgREST (reads, simple non-financial CRUD)
  HTTP Request node → Supabase RPC (all financial operations)
  HTTP Request node → Python service (fraud scoring before transfer)
  Credential store: Supabase service_role, Groq API key, Pinecone API key, Gmail OAuth

[Python Service — Railway or Render free tier]
  FastAPI app, always online
  Deterministic fraud scoring → writes fraud_assessments via Supabase RPC
  Returns {approved, fraud_assessment_id} to n8n
  Triggered by: n8n HTTP Request node

[Pinecone Cloud]
  Vector index of banking policy documents
  Queried by n8n during RAG support workflow

[Groq Cloud]
  Drafts support responses only
  Receives: customer inquiry + retrieved policy text
  Returns: draft text to n8n for human review queue
  Has zero access to any financial data or database

[Gmail]
  Outbound only in MVP: notifications, approved support replies
  Triggered by n8n after human approval gate
```

**Laptop-independence:** All scheduled and event-driven workflows run entirely in the cloud. The laptop is needed only for development and deployment tasks.

---

## 6. REMAINING BLOCKERS BEFORE SQL

None.

All decisions are locked. All ambiguities from the previous audits are resolved. The schema is internally consistent, the security model is defined, the deployment model is confirmed, and the function list is complete.

---

**ARCHITECTURE LOCKED — READY FOR SQL**
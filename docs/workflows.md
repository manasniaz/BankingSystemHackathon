# n8n Workflows — Quick Reference

The full operator manual (credentials, import/activation order, real Gmail test scripts) lives in [`n8n/README.md`](../n8n/README.md). This page is the short index plus what changed in the 2026-09-14 review.

| Workflow | Trigger | Purpose |
|---|---|---|
| WF-00 Gmail Front Door | Gmail Trigger (poll unread, every minute) | Resolves sender → profile, authorizes against `account_holders`, classifies intent (balance / transfer / policy / standing order / dispute / open account / unauthorized), routes to the right sub-workflow, sends the customer-facing reply. |
| WF-01 Transfer | Sub-workflow + webhook (`/webhook/transfer`) | Validates the payload (no fallback defaults — a missing field is a rejected request), calls `execute_transfer()`, returns success/failure. |
| WF-02 Standing Orders | Schedule (hourly) | Finds due orders, calls `execute_standing_order()`, retries up to 3 times, alerts ops on permanent failure. |
| WF-03 Fraud Hold | Sub-workflow + webhook (`/webhook/assess-fraud`) | Calls the Python fraud microservice, places a full-account freeze via `place_account_hold()` on high risk, alerts ops. |
| WF-04 RAG Support | Sub-workflow + webhook (`/webhook/support-case`) | LangChain agent (Groq + Pinecone + Gemini) drafts a grounded policy answer, or falls back to "needs human" below a 0.7 confidence/grounded threshold. |
| WF-05 Human Approval | Webhook (`/webhook/approve-draft`) | The only path that can send a RAG draft to a customer. Approve / edit / reject, with an audit log entry either way. |
| WF-06 Reconciliation | Schedule (midnight UTC) | Calls `run_reconciliation()`, alerts ops on any ledger discrepancy. |

## Changes made in the 2026-09-14 review

- **WF-00, WF-01, WF-04**: each had a newer, safer draft sitting unpublished in the n8n editor — the *live* version had hardcoded fallback account/profile/fraud-assessment IDs that activated on malformed input instead of rejecting the request. Republished all three to their improved drafts.
- **WF-00, WF-03**: the Python fraud-service call used `$vars.PYTHON_SERVICE_URL` directly, which is stored without an `https://` scheme — every call failed with `Invalid URL`. Both HTTP Request nodes now normalize the scheme in the node itself, so the fix doesn't depend on how the instance variable happens to be formatted.
- **WF-03**: `place_account_hold` returns a bare `UUID` (unlike every other financial RPC, which returns `JSONB`), which crashed n8n's JSON auto-detect. Forced `responseFormat: text` on that node.
- Supabase: added explicit deny-all RLS policies for `anon`/`authenticated` on the four internal-only tables that had RLS enabled with no policies (`003_rls_explicit_deny_policies.sql`).

See `decisions.md` → "Known live issues" for what still needs a manual fix outside n8n (Railway env vars, Pinecone index creation).

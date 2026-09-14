# Testing

## SQL test suite (`tests/`)

Run these in the Supabase SQL editor, in order, against a project that already has `supabase/migrations/*.sql` applied:

1. `seed_test_data.sql` — creates Alice/Bob/Charlie test profiles and accounts (`TEST-ALICE-001`, `TEST-BOB-001`, `TEST-JOINT-001`).
2. `phase1_smoke_tests.sql` — schema and constraint sanity checks (tables exist, checks/FKs behave).
3. `test_transfer_flow.sql` — exercises `execute_transfer()` directly: happy path, idempotency replay, insufficient funds, fraud-assessment requirement.
4. `test_concurrency.sql` — concurrent-withdrawal isolation: two simultaneous transfers against the same source account should never both succeed past the available balance.

## n8n live workflow tests

The full set of real-email test scenarios (balance inquiry, transfer, fraud block, RAG policy question, human approval, unauthorized cross-account access, unregistered sender) is documented in [`n8n/README.md`](../n8n/README.md) and summarized in the root [`README.md`](../README.md) "Live Demo & Judge Testing Guide". They're not duplicated here — that's the canonical, judge-facing version.

## What was actually verified live during the 2026-09-14 audit

Using n8n's execute/test tooling directly against the production Cloud instance (not just reading the workflow JSON):

- `WF-03 Fraud Hold` end-to-end call to the Railway Python service — **initially failed** (`Invalid URL`, missing `https://` scheme on `PYTHON_SERVICE_URL`), fixed, re-tested, now reaches the service. The Railway service itself currently rejects requests (`Supabase credentials missing`) — see `decisions.md` for the exact fix needed on Railway's side.
- `place_account_hold` RPC — a real test call surfaced a genuine crash (bare-`UUID`-return not parsed as JSON by n8n); fixed and republished.
- `WF-04 RAG Support` end-to-end call to Pinecone — confirmed the retrieval tool returns HTTP 404 (index doesn't exist yet), and confirmed the fallback path correctly degrades to a "needs human" draft instead of crashing or hallucinating.
- Accidental side effect of the first fraud test: a real fraud hold + account freeze was placed on `TEST-ALICE-001`. This was released (`release_account_hold`) as part of the same review — the account is back to `active`.

## Not yet covered by any automated test

Standing-order weekend/holiday behavior (not built — see `decisions.md`), joint-account majority-vote governance (not built), guardian/minor account permissions (not built). These are scope decisions, not test gaps — there's nothing to test because the feature doesn't exist. See `mvp-scope.md`.

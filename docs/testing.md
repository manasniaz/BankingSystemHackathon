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

## Session 2: joint invitations, governance, PKR (2026-09-15)

Verified live via direct RPC calls and n8n executions (not just read from code):

- **Joint invitation full lifecycle**: created an invitation (Alice → Bob), Bob accepted (already an existing profile) → real `JNT-` account created in PKR. A duplicate accept call on the same invitation returned `already_processed: true` and did **not** create a second account (confirmed via `count(*)` on the account number). A second invitation was manually expired and swept by `expire_stale_joint_invitations()`, which correctly emailed the inviter (`Alice Testuser`) — verified as an actual sent Gmail message, not just a mocked assertion.
- **Both-signature (all-signatures) transfer authority**: set `TEST-JOINT-001` to `authority_model='all_signatures'`, funded it, then had Alice initiate an outgoing transfer via `initiate_transfer` — correctly returned `status: pending` with no funds moved. Charlie then consented via `record_joint_consent`, and the transfer executed atomically (Bob's balance increased by exactly the transfer amount, joint account decreased by the same amount).
- **Adding a holder to an account with an active hold**: placed a real hold on Bob's account, called `add_account_holder` without acknowledgment (correctly refused with `requires_acknowledgment: true`), then with acknowledgment (succeeded). Both artifacts were cleaned up afterward (hold released, test holder removed) to leave seed data as found.
- **RAG public access + returning-visitor detection**: called WF-04 with only a `customer_email` (no `profile_id`) for a fully non-customer email address — succeeded, `inquirer_type: "public"`. An immediate second call from the same address correctly flagged `isReturning: true`.
- **RAG crash found and fixed**: the very same public-access test above initially **crashed** the workflow (agent hit its 10-iteration tool-call cap searching an empty Pinecone index instead of returning its own "not grounded" fallback). Fixed and re-verified — same empty-index scenario now completes cleanly with a graceful "couldn't find that in our policy documents" draft instead of an error.
- **Python test suite**: all 4 existing `pytest` tests in `python/test_main.py` re-verified passing after conversion to PKR values and the new Rs 500,000 large-amount threshold (`pytest python/test_main.py` — 4 passed).
- **n8n workflow file validation**: `n8n/validate_workflows.py` passes on all 9 workflow files (the original 7 plus the two new ones, WF-08 and WF-09) after every change in this session.

## Not yet covered by any automated test

Standing-order weekend/holiday behavior (not built — see `decisions.md`), joint-account majority-vote governance (not built), guardian/minor account permissions (not built). These are scope decisions, not test gaps — there's nothing to test because the feature doesn't exist. See `mvp-scope.md`.

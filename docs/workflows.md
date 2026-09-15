# n8n Workflows — Quick Reference

The full operator manual (credentials, import/activation order, real Gmail test scripts) lives in [`n8n/README.md`](../n8n/README.md). This page is the short index plus what changed in the 2026-09-14 review.

| Workflow | Trigger | Purpose |
|---|---|---|
| WF-00 Gmail Front Door | Gmail Trigger (poll unread, every minute) | Resolves sender → profile, authorizes against `account_holders`, classifies intent (balance / transfer / policy / standing order / dispute / open account / joint open / loan application / deposit / unauthorized), routes to the right sub-workflow, sends the customer-facing reply. |
| WF-01 Transfer | Sub-workflow + webhook (`/webhook/transfer`) | Validates the payload (no fallback defaults — a missing field is a rejected request), calls `execute_transfer()`, returns success/failure. |
| WF-02 Standing Orders | Schedule (hourly) | Finds due orders, calls `execute_standing_order()`, retries up to 3 times, alerts ops on permanent failure. **Was broken on every run until 2026-09-15** — see Session 5 below. |
| WF-03 Fraud Hold | Sub-workflow + webhook (`/webhook/assess-fraud`) | Calls the Python fraud microservice, places a full-account freeze via `place_account_hold()` on high risk, alerts ops. |
| WF-04 RAG Support | Sub-workflow + webhook (`/webhook/support-case`) | LangChain agent (Groq + Pinecone + Gemini) drafts a grounded policy answer. Grounded + confident (≥0.7) → sent to the customer directly. Below that bar → falls to "needs human" and queues for WF-05. Designed in Session 5, but the direct-send path was silently broken by two CHECK-constraint violations until Session 7 caught and fixed it with a live test. |
| WF-05 Human Approval | Webhook (`/webhook/approve-draft`, `/webhook/approve-loan`) | Two independent webhook triggers in one workflow. `/approve-draft` handles only the RAG cases WF-04 couldn't confidently answer. `/approve-loan` (new, Session 7) lets an operator approve/reject a loan WF-00 queued as `pending_review` (amounts over Rs 200,000), calling `approve_loan`/`reject_loan` and emailing the customer either way. |
| WF-06 Reconciliation | Schedule (midnight UTC) | Calls `run_reconciliation()`, alerts ops on any ledger discrepancy. Also runs `promote_minors_to_adult()` on the same schedule. |
| WF-08 Joint Invitation Expiry Sweep | Schedule (every minute) — **deactivated** | Superseded: was burning ~1,440 n8n executions/day regardless of need. Kept, deactivated, for optional temporary use during a live demo. The same logic now runs opportunistically inside WF-00 (see below) at zero standing cost. |
| WF-09 Seed Policy Documents | Manual/one-time utility | Embeds the 13 PKR-denominated policy documents (see [`docs/policies.md`](policies.md)) into Pinecone via Gemini embeddings — re-run after any Pinecone index recreation. |

**Invitation expiry sweep (folded into WF-00)**: a parallel branch off the Gmail Trigger node calls `expire_stale_joint_invitations()` on every real incoming email and notifies any inviter whose invitation expired. See `decisions.md` Session 4 for why this replaced the standalone WF-08 scheduler.

## Changes made in the 2026-09-14 review

- **WF-00, WF-01, WF-04**: each had a newer, safer draft sitting unpublished in the n8n editor — the *live* version had hardcoded fallback account/profile/fraud-assessment IDs that activated on malformed input instead of rejecting the request. Republished all three to their improved drafts.
- **WF-00, WF-03**: the Python fraud-service call used `$vars.PYTHON_SERVICE_URL` directly, which is stored without an `https://` scheme — every call failed with `Invalid URL`. Both HTTP Request nodes now normalize the scheme in the node itself, so the fix doesn't depend on how the instance variable happens to be formatted.
- **WF-03**: `place_account_hold` returns a bare `UUID` (unlike every other financial RPC, which returns `JSONB`), which crashed n8n's JSON auto-detect. Forced `responseFormat: text` on that node.
- Supabase: added explicit deny-all RLS policies for `anon`/`authenticated` on the four internal-only tables that had RLS enabled with no policies (`003_rls_explicit_deny_policies.sql`).

See `decisions.md` → "Known live issues" for what still needs a manual fix outside n8n (Railway env vars, Pinecone index creation).

## Session 5 fixes (2026-09-15)

- **WF-00**: `Check Pending Joint Invitation` returns zero rows for anyone without a pending joint invitation (almost everyone), and n8n does not execute a node's downstream nodes when it outputs zero items — so the *entire* main pipeline (transfer, balance, policy, open-account) was silently never running after that node. Confirmed via two real executions. Fixed by adding `alwaysOutputData: true` to that node, matching the same setting already used on `Lookup Profile by Email` a few nodes earlier in the same graph.
- **WF-02**: `Fetch Due Standing Orders`'s date filter used `{{ $now.toISO() }}` inside a raw query string; the resulting `+05:00` offset gets read as a literal space once it hits PostgREST, producing `invalid input syntax for type timestamp with time zone`. Every hourly run had failed this way since the workflow was activated (17/17 executions checked). Fixed by switching to `{{ $now.toUTC().toISO() }}` (ends in `Z`, no `+`). Verified live post-fix (execution succeeded, 0 orders due at that moment).

Full root-cause writeups: `decisions.md` → "Session 5".

## Session 7 fixes (2026-09-15)

- **New money-origination feature**: `TREASURY-MAIN` (bank capital account), `loans` table, `deposit_funds`/`apply_for_loan`/`approve_loan`/`reject_loan` RPCs, new WF-00 intents (`LOAN_APPLICATION`, `DEPOSIT`), and a new `/webhook/approve-loan` trigger in WF-05. See `docs/policies.md` → "Where does the money come from?" for the design and `decisions.md` → "Session 7" for the full writeup, including two bugs caught by live testing before they shipped (a reconciliation-breaking genesis-funding mistake, and two CHECK-constraint violations that had silently broken Session 5's RAG auto-answer feature since it was written).
- **WF-05**: `Fetch Loan & Profile Info`'s Supabase query initially failed with a PostgREST 300 ambiguity error (`loans` has two foreign keys to `profiles`) — fixed by qualifying the embed to `profiles!loans_profile_id_fkey(*)`.

Full root-cause writeups: `decisions.md` → "Session 7".

## Session 8 fixes (2026-09-15)

- **WF-00**: keyword-only intent classification was too brittle ("Create a account" fell through to the generic fallback). Widened the keyword lists and added a Groq-based fallback classifier for both the existing-customer and new-sender paths, used only when the keywords genuinely can't decide. Verified against 8+ phrasings via a throwaway test harness before wiring in — the obvious model+structured-parser combo silently failed on short inputs; fixed by switching to plain-text output.
- **WF-00**: reorganized all 82 nodes into a clean layered layout (programmatic, by hop-distance from the trigger) — the canvas had accumulated overlapping nodes from many incremental sessions. No logic or connections changed; re-verified with the connection-completeness audit.

Full root-cause writeup, including two wiring bugs caught before publishing: `decisions.md` → "Session 8".

## Session 9 changes (2026-09-15)

### Two mailboxes

| Mailbox | Role |
|---|---|
| **Bank inbox** | The only address customers ever see. The WF-00 Gmail Trigger polls it, and every customer-facing email is sent from it. |
| **Ops inbox** | Receives every request that needs a human decision. The operator replies APPROVE or REJECT to that email; the reply lands back in the **bank** inbox, where WF-00 recognises the reference code and applies the decision. |

There is no second Gmail credential and no second trigger — the ops reply is just another email arriving at the bank inbox, which is why this needs no extra OAuth setup.

Both addresses are redacted in this repository (`ops-team@yourbank.example`, `bank@yourbank.example`). The live n8n Cloud workflows use the real addresses. If you import these JSON files into your own n8n, set them in: WF-00 `Detect Reference Reply` (the `OPS_TEAM_EMAIL` constant), WF-00 `Alert Ops - Loan Pending Review`, `Confirm Decision to Ops Team`, `Send Ops Decision Problem Email`, `Alert Ops - Joint Transfer Fraud Block`, WF-01 `Email Ops - Transfer Failed Alert`, WF-02 `Email Ops Team - Standing Order Failed`, WF-03 `Email Ops - Fraud Hold Placed Alert`, WF-04 `Alert Ops - Policy Answer Needs Review`, WF-06 `Email Ops Team - Reconciliation Mismatch`.

### Reference codes

Every email that asks a human to decide something carries a short code in its subject line. Replying to the email is enough — the code comes back with it.

| Prefix | Who may answer | Enforced by |
|---|---|---|
| `OPS-XXXXXXXX` | the ops mailbox only | WF-00 `Detect Reference Reply` compares the real Gmail sender; a code quoted by anyone else is ignored and the email is handled as an ordinary customer message |
| `JNT-XXXXXXXX` | any holder of that account | `respond_to_joint_action_by_ref()` in Postgres |
| `MIN-XXXXXXXX` | the named guardian only | `respond_to_minor_account_request()` in Postgres |

A reply that contains both APPROVE and REJECT, or neither, is never guessed at: the sender gets a short "we could not read your answer" email and the request stays pending.

### What changed per workflow

- **WF-00** (82 → 134 nodes). New `Detect Reference Reply` → `Is Reference Reply?` → `Route Reference Kind` branch sits between `Extract Email Metadata` and the existing pipeline, with four sub-branches: ops decision, joint co-holder consent, guardian consent, and unclear-reply clarification. Account opening now gates on date of birth and age (`Account Opening Eligibility`) and routes under-18 applicants through `Request Minor Account` → guardian consent. `Open First Account for New Customer` calls `open_account_with_details` instead of `open_account_for_profile`, so the date of birth and phone number are stored. Joint invitations carry the chosen mandate. A transfer parked for signatures emails the requester and every co-holder still to sign.
- **WF-01**. `Transfer Pending Result` now carries the `JNT` ref code, both account numbers, the amount, the requester's name, the expiry and the list of holders still to sign — WF-01 already called `initiate_transfer`, so the mandate enforcement added in migration 012 took effect here with no node change.
- **WF-03**. A fraud freeze raises a `fraud_hold_release` ops approval and the alert carries its code; replying APPROVE releases the hold (and unfreezes the account if it was the last freeze), REJECT leaves it in place. Previously clearing a fraud hold meant calling `release_account_hold` by hand.
- **WF-04**. An answer the agent could not ground confidently raises a `support_draft` ops approval and emails the ops mailbox the draft. APPROVE sends it; APPROVE plus a `NOTE:` line sends that text instead; REJECT closes the case without emailing the customer.
- **WF-06**. The nightly run also calls `expire_stale_ops_approvals()` and `expire_stale_minor_account_requests()`.

`/webhook/approve-draft` and `/webhook/approve-loan` in WF-05 still work and are unchanged. They are now the fallback path rather than the primary one.

Full root-cause writeup, including the two bugs found by live testing: `decisions.md` → "Session 9".

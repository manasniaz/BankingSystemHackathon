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

## Session 10 changes (2026-09-15)

### Policy documents are now documents

Six readable policy documents live in [`docs/policy-documents/`](policy-documents/) and are the source of truth for every RAG answer. WF-09 gained a second branch that reads them from a Google Drive folder and seeds Pinecone namespace `banking_policy_v2`, so policy can be edited without touching code. See [`docs/policy-documents/README.md`](policy-documents/README.md) for the one-time setup and the namespace switch-over.

The live bank still answers from namespace `banking_policy` until `v2` is verified. That is deliberate — the six documents rewrite the same subject matter as the original nineteen snippets, and having both retrievable risks a contradictory answer.

### The RAG assistant now actually answers

WF-04's agent no longer uses a structured-output parser. The only Groq model available on this account fails that call intermittently, which was sending correct, fully-grounded answers to human review with `confidence: 0`. The agent now returns labeled plain text, parsed by `Parse Agent Draft Output`. Verified live: grounded, confidence 1.0, answer sent directly with no human step.

### New and changed per workflow

- **WF-00** (137 → 146 nodes).
  - `Is Automated Sender?` → `Ignore Automated Sender` sits immediately after `Extract Email Metadata`, ahead of everything including the reference-code branch. Mail from `no-reply@`, `mailer-daemon@`, `postmaster@`, bulk-mail domains and `accounts.google.com` ends there silently — no reply, no case, no lookup.
  - `Route Ops Decision Outcome` gained a fourth branch, `Policy Answer Rejected`, so an ops REJECT on a policy draft sends the customer a graceful decline instead of nothing at all. The fallback moved from output 3 to output 4.
  - **`ACCOUNT_CLOSURE` is a new intent.** `Detect Account Closure Intent` sits after both classifier paths converge and promotes `UNKNOWN` to `ACCOUNT_CLOSURE` on unmistakable wording. It never overrides a confident classification — a closure *question* stays `POLICY_RAG`, and "close it and send my balance to X" stays `TRANSFER`.
  - Closure handler: `Resolve Account Closure Request` → `Closure Request Understood?` → `Request Account Closure` → `Closure Request Accepted?` → `Split Closure Confirmers` → `Ask Holder To Confirm Closure`, with `Send Closure Clarification Email` and `Send Closure Blocked Email` on the failure paths. `Route by Intent` gained rule 10; its fallback moved to output 11.
- **WF-04**. Structured output parser removed, `Parse Agent Draft Output` added, agent set to retry twice on failure.
- **WF-09**. Drive sync branch added: `Sync From Drive Trigger` → `Drive Folder Config` → `List Policy Documents in Drive` → `Download Policy Document` → `Extract Document Text` → `Prepare Drive Policy Document` → `Skip Unreadable Files` → `Seed Policy Docs From Drive`.

### Closing an account

A closure request never closes anything on its own. Every holder, **including the person who asked**, must reply `APPROVE` to an emailed `JNT-` reference code — closure is irreversible and a single unverified sentence in an email is not enough to act on.

Blocked up front, with the reason stated in plain language, when the account has: a non-zero balance (the amount is quoted and the customer is told to transfer it out first), an active hold, an active standing order paying out of it, an outstanding or pending loan, or a frozen status.

The confirm-and-execute half needed no new code — `respond_to_joint_action_by_ref()` and `finalize_joint_action_if_complete()` already handled `action_type = 'close_account'` from Session 9.

### A recurring hazard worth naming

Adding a rule to an n8n Switch shifts its fallback output index. This project has now been bitten three times (Sessions 7, 9, 10). Rewiring connections and adding the rule are separate operations, and between them the fallback is mis-aimed — in this session's case, briefly routing every unclassified email in the bank into the account-closure flow. Run the rule-count-versus-connection-count audit after every switch change.

Full root-cause writeup: `decisions.md` → "Session 10".

## Session 11 changes (2026-09-15)

Every one of the capstone brief's 32 items is now built. This session closed the last twelve gaps. Full reasoning in `decisions.md` → "Session 11".

### New reference code

| Prefix | Who may answer | Enforced by |
|---|---|---|
| `DSP-XXXXXXXX` | any holder of the disputed account | `add_dispute_holder_input()` in Postgres |

Joins the existing `OPS-`, `JNT-` and `MIN-` families. An invited holder replying to a `JNT-` add-holder code is now routed to `accept_holder_addition()` rather than refused for not yet being a holder.

### New and changed per workflow

- **WF-00** (146 → 167 nodes).
  - **`STATEMENT`** is a new intent. `Resolve Statement Request` picks the account and period (defaulting to last full month, understanding "this month", "this year" and explicit `YYYY-MM-DD to YYYY-MM-DD`), the Python service renders it, and it is emailed as readable text. Won't guess which account when the customer holds several.
  - **`DISPUTE` is no longer an acknowledgement dead end.** It creates a tracked dispute with a `DSP-` reference, queues it for a human, and on a joint account emails every other holder for their side. This also fixed a latent bug: the DISPUTE branch fired **both** the generic could-not-process reply and the dispute acknowledgement, sending two contradictory emails.
  - `Detect Late Intent Overrides` (renamed from `Detect Account Closure Intent`) now promotes `UNKNOWN` to `STATEMENT` as well as `ACCOUNT_CLOSURE`. It still never overrides a confident classification.
  - Dispute-input branch: `Add Dispute Holder Input` → `Dispute Input Recorded?` → confirmation or problem email.
  - `Route by Intent` gained rule 11 (`STATEMENT`); its fallback moved to output 12. `Route Reference Kind` gained rule 3 (`Dispute Input`); its fallback moved to output 4.
- **WF-02**. On a permanently failed standing order, every holder of the source account is now emailed directly — what failed, why, and what to do — with distinct wording when it was a loan repayment. Previously only ops was told.
- **WF-03**. The ops alert now carries the three most similar known fraud typologies, retrieved semantically, each with its innocent explanations. Advisory only and clearly labelled as such: the freeze decision remains the deterministic rules engine.
- **WF-04**. Citation guardrail — an answer claiming to be grounded with zero citations is forced to human review whatever confidence it reports. Retrieval bounded to `topK` 4.
- **WF-06**. Nightly run extended with `sweep_outstanding_debts()` and `accrue_monthly_interest()`, both idempotent.
- **WF-09**. Third branch seeding ten fraud typologies into a separate `fraud_patterns` namespace.

### Pinecone namespaces

| Namespace | Contents | Read by |
|---|---|---|
| `banking_policy` | the 19 policy snippets (live) | WF-04 `Policy Knowledge Base` |
| `banking_policy_v2` | the six Drive-sourced documents (staged, not yet live) | nothing yet — switch WF-04 across once verified |
| `fraud_patterns` | ten fraud typologies | WF-03 `Search Fraud Patterns` |

They are deliberately separate. A fraud typology must never be retrievable by the customer-facing policy assistant — it would be both wrong and a disclosure of how detection works. And because past support cases are never indexed at all, the "similar-but-wrong past case" failure the brief asks about cannot occur by construction.

### A recurring hazard, now automated away

Adding a rule to an n8n Switch shifts its fallback output index, and this project has been bitten by it four times (Sessions 7, 9, 10, 11). The graph audit now checks rule count against connection count for every switch and reports any rule or fallback with no target. Run it after every switch change.

## Session 12 changes (2026-09-16)

### The transfer fix

`Execute WF-01 Transfer Sub-Workflow` had no input mapping. An Execute Sub-workflow node forwards the items it receives, and the node feeding it was the fraud service — so WF-01 received `{approved, risk_score, reason, fraud_assessment_id}` and none of the transfer. It rejected every transfer for missing required fields, and the customer was told *"Transfer rejected by banking rules"*.

**`Build Transfer Payload`** sits between `Fraud Cleared?` and the sub-workflow call and rebuilds the payload explicitly from `$('Resolve Transfer Target & Authorize')` and `$('Look Up Destination Account')`. A sub-workflow cannot see the parent's node history; every field it validates has to be handed to it.

### Staff mail never enters the customer path

`Is Reference Reply?` (false) now goes to **`Is Ops Team Sender?`** before anything else. Ops mail branches to `Parse Ops Command` → `Route Ops Command`; everything else continues to the customer flow exactly as before.

`Parse Ops Command` recognises two commands and nothing else:

| Command | Effect |
|---|---|
| `credit 5000 to someone@example.com` | `operator_credit_account()` — a grant, no loan, nothing to repay |
| `reject loan for ACC-1234567890` | `operator_decide_loan()` on a pending application |

`NOTE:` on its own line attaches a reason. Anything unrecognised gets `Email Ops - Command Not Understood`, which lists the supported forms, and nothing changes. A broader parser here would move real money on a guess.

### One place holds the bank's own addresses

`Detect Reference Reply` now emits **`bankEmail`** alongside `opsTeamEmail`, and every node downstream reads them from there instead of repeating a literal. That node is the only place in the live workflow carrying the real addresses; the repository copy carries placeholders.

### Quote stripping works on one-line replies

The cut markers were anchored to line starts. Proton Mail on Android sends the whole reply as a single line, so nothing matched and the quoted original was read as the customer's own text — including the bank's address in `On … <…> wrote:`. Markers are now unanchored and cut at the earliest match anywhere in the body. Fixed in both `Detect Reference Reply` and the intent classifier; in the former the consequence would have been a pending approval decided by the quoted message instead of by the person replying.

### New and changed per workflow

| Workflow | Change |
|---|---|
| **WF-00** | 167 → **187 nodes**. `Build Transfer Payload`; `Is Ops Team Sender?` → `Parse Ops Command` → `Route Ops Command` with credit and loan-decision chains and their confirmation emails; `Withdraw Loan Application` → `Loan Withdrawn?` chain with customer and ops emails; `Look Up Destination Account` replaced by an RPC call to `resolve_destination_account()`; new `LOAN_CANCEL` intent and switch rule; question-about-a-past-action guard; `Finalize LLM-Classified Intent` reduced to relabelling only. |
| **WF-04** | `Policy Knowledge Base` namespace switched from `banking_policy` to **`banking_policy_v2`** — the six consolidated documents synced from Drive. Rollback is this one field. |
| **WF-09** | 23 → **25 nodes**. `Get Pinecone Index Host` → `Clear Staging Namespace` now run before the Drive listing, so a re-sync **replaces** rather than appends. `Drive Folder Config` holds the real folder ID. `Prepare Drive Policy Document` skips `README.md` and other non-policy files. |

### Intent classification

`LOAN_CANCEL` is tested **before** `LOAN_APPLICATION`, or "cancel my loan application" reads as an application. A question about a past outcome (`why … rejected`, `what happened to …`) routes to support rather than being executed again. A `TRANSFER` with neither an amount nor a recipient is reclassified rather than answered with a complaint about the missing account number.

`Finalize LLM-Classified Intent` was also silently coercing `ACCOUNT_CLOSURE` and `STATEMENT` to `UNKNOWN` — the model was told to emit them but they were absent from its `validLabels` list.

### Transfers by email address

`Look Up Destination Account` now calls `resolve_destination_account()`, which accepts an account number **or** a registered email address and reports ambiguity instead of picking when someone holds several accounts. `Send Destination Not Found Email` explains which of the four cases applies.

An address in the message body may name a recipient. It still never establishes who is asking — identity remains the envelope sender, always.

### WF-05 unpublished: an unauthenticated loan-approval endpoint

Five workflows expose public webhooks wired straight to live logic, none with authentication:

| Workflow | Path | State |
|---|---|---|
| WF-01 | `/webhook/transfer` | inert — no Respond to Webhook node, errors at the trigger |
| WF-03 | `/webhook/assess-fraud` | inert — same |
| WF-04 | `/webhook/support-case` | inert — same |
| **WF-05** | `/webhook/approve-draft`, `/webhook/approve-loan` | **was live** |

WF-05 has eight Respond to Webhook nodes, so unlike the others its endpoints ran. `POST /webhook/approve-loan` parsed a request and replied; with a real loan id and `action: approve` it would have approved the loan, disbursed the funds and emailed the customer — for anyone who knew the URL.

**WF-05 is unpublished.** Both paths now return 404. Nothing references it, and its entire job was already being done by the `OPS-` reference-code flow in WF-00:

| WF-05 did | WF-00 does |
|---|---|
| Approve/reject a support draft, email the customer | `Resolve Ops Approval` → `Route Ops Decision Outcome` → `Send Reviewed Policy Answer to Customer` / `Send Policy Answer Rejected Email` |
| Approve/reject a loan, email the customer | same route → `Send Loan Approved Email (Ops Decision)` / `Send Loan Rejected Email (Ops Decision)`, plus `operator_decide_loan()` |
| Update draft/case state, write audit rows | done inside `resolve_ops_approval()` in SQL |

It was superseded when ops moved to email, and was simply left running. Deleting it, and removing the three inert webhook triggers, is still worth doing.

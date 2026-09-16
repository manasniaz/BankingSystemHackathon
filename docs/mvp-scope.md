# MVP Scope

What this submission includes, what it deliberately leaves out, and why. This is the short version — the item-by-item reasoning for every edge case in the capstone PDF lives in [`decisions.md`](decisions.md).

> **Update (2026-09-15):** Several items below (minor/guardian accounts, either-or vs. both-signature authority, majority-vote governance, holder addition with active holds, real account opening) were moved from "out of scope" into "built" in a follow-up pass. See `decisions.md`'s **Session 2 Addendum** for the full detail — this page hasn't been fully rewritten to match, so where the two disagree, `decisions.md` is authoritative.

## In scope (built and live)

- Single-holder, joint and guardian-supervised minor account creation. Full multi-holder governance: closure, transfer mandate, holder addition, holder removal and authority changes, all by recorded consent.
- Atomic, idempotent, double-entry transfers via `execute_transfer()` — isolation-safe under concurrent withdrawals, fully rolled back on any partial failure.
- Deterministic Python fraud scoring (4 rules) gating every transfer, with automated full-account-freeze on high risk.
- Standing orders: hourly execution, retry-with-max-3, permanent-failure alerting, stale-lock-safe against concurrent edits.
- Nightly ledger reconciliation (debit=credit system-wide, cached balance vs. ledger sum per account).
- RAG-drafted policy support answers: a grounded, confident (≥0.7) answer is sent straight to the customer; anything else degrades to a mandatory human approval gate instead of guessing. Human review is for what's actually ambiguous, not every request. That gate is the `OPS-` reference-code email round trip in WF-00 — an operator replies `APPROVE` or `REJECT` from the operations mailbox. (It was originally WF-05, an HTTP approval workflow, which has been retired.) See `decisions.md` Sessions 5, 9 and 12, and `docs/policies.md`.
- Gmail as the sole customer-facing channel, both inbound (intent classification from real emails) and outbound (every response path).
- 24-table Postgres ledger of truth, 59 `SECURITY DEFINER` RPCs as the only financial mutation path, RLS on every table.
- **Email-driven human approval**: a dedicated ops mailbox receives every decision that needs a person — a loan over Rs 200,000, a policy answer the RAG agent couldn't ground, a fraud freeze — and the operator decides it by replying APPROVE or REJECT to that email. See `decisions.md` Session 9.
- **Account opening with real details**: date of birth (four accepted formats) and optional phone, stored on the profile. Under 18 routes to guardian consent instead of opening an account.
- **Minor and guardian accounts**: guardian-acts / minor-views-only, enforced in Postgres, with automatic conversion to full access at 18.
- **Joint account mandates**: either-or or all-signatures, chosen by the customer in plain English at invitation time, enforced on every transfer; co-holders sign by replying to an email.
- **Money-in**: a real funding source (`TREASURY-MAIN`, funded from a `BANK-CAPITAL` account, both ledger-backed) instead of every account being permanently stuck at Rs 0.00. Self-service deposits (capped, rate-limited) and loans (flat 10% interest, auto-approved ≤ Rs 200,000, human-reviewed up to Rs 2,000,000) via `apply_for_loan`/`approve_loan`/`reject_loan`/`deposit_funds`. See `decisions.md` Session 7.

## Explicitly out of scope for this submission

> **Update (2026-09-15, Session 11): nothing from the capstone brief is out of scope any more.** All 32 items in `decisions.md` now read Built. The list that follows is kept only as a record of what was once deferred and why, since several of the original refusals turned out to rest on faulty reasoning — see `decisions.md` → "Session 11" → "Where the earlier reasoning was actually wrong".

### Historical record of deferrals (all since resolved)


See `decisions.md` for the full reasoning per item. Summary:

- ~~**Minor/guardian accounts and age-based access triggers**~~ — **built in Session 9.** Account opening captures a date of birth, an under-18 applicant needs their named guardian to consent by email, only the guardian can move money out, and `promote_minors_to_adult()` restores full access at 18.
- ~~**Either-or vs. both-signature authority configuration, majority-vote governance for 3+ holders**~~ — **built in Session 9.** The mandate is chosen at invitation time and enforced by `initiate_transfer()`; majority closure for 3+ holders is honoured by `finalize_joint_action_if_complete()`. **Holder removal is still unbuilt**, and adding a holder to an account with active holds exists as `add_account_holder(..., p_acknowledge_active_holds)` but has no customer-facing email intent yet.
- ~~**Reversal/chargeback into a negative balance**~~ — **built in Session 11**, and the original instinct was right: it *is* a parallel, clearly-labelled structure (`account_debts`), not a schema exception. `balance >= 0` is untouched.
- ~~**Weekend/holiday-aware standing order scheduling**~~ — **built in Session 11** against a real `bank_holidays` calendar. The original reasoning still justifies `allow_weekend` remaining a legitimate option, but it did not justify having no calendar at all.
- ~~**Interest calculation**~~ — **built in Session 11.** Savings earn 5% p.a., accrued monthly from the treasury through the normal double-entry path.
- ~~**Pinecone-side fraud-pattern semantic search**~~ — **built in Session 11** as an advisory layer for the human reviewing a freeze. Fraud *scoring* is still the deterministic rules engine only, deliberately.

## Infrastructure gaps found during review (not scope decisions — bugs/config to fix)

Tracked in `decisions.md` → "Known live issues": the Railway Python service URL scheme, the `place_account_hold` response-parsing crash, missing Supabase env vars on Railway, and the empty Pinecone index. **All four are now resolved.** The Railway environment variables have been set and `/assess-fraud` returns real rules-engine scores against live data; the Pinecone index is seeded and `banking_policy_v2` is fed from Google Drive.

The Railway one stayed open far longer than it should have because it was not *checkable*: `/health` returned `{"status": "ok"}` whether or not the service could reach the database, so the only symptom of a misconfigured deployment was every transfer being blocked — which looks exactly like fraud detection working. `/health` now reports credential presence and a live database round-trip, so the question "is the deployment configured?" has an answer that does not involve moving money.

**Found and closed in Session 12:** `POST /webhook/approve-loan` on WF-05 was a live, unauthenticated endpoint that could approve a loan and disburse funds to anyone who knew the URL. WF-05 is now unpublished; it was superseded by the `OPS-` email flow in WF-00 and nothing referenced it. The equivalent webhooks on WF-01, WF-03 and WF-04 are inert — they declare `responseMode: responseNode` with no such node present, so n8n errors at the trigger — but they should still be deleted. See `decisions.md` → Session 12.

## Genuinely still not built

These were never in the capstone brief and remain deliberately absent:

- **Multi-currency / FX conversion.** Every account is PKR. A cross-currency transfer is refused rather than converted at an unpublished rate.
- **Real interbank settlement.** This bank settles instantly and internally against its own ledger; there are no external rails.
- **Removing a holder while keeping an account open in a way that reallocates their share of holds or standing orders.** Removal is supported, but it does not attempt to divide anything — it is refused outright while the account is encumbered.
- **Customer-initiated holder management by email.** `request_holder_addition`, `request_holder_removal` and `request_authority_change` are fully built, tested and reachable by RPC, and every *response* arrives by email via the JNT reference codes. What is not wired is an inbound email intent to *start* one; today an operator initiates it. This is the one place where a built capability has no customer-facing front door.
- **Sending money to a person by name.** Deliberately absent, and distinct from sending to an **email address**, which is supported. A name is not unique and proves nothing; an email address is the exact thing this bank authenticates on. Where an address resolves to more than one account we ask which, rather than choosing.
- **Ops commands beyond crediting an account and deciding a pending loan.** The operations mailbox is understood as staff, not as a customer, but its free-text command vocabulary is deliberately two commands wide. Anything else is answered with the list of supported forms and changes nothing. A broader natural-language parser on an input that moves real money would be guessing.

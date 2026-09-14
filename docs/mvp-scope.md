# MVP Scope

What this submission includes, what it deliberately leaves out, and why. This is the short version — the item-by-item reasoning for every edge case in the capstone PDF lives in [`decisions.md`](decisions.md).

## In scope (built and live)

- Single-holder and joint account creation, unanimous-consent joint account **closure** only (not holder removal, not other joint actions).
- Atomic, idempotent, double-entry transfers via `execute_transfer()` — isolation-safe under concurrent withdrawals, fully rolled back on any partial failure.
- Deterministic Python fraud scoring (4 rules) gating every transfer, with automated full-account-freeze on high risk.
- Standing orders: hourly execution, retry-with-max-3, permanent-failure alerting, stale-lock-safe against concurrent edits.
- Nightly ledger reconciliation (debit=credit system-wide, cached balance vs. ledger sum per account).
- RAG-drafted policy support answers with a mandatory human approval gate before anything reaches a customer, plus a grounded/confidence threshold that degrades to "needs human" instead of guessing.
- Gmail as the sole customer-facing channel, both inbound (intent classification from real emails) and outbound (every response path).
- 15-table Postgres ledger of truth, `SECURITY DEFINER` RPCs as the only financial mutation path, RLS on every table.

## Explicitly out of scope for this submission

See `decisions.md` for the full reasoning per item. Summary:

- **Minor/guardian accounts and age-based access triggers** — needs a permissions layer that doesn't exist yet (`account_holders.role`, RLS, and every n8n intent handler would all need to branch on it). Real v2 scope.
- **Either-or vs. both-signature authority configuration, majority-vote governance for 3+ holders, holder removal, adding a holder to an indebted account** — the joint-account model only implements unanimous-consent *closure*; every other multi-holder governance question is unbuilt.
- **Reversal/chargeback into a negative balance** — the schema enforces `balance >= 0` everywhere as a deliberate invariant; a real debt-tracking ledger would need to be a parallel, clearly-labeled structure, not a schema exception.
- **Weekend/holiday-aware standing order scheduling** — this system settles instantly and internally, so the real-bank problem (waiting for the next business day to clear via interbank rails) doesn't apply the same way. Documented rather than silently ignored.
- **Interest calculation** — no interest-bearing account type or rate schedule exists.
- **Pinecone-side fraud-pattern semantic search** — fraud scoring is the deterministic Python rules engine only; there's no vector-similarity fraud lookup.

## Infrastructure gaps found during review (not scope decisions — bugs/config to fix)

Tracked in `decisions.md` → "Known live issues": the Railway Python service URL scheme, the `place_account_hold` response-parsing crash, missing Supabase env vars on Railway, and the empty Pinecone index. The first two were fixed in this review; the latter two need a manual step in Railway/Pinecone's own dashboards (credential entry that shouldn't be done by an agent) — see the README's "Known Dependencies" section for exact next steps.

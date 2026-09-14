# Security Model

## Roles

| Role | Where it's used | RLS applies? | Can it move money? |
|---|---|---|---|
| `anon` / customer JWT | Not yet wired to a customer-facing app in this MVP (Gmail is the only channel) | ✅ Yes | No — read-only by design, and no financial write policies exist for it anywhere. |
| `service_role` | n8n Cloud (all 7 workflows), Python fraud microservice (Railway) | ❌ Bypassed | Only indirectly, by calling `SECURITY DEFINER` RPCs — it never runs raw `UPDATE`/`INSERT` against `accounts`, `ledger_entries`, or `audit_log`. |
| `banking_functions` | Internal Postgres role, owns every financial RPC | N/A (DB-internal) | Yes — this is the only role with `GRANT`s to mutate `accounts.balance`, insert `ledger_entries`, or insert `audit_log`. Never exposed to any external credential. |

## Hard rules enforced in schema

- `ledger_entries` and `audit_log` are **append-only**: a trigger (`prevent_modification_append_only()`) raises an exception on any `UPDATE` or `DELETE`, regardless of role.
- `accounts.balance` has `CHECK (balance >= 0)` — the schema itself refuses to store a negative balance; see `decisions.md` #14 for why chargeback-into-debt was scoped out rather than special-cased around this.
- All 15 tables have RLS **enabled**. Four internal-only tables (`audit_log`, `idempotency_keys`, `reconciliation_runs`, `support_case_drafts`) had RLS enabled with no policies — functionally already deny-all for non-bypassing roles, but migration `003_rls_explicit_deny_policies.sql` makes that explicit so it isn't just incidental.
- Every financial RPC (`execute_transfer`, `execute_standing_order`, `place_account_hold`, `release_account_hold`, `close_account`, etc.) is `SECURITY DEFINER`, owned by `banking_functions`, and does its own authorization/validation inside the function body rather than trusting the caller.

## Credential handling

- Supabase `service_role` key, Groq/Pinecone/Gemini API keys, and the Gmail OAuth2 token live only in n8n Cloud's credential store and Railway's environment variables. None of them are committed to this repository (`python/.env.example` ships placeholder values only).
- Groq/Gemini (the LLM layer) only ever receive customer inquiry text and retrieved policy snippets — never account numbers, balances, or amounts. They cannot write to any financial table; their only write path is `support_case_drafts`, which itself cannot reach a customer without the human approval gate in WF-05.

## Email-based identity (specific to this system's design)

Because Gmail is the only customer channel, sender-email verification is the front door to everything: WF-00 resolves the sender's address against `profiles.email` before any other logic runs, and rejects unregistered senders outright. This means **the security of the whole system currently rests on Gmail's own sender-authentication guarantees** (SPF/DKIM/DMARC as enforced by Google) rather than a customer-held credential like a JWT. That's an accepted tradeoff for an email-native MVP, not an oversight — a future iteration that accepts other channels would need to reintroduce a real auth token.

## Known gaps (tracked, not hidden)

See `decisions.md` → "Known live issues" for the Railway/Pinecone configuration gaps found during this review, and `mvp-scope.md` for the account-governance features (guardian accounts, either-or vs. both-signature authority) that were deliberately not built.

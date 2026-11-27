# Server migration history

`backend/supabase/migrations/` is the ONLY active migration directory. The
Supabase CLI applies every `*.sql` here, in filename order, and records each
in `supabase_migrations.schema_migrations`.

## Active chain (in order)

| File | Represents |
| --- | --- |
| `20261030000000_production_baseline.sql` | Complete production schema snapshot (read-only declarative export, 2026-11-24), BEFORE the H1 migrations. Fail-closed: aborts on a populated schema. |
| `20261125000000_void_settles_pending_requests.sql` | H1 — void lifecycle hardening; verify production status from remote migration history |
| `20261126000000_void_request_insert_lock.sql` | H1 — void-request locking; verify production status from remote migration history |
| `20261127000000_void_request_sale_fk.sql` | H1 — void-request sale foreign key; verify production status from remote migration history |
| `20261128000000_register_device_unlimited.sql` | Request 2 — atomic unlimited-device `register_device` RPC |
| `20261128000001_rate_limit_buckets.sql` | Request 2 — durable rate limiting |
| `20261201000000_actor_authorization.sql` | Request 3 — device licence vs. human actor authorization and ledger protection |
| `20261202000000_request3_acceptance.sql` | Request 3 — checked RPC grants, retryable sync outcomes, multi-actor finance, owner-bootstrap concurrency |
| `20261203000000_request3_corrections.sql` | Request 3 — owner-bootstrap credential verification, offline finance lifecycle replay, quarantine recovery |
| `20261204000000_request3_financial_integrity.sql` | Request 3 — atomic cash-leg uniqueness and safe legacy-reversal reconciliation |
| `20261205000000_request3_legacy_reversal_safety.sql` | Request 3 — bidirectional legacy-reversal matching and actor-evidence safeguards |
| `20261206000000_request3_late_reversal_dedup.sql` | Request 3 — late-arriving reversal deduplication and audited operator reconciliation |
| `20261207000000_request3_reason_drift_audited_link.sql` | Request 3 — reason-drift safety and audited manual reversal linking |
| `20261208000000_request3_manual_link_amount.sql` | Request 3 — exact amount equality for manual legacy-reversal links |

## Deployment and ordering safeguards

The active 14-file chain passes the cold-replay job against an empty PostgreSQL 17 database (CI [run #39](https://github.com/marrierose25-ui/wholesale-pos/actions/runs/45895098268)). This does **not** prove that a customer/production Supabase project has the same migration history. Before deployment, compare the remote `supabase_migrations.schema_migrations` versions with this active chain; do not infer production state from cold replay or README status.

The latest active migration is `20261208000000_request3_manual_link_amount.sql`. Its timestamp is 2026-12-08, later than the 2026-11-27 audit date. The reason for that future date has not been independently established. Do not rename or reorder a migration that may already have been applied. New migrations must sort after the current latest version unless a reviewed migration-history repair explicitly establishes a safe alternative.

Historical one-off scripts under `docs/*.sql` are not the active migration chain. In particular, `docs/supabase_pos_integrity.sql` declares itself superseded and says not to apply it to production. Destructive bootstrap/reset scripts must never be run against a populated customer database.

## Archived migrations

`backend/supabase/migrations_archive/` holds the ten incremental migrations
(`20261031…`–`20261111…`) that were applied to production BEFORE the baseline
export. Their effects are already inside the baseline snapshot, so replaying
them would fail or double-apply objects. They are preserved for history and
for `migration repair` bookkeeping — see
`docs/architecture/migration-history-repair.md`.

Historical one-off SQL under `docs/*.sql` is NOT a migration source; see
`docs/architecture/migration-history-repair.md` and the SQL classification in
`docs/architecture/database-target-architecture.md`.

## Cold replay

A brand-new database is built by applying this directory from empty:

```bash
# Local Docker Postgres 17 (creates roles/extensions schema the export
# assumes, then applies every active migration in order):
docker run --rm -d --name pos-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:17
bash backend/supabase/scripts/replay_migrations.sh
```

CI runs the same replay plus object/security assertions — see
`.github/workflows/ci.yml` (`supabase-replay` job).

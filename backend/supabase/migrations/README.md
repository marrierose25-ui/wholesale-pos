# Server migration history

`backend/supabase/migrations/` is the ONLY active migration directory. The
Supabase CLI applies every `*.sql` here, in filename order, and records each
in `supabase_migrations.schema_migrations`.

## Active chain (in order)

| File | Represents |
| --- | --- |
| `20261030000000_production_baseline.sql` | Complete production schema snapshot (read-only declarative export, 2026-11-24), BEFORE the H1 migrations. Fail-closed: aborts on a populated schema. |
| `20261125000000_void_settles_pending_requests.sql` | H1 — pending, not yet applied to production |
| `20261126000000_void_request_insert_lock.sql` | H1 — pending |
| `20261127000000_void_request_sale_fk.sql` | H1 — pending |
| `20261128000000_register_device_unlimited.sql` | Request 2 — atomic unlimited-device `register_device` RPC |
| `20261128000001_rate_limit_buckets.sql` | Request 2 — durable rate limiting |

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

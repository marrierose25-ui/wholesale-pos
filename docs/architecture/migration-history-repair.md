# Migration-history repair runbook — DEFERRED, DO NOT EXECUTE YET

> **Status: DEFERRED.** The owner has postponed all production migration
> work until the remaining architecture requests are complete. Nothing in
> this file has been run against production. Execute only after explicit
> human authorization for the rollout window.

## Situation

- Production already contains the schema that the new
  `20261030000000_production_baseline.sql` snapshot represents, plus the
  results of the ten archived incremental migrations
  (`backend/supabase/migrations_archive/`).
- `supabase_migrations.schema_migrations` on production records whatever
  IDs were applied through the CLI historically. The docs-era SQL scripts
  (`docs/*.sql`) were applied manually and may have NO migration rows at
  all — the remote history cannot be assumed complete or empty.
- Pending forward migrations that MUST run after reconciliation:
  `20261125000000`, `20261126000000`, `20261127000000` (H1),
  `20261128000000`, `20261128000001` (Request 2).

## Step 0 — Inspect (read-only)

```bash
supabase link --project-ref <ref>
supabase migration list --linked
```

Record every `LOCAL`/`REMOTE`/`—` row. The goal is to learn which of the
archived IDs (`20261031000000`…`20261111000000`) and the new baseline ID
already have remote rows.

## Step 1 — Reconcile historical IDs

For each archived migration whose DDL is confirmed present in production
(the baseline export is the evidence), mark it applied WITHOUT re-running:

```bash
supabase migration repair --status applied <version> --linked
```

Do this per version. Never repair a version whose objects are NOT in
production — that would silently skip real DDL.

## Step 2 — Mark the baseline applied

The baseline DDL must NEVER execute against production (its fail-closed
guard would abort anyway, but do not rely on that):

```bash
supabase migration repair --status applied 20261030000000 --linked
```

## Step 3 — Apply pending migrations

```bash
supabase db push --linked        # or: supabase migration up --linked
```

Expected order: the three H1 files, then the two Request-2 files. Review
the planned list BEFORE confirming — `db push` prints it.

## Step 4 — Verify

```bash
supabase migration list --linked   # every active file shows REMOTE
```

Then spot-check objects that only the new migrations create:

```sql
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND proname IN
  ('register_device','rate_limit_hit','rate_limit_reset');
SELECT to_regclass('public.rate_limit_buckets');
```

And confirm the H1 invariants still hold by re-running
`backend/supabase/tests/h1_void_invariants/h1_void_invariants_test.sql`
against a fresh local replay (never against production directly).

## Rollback note

There is no down-migration. If a pending migration must be reverted,
write a NEW forward migration that undoes it — never edit applied files.

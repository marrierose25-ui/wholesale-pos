#!/usr/bin/env bash
# Cold-replay the active Supabase migration chain on an EMPTY PostgreSQL 17
# database and verify the resulting schema.
#
# Usage:
#   PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=postgres \
#     bash backend/supabase/scripts/replay_migrations.sh
#
# The script:
#   1. creates the Supabase-compat roles + extensions schema the declarative
#      baseline expects (anon/authenticated/service_role/pg_database_owner
#      semantics, `extensions` schema);
#   2. applies every backend/supabase/migrations/*.sql in filename order;
#   3. asserts key objects exist (tables, functions, RLS, grants).
#
# It NEVER touches a remote database — there is no --remote flag anywhere.
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-55432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST PGPORT PGUSER PGPASSWORD

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MIGRATIONS="$REPO_ROOT/backend/supabase/migrations"
PSQL="psql -v ON_ERROR_STOP=1 -q"

echo "== replay target: $PGHOST:$PGPORT/$PGUSER =="

# --- Supabase-compat bootstrap (empty DB only) ------------------------------
$PSQL <<'SQL'
DO $$
BEGIN
  IF current_database() <> 'postgres' THEN
    RAISE EXCEPTION 'replay must run against a scratch database';
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
SQL

# Baseline guard requires an empty app schema — verify before applying.
POPULATED="$($PSQL -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('customers','licenses','pos_users','sales','sync_mirror')")"
if [ "$POPULATED" != "0" ]; then
  echo "FATAL: application tables already exist — not a cold replay." >&2
  exit 1
fi

# --- Apply migrations in order ------------------------------------------------
for f in "$MIGRATIONS"/*.sql; do
  name="$(basename "$f")"
  echo "applying $name"
  $PSQL -f "$f" >/dev/null
done

# --- Assertions ---------------------------------------------------------------
$PSQL <<'SQL'
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(t, ', ') INTO missing
  FROM (VALUES
    ('customers'),('licenses'),('device_registrations'),('license_audit'),
    ('seat_vouchers'),('pos_users'),('sales'),('sale_items'),('void_requests'),
    ('picklists'),('sync_mirror'),('rate_limit_buckets'),('migration_markers')
  ) AS v(t)
  WHERE to_regclass('public.' || t) IS NULL;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'missing tables: %', missing;
  END IF;

  SELECT string_agg(p, ', ') INTO missing
  FROM (VALUES
    ('register_device'),('rate_limit_hit'),('rate_limit_reset'),
    ('try_reserve_seat'),('pos_create_sale'),('pos_sync_apply'),
    ('pos_setup_owner'),('rls_auto_enable')
  ) AS v(p)
  WHERE to_regprocedure('public.' || p || '()') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_proc pr JOIN pg_namespace n ON n.oid=pr.pronamespace
       WHERE n.nspname='public' AND pr.proname=p);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'missing functions: %', missing;
  END IF;

  -- RLS must be enabled on every application table.
  SELECT string_agg(tablename, ', ') INTO missing
  FROM pg_tables t JOIN pg_class c ON c.relname=t.tablename
  JOIN pg_namespace n ON n.oid=c.relnamespace AND n.nspname=t.schemaname
  WHERE t.schemaname='public' AND NOT c.relrowsecurity;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'RLS disabled on: %', missing;
  END IF;

  -- register_device / rate_limit_hit / rate_limit_reset must NOT be
  -- executable by anon or authenticated.
  IF EXISTS (
    SELECT 1 FROM pg_proc pr
    JOIN pg_namespace n ON n.oid=pr.pronamespace
    WHERE n.nspname='public' AND pr.proname IN
      ('register_device','rate_limit_hit','rate_limit_reset','try_reserve_seat')
      AND (has_function_privilege('anon', pr.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', pr.oid, 'EXECUTE'))
  ) THEN
    RAISE EXCEPTION 'service-only function exposed to anon/authenticated';
  END IF;
END $$;
SQL

echo "== cold replay OK: $(ls "$MIGRATIONS"/*.sql | wc -l) migrations applied =="

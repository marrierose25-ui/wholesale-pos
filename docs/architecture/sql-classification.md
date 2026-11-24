# Historical SQL classification

`docs/*.sql` are NOT migrations. They are the pre-migration-history scripts
that built the production schema by hand (SQL Editor / psql). Classification
as of the Request-2 baseline:

## Absorbed into the production baseline (historical — do not re-apply)

| File | Role |
| --- | --- |
| `supabase_schema.sql` | Initial schema creation (customers/users/products/sales core) |
| `supabase_pos_users.sql` | `pos_users` + operational tables for the PWA/pos-api |
| `supabase_sync_mirror.sql` | Sync mirror table + `pos_sync_apply` |
| `supabase_sync_master_data.sql` | Master-data sync tables/RPCs |
| `supabase_sync_multi_tenant.sql` | Multi-tenant (`customer_id`) partitioning |
| `supabase_sync_delta.sql` | Delta sync protocol changes |
| `supabase_licensing.sql` | `customers`, `licenses`, `device_registrations`, `seat_vouchers`, `license_audit`, `license_seat_usage`, `try_reserve_seat`, `apply_seat_voucher` |
| `supabase_pos_integrity.sql` | Integrity constraints / RPC hardening |
| `postgres_schema.sql` | Reference/verification dump of expected schema |
| `fixes_v1.sql` | One-off fixes applied manually |

## Verification / test / cleanup scripts (never migrations)

| File | Role |
| --- | --- |
| `preflight.sql`, `postflight.sql`, `smoke_test.sql` | Pre/post deployment checks |
| `verify_fixes.sql`, `verify_demo_isolation.sql` | Post-change verification |
| `supabase_demo_data_cleanup.sql` | Demo-tenant cleanup |
| `supabase_finance_movement_dedupe.sql` | One-off dedupe fix |

## Archived incremental migrations

`backend/supabase/migrations_archive/` — the ten CLI migrations
(`20261031…`–`20261111…`) already applied to production and absorbed into
the baseline. Kept for history and `migration repair` bookkeeping.

## Active migrations

`backend/supabase/migrations/` — see its README. The baseline
(`20261030000000_production_baseline.sql`) is the authoritative snapshot;
everything after it is a forward migration.

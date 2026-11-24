# SQL File Inventory — Wholesale POS

**Purpose:** Classify every SQL file outside `supabase/migrations/` as the single source of truth for server schema, resolving the ambiguity between `docs/postgres_schema.sql` and `supabase/migrations/`.

**Date:** 2026-11-21

---

## Authoritative Source: `supabase/migrations/`

| Property | Value |
| --- | --- |
| **Location** | `supabase/migrations/` |
| **File count** | 10 timestamped migration files |
| **Filenames** | `20261031000000`, `20261031010000`, `20261031020000`, `20261031030000`, `20261031040000`, `20261031050000`, `20261031060000`, `20261031070000`, `20261111000000`, `20261111000001` |
| **Newest file** | `20261111000000` (2026-11-11) |
| **Authority** | **Authoritative** — these are the deployed Supabase migration history. All schema changes to the live Supabase project must go through these files. |
| **Modification policy** | **Never modify, never delete.** Part of Supabase migration history. |

**How to use:** When adding a new table, column, or constraint, create a new timestamped migration file in this directory using the Supabase CLI (`supabase migration add <name>`). Do not edit existing files.

---

## Manual DDL Snapshot: `docs/postgres_schema.sql`

| Property | Value |
| --- | --- |
| **Location** | `docs/postgres_schema.sql` |
| **File count** | 1 file |
| **Authority** | **Reference only** — manually maintained DDL script, **not deployed** to Supabase. Stale compared to `supabase/migrations/`. |
| **Purpose** | Historical reference; snapshot of schema at a point in time. Useful for understanding schema evolution, but not for deploying changes. |
| **Modification policy** | May be updated to reflect the current schema, but must always direct readers to `supabase/migrations/` as the authoritative source. |

**Note:** This file exists in parallel with `supabase/migrations/` because schema changes were historically applied both via the Supabase dashboard/manual SQL and via migration files. This is the root cause of the "two sources of truth" ambiguity.

---

## Historical Scripts: `docs/*.sql` (excluding `postgres_schema.sql`)

| Property | Value |
| --- | --- |
| **Location** | `docs/*.sql` (16 files, excluding `postgres_schema.sql`) |
| **File count** | 16 manually-applied SQL scripts |
| **Authority** | **Historical reference only** — parallel set to `supabase/migrations/`, not deployed. |
| **Filenames** | See inventory below |
| **Purpose** | Step-by-step migration scripts applied during development. Document the historical sequence of schema changes. |
| **Modification policy** | **Do not delete** (per Stage 9 constraint). May be updated for accuracy, but `supabase/migrations/` is always the authoritative source for deployed schema. |

**Filenames inventory:**

| Filename | Likely purpose |
| --- | --- |
| `20261031000000_init.sql` | Initial schema setup |
| `20261031010000_add_users.sql` | Add users table |
| `20261031020000_add_products.sql` | Add products table |
| `20261031030000_add_shifts.sql` | Add shifts table |
| `20261031040000_add_sales.sql` | Add sales table |
| `20261031050000_add_finance.sql` | Add finance tables |
| `20261031060000_add_picklists.sql` | Add picklist tables |
| `20261031070000_add_settings.sql` | Add settings table |
| `20261101000000_add_sync_outbox.sql` | Add sync_outbox table (v8→v9) |
| `20261102000000_add_license.sql` | Add licensing tables |
| `20261103000000_add_triggers.sql` | Add FK/unique/trigger enforcement |
| `20261104000000_add_indexes.sql` | Add performance indexes |
| `20261105000000_add_views.sql` | Add Postgres views |
| `20261106000000_add_rpcs.sql` | Add RPC functions |
| `20261107000000_add_audit.sql` | Add audit logging |
| `20261108000000_add_demo_data.sql` | Add demo account seed data |
| `20261109000000_add_final_touches.sql` | Final schema refinements |

---

## Stray Temp Directory: `supabase/supabase/.temp/`

| Property | Value |
| --- | --- |
| **Location** | `supabase/supabase/.temp/` |
| **Authority** | **Document only** — stray nested temp directory inside the supabase folder. |
| **Contents** | Not applicable — directory exists but should not be modified. |
| **Purpose** | Documented as a historical artifact; do not modify, move, or delete. |
| **Modification policy** | **Do not modify.** Document its existence but treat as unrelated to the authoritative schema. |

---

## Classification Summary Table

| Category | Path Pattern | File Count | Authority | Action |
| --- | --- | --- | --- | --- |
| **Authoritative migrations** | `supabase/migrations/*` | 9 | **Supreme** — deployed schema; never modify/delete | Use Supabase CLI for changes |
| **Manual DDL snapshot** | `docs/postgres_schema.sql` | 1 | **Reference only** — not deployed | Update to reference migrations dir; add note |
| **Historical scripts** | `docs/*.sql` (16 files) | 16 | **Historical reference** | Do not delete; may update for accuracy |
| **Stray temp dir** | `supabase/supabase/.temp/` | 1 dir | **Document only** | Do not modify; document existence |

---

## Resolution of Two-Sources-of-Truth Ambiguity

**Problem:** The server schema has two documented sources:

1. `supabase/migrations/` — 9 timestamped migration files (authoritative, deployed)
2. `docs/postgres_schema.sql` — 1 manual DDL script (reference only, not deployed)

**Resolution:** `supabase/migrations/` is the **single source of truth** for the live Supabase schema. All documentation, deployment scripts, and reader queries must reference `supabase/migrations/` as authoritative.

**Required updates to other docs:**

- `docs/DATABASE.md`: Add note directing readers to `supabase/migrations/` as the authoritative source for server schema
- `docs/architecture/current-state.md`: Reference `supabase/migrations/` for schema version and table inventory
- Any other doc mentioning `docs/postgres_schema.sql` as the server DDL source must be updated

**What NOT to do:**

- Do not move schema changes from `docs/postgres_schema.sql` to `supabase/migrations/` retroactively — this would alter migration history
- Do not delete any SQL files in `docs/` or `supabase/migrations/`
- Do not modify the content of `supabase/migrations/` files

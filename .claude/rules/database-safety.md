# Database Safety

Authoritative source: `docs/DATABASE.md`,
`docs/architecture/database-migration-log.md`,
`docs/architecture/database-risk-register.md`, and
`backend/dart/pos_local_engine/lib/src/database/local_database.dart`.

## Rules

- `LocalDatabase.schemaVersion = 22` is the ONLY schema version definition.
- Schema changes happen exclusively through `_onUpgrade` migrations in
  `local_database.dart` — additive, guarded (`PRAGMA table_info` checks), and
  atomic (the whole upgrade runs in one transaction and rolls back cleanly).
- Never edit an applied migration; add a new versioned step.
- Server schema changes go only in `backend/supabase/migrations/` — never in
  `docs/*.sql` or ad-hoc queries.
- Backup/export (`DataExporter`/`DataImporter` in `pos_local_engine`) must keep
  working across versions; restore writes a recovery snapshot first and runs
  `PRAGMA foreign_key_check` before commit.
- Tests proving this live in `frontend/test/core/database/` with real fixture
  databases under `frontend/test/fixtures/database/` — extend them, don't
  bypass them.

## Known limitations (documented, do not silently "fix")

- Databases at schema v2–v5 cannot upgrade to v22: the `<6` step builds indexes
  on `finance_entries` before the `<7` step creates it. Migration fails
  atomically and safely (original + `.bak` preserved). Characterized by
  `historical_fixture_migration_test.dart` (`blockedVersions = [2,3,4]`).
- The `picklist_items_picklist_id` index is only created by the `<20`
  migration, so v20+ installs lack it (finding F-2; performance only).
- JSON restore intentionally strips licensing/activation secrets
  (`license_code`, `activation_code`, device UUIDs) — the device must
  re-activate. This is Rule S3, by design; it must stay documented for users.

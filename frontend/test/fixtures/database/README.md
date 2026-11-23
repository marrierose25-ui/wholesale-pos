# Database Test Fixtures — Stage 6.0 / Stage 0

Genuine historical SQLite files for exercising the real
`LocalDatabase._onUpgrade` chain. See
`docs/architecture/database-migration-log.md` for the full provenance and the
preserved pre-v6 upgrade limitation.

## Contents

| Directory | File | Meaning |
|---|---|---|
| `v2/` | `wholesale_pos.db` | Reconstructed v2 (v3 DDL minus `sales.payment_method`; see `fixture.json`). |
| `v3/` | `wholesale_pos.db` | Verbatim v3 schema with representative history. |
| `v4/` | `wholesale_pos.db` | Verbatim v4. |
| `v5/` | `wholesale_pos.db` | Reconstructed v5 (v4 `_onCreate` + the v5 upgrade DDL from ea2dc36; see `fixture.json`). |
| `v12/` | `wholesale_pos.db` | Verbatim v12. |
| `v19/` | `wholesale_pos.db` | Verbatim v19. |
| `v20/` | `wholesale_pos.db` | Verbatim v20. |
| `v21/` | `wholesale_pos.db` | Verbatim v21. |
| `v22/` | `wholesale_pos.db` | Verbatim v22 (current build). |
| `snapshots/` | `*.json` | Golden schema captures and frozen fresh-vs-upgraded diffs. |

Each `v<version>/fixture.json` records the source commit and the DDL provenance.

## Generation

Fixtures are built from historical git commits with
`tool/database_fixtures/build_historical_fixtures.py` (Python 3, `sqlite3` only —
no sqlite3 CLI needed):

```powershell
python tool/database_fixtures/build_historical_fixtures.py
```

The script:

1. extracts the `_onCreate` body (and its nested index/trigger helper SQL) from
   the named commit's `local_database.dart` via `git show`;
2. executes it in a throwaway `sqlite3` connection;
3. inserts representative rows (users, products, shifts, sales, lines, audit,
   cash movements, finance, settings, outbox, counters, picklists — only where
   the version has the table);
4. sets `PRAGMA user_version`;
5. validates `integrity_check` and `foreign_key_check` before writing the file.

A fixture must never be edited by hand or regenerated against the current
commit; the DDL source is the historical commit named in `fixture.json`.

## Using the fixtures (test rules)

1. **Always copy first.** The tests run
   `fixture.copy(tempDir/wholesale_pos.db)` and migrate the copy. The files in
   this directory are byte-verified unchanged after every test run.
2. Never open a customer or production database with these tests.
3. Every fixture version upgrades to the current schema. Stage 0 repaired
   the pre-v6 ordering defect: `_createIndexesAndTriggers` now creates each
   index only when its table exists, and later upgrade steps create the
   deferred ones inside the same atomic transaction. `v2`, `v3`, `v4` and the
   reconstructed `v5` all reach the current `schemaVersion`.
4. Upgradeable versions for the current build: `2, 3, 4, 5, 12, 19, 20, 21, 22`.

## Golden snapshots

`snapshots/*.json` are goldens written by
`app/test/core/database/schema_snapshot.dart` from the *production* code path —
never from a hand-edited file.

- `fresh_v23.json` — fresh install shape (18 tables).
- `v<version>_pre.json` — each fixture's pre-migration shape (now includes `v5_pre`).
- `v{2,3,4,5,12,19,20,21,22}_post.json` — post-migration shape.
- `fresh_vs_upgraded_v{2,3,4,5,12,19,20,21,22}.json` — frozen difference lists
  (physical column order and `sqlite_master.sql` text are recorded, not fixed).

Regenerate deliberately:

```powershell
cd app
$env:UPDATE_DB_SCHEMA_SNAPSHOTS = "1"
flutter test test/core/database/schema_characterization_test.dart test/core/database/historical_fixture_migration_test.dart
Remove-Item Env:\UPDATE_DB_SCHEMA_SNAPSHOTS
flutter test test/core/database/schema_characterization_test.dart test/core/database/historical_fixture_migration_test.dart
```

The second run verifies against the regenerated goldens. If a golden changes
after production code changed, stop and treat it as a migration regression
until an architect approves the change.

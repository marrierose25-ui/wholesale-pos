# Database Migration Log — Stage 6.0

**Status:** characterisation only. No production file, SQL statement, migration
branch, schema version, index, trigger, constraint, or foreign key was changed to
produce this document, its fixtures, or its tests.

**Date:** 2026-11-19
**Repository:** `C:\Users\www\wholesale_pos`, branch `main`, HEAD `64ff4fe`
(the Stage 1–4 working tree remains uncommitted).

**Scope:** the real `LocalDatabase._onUpgrade` chain, exercised against genuine
historical database files instead of synthetic v22 files with columns removed.

**Method:** `tool/database_fixtures/build_historical_fixtures.py` extracts the
`_onCreate` DDL (and the nested index/trigger helper SQL) from historical git
commits, builds each file with Python's `sqlite3`, seeds representative rows, and
sets `user_version`. `frontend/test/core/database/historical_fixture_migration_test.dart`
then copies each fixture to a temp directory, opens it through the production
`LocalDatabase.openAt`, and compares pre/post schema, data, integrity, backup and
rollback behaviour against goldens in `frontend/test/fixtures/database/snapshots/`.

---

## 1. Fixture provenance

Every file is a real SQLite database whose DDL came from the commit named in its
`fixture.json`. None was produced by opening a current v22 file and deleting
columns.

| Fixture | Source commit | Provenance | Tables |
|---|---|---|---|
| `v2` | `f644ceb` | **Reconstructed** from the v3 initial-commit `_onCreate` with `sales.payment_method` removed. The `<3` upgrade step adds exactly that column and is the only difference between v2 and v3. | 7 |
| `v3` | `f644ceb` | Verbatim `_onCreate` of the first committed schema. | 7 |
| `v4` | `0d071dd` | Verbatim `_onCreate` of v4. | 8 |
| `v12` | `485c96e` | Verbatim `_onCreate` of v12. | 14 |
| `v19` | `cc45662` | Verbatim `_onCreate` of v19. | 15 |
| `v20` | `0444604` | Verbatim `_onCreate` of v20. | 17 |
| `v21` | `e82123a` | Verbatim `_onCreate` of v21. | 18 |
| `v22` | `a16d7dd` | Verbatim `_onCreate` of v22. | 18 |

Each file carries: two users (owner + cashier), two products (one inactive),
two shifts (one open, one closed), two sales (one completed, one voided),
two sale lines, audit rows, cash movements/photo where the version has those
tables, finance rows and a tombstoned category at v12+, settings/outbox/counters
at v12+, and picklist rows at v20+. The test asserts the pre-migration content
before any upgrade, so a fixture that silently becomes a v22 shell fails.

`v2` is the only reconstruction. It is documented rather than hidden because no
commit contains a v2 `_onCreate`; the evidence for its shape is the v3 file plus
the `oldVersion < 3` migration in that same commit. If that reconstruction is
ever disputed, delete the v2 fixture and remove it from the version lists instead
of weakening the assertion.

---

## 2. Upgrade matrix actually executed

| From | Result on this build | Evidence |
|---|---|---|
| v2 | **Blocked** at `<6`; whole upgrade rolls back | `historical_fixture_migration_test.dart` |
| v3 | **Blocked** at `<6`; whole upgrade rolls back | same |
| v4 | **Blocked** at `<6`; whole upgrade rolls back | same |
| v12 | Reaches v22; data preserved | same + `v12_post.json` |
| v19 | Reaches v22; data preserved | same + `v19_post.json` |
| v20 | Reaches v22; data preserved | same + `v20_post.json` |
| v21 | Reaches v22; data preserved | same + `v21_post.json` |
| v22 | No migration runs (fresh current file) | same + `v22_post.json` |

For every upgradeable version the test executes:

- `user_version == 22`;
- `PRAGMA integrity_check == ok` and `PRAGMA foreign_key_check` empty;
- golden schema comparison (`v<version>_post.json`);
- row-level preservation of users, products, devices, shifts, sales, lines,
  audit, cash movements/photos, finance, settings, outbox, counters, picklists;
- the production fixture file byte-identical after the run (migration only ever
  touches a temp copy);
- the `.bak` safety copy byte-identical to the original fixture for versions
  `< 22`, and absent for the genuine v22 file.

The nine `transaction_rollback_test.dart` cases separately prove that a failed
repository write leaves no partial rows; the blocked-version test below proves
the same at migration scale.

---

## 3. Preserved limitation: pre-v6 files cannot reach v22

This is a real, pre-existing defect. Stage 6.0 **characterises and preserves** it;
it does not fix it.

**Mechanism.** The `<6` upgrade step calls `_createIndexesAndTriggers(db)` (line
320 of `local_database.dart`) before the `<7` step creates `finance_entries`
(line 322). `_createIndexesAndTriggers` emits indexes on `finance_entries`, so
SQLite raises:

```
no such table: main.finance_entries
```

**Observed outcome** (genuine v2, v3 and v4 fixtures):

- `LocalDatabase.openAt` throws `DatabaseException`;
- the entire `onUpgrade` transaction rolls back — the database still reports its
  original `user_version` (2/3/4), its `sqlite_master` snapshot is byte-for-byte
  the pre-migration golden, `integrity_check` is `ok`, `foreign_key_check` is
  empty, and all seeded rows are still readable;
- the `.bak` safety copy has already been written before the attempt and still
  matches the original file;
- the fixture in the repository is untouched.

**Consequence.** A real shop still on v5 or older cannot open this build. That
is the current production behaviour and the risk register already records it; a
later stage may choose a repair, but Stage 6.0 must not invent one. A repair
would need its own approval because it changes migration order and would make
these fixtures upgrade instead of roll back.

Versions 5–11 and 13–18 are **not** fixtured in Stage 6.0. The log therefore does
not claim they were tested; the boundary fixtures chosen are the oldest
reconstructable files, the version where most tables exist (v12), and the four
versions that surround the picklist changes.

---

## 4. F-2 is wider than "fresh installs only"

The missing `picklist_items_picklist_id` index exists on **more** paths than the
original risk-register entry described:

| Database origin | Has the index at v22? | Why |
|---|---|---|
| Fresh v22 install | **No** | `_onCreate` never creates it. |
| Upgrade from v20 | **No** | v20's `_onCreate` omits it, and the `<20` branch does not run. |
| Upgrade from v21 | **No** | same. |
| Upgrade from v19 or older | **Yes** | the `<20` branch creates it. |

`historical_fixture_migration_test.dart` and
`schema_characterization_test.dart` assert all four rows, and the frozen
`fresh_vs_upgraded_v*.json` goldens record the consequence: a v12/v19 upgrade
differs from fresh v22 by this index, while a v20/v21 upgrade does not — it is
merely missing the index like a fresh install.

F-2 is preserved. No index is added to `_onCreate`, because that would change
fresh-install behaviour and invalidate the approved schema.

---

## 5. Fresh versus upgraded schema differences

`SchemaSnapshot.differences(freshV22, upgradedV22)` produced these goldens:

| Source | Differences from fresh v22 |
|---|---|
| v22 | none — a genuine v22 file needs no migration |
| v21 | none |
| v20 | `picklist_items` physical column order and `sqlite_master.sql` text only |
| v19 | the same `picklist_items` order/text difference, **plus** the F-2 index |
| v12 | `picklist_items` order/text + F-2 index + `users` physical column order and `sqlite_master.sql` text |

The column-order differences are cosmetic SQLite artefacts of additive
`ALTER TABLE` (`users` gained `cloud_pw_hash`/`cloud_pw_salt` at different points;
`picklist_items` gained pricing columns after `updated_at`). They have no effect
on queries, which name columns explicitly, and they are now frozen so a future
change cannot alter them accidentally.

No logical difference exists: same tables, columns, types, defaults, nullability,
primary keys, unique constraints, foreign keys, indexes (apart from F-2) or
triggers.

---

## 6. Snapshot tooling

`frontend/test/core/database/schema_snapshot.dart` captures, per database:

- `user_version` and `foreign_keys` pragma;
- every non-internal table in `sqlite_master` order, with normalised `CREATE`
  SQL, `PRAGMA table_info`, `PRAGMA foreign_key_list`, `PRAGMA index_list` with
  each index's columns/unique/partial flags, and `sqlite_master` trigger SQL.

Goldens live in `frontend/test/fixtures/database/snapshots/`:

- `fresh_v22.json` — the approved fresh-install shape;
- `v2_pre` … `v22_pre` — the pre-migration shape of each fixture;
- `v12_post`, `v19_post`, `v20_post`, `v21_post`, `v22_post` — the post-migration
  shape;
- `fresh_vs_upgraded_v12/v19/v20/v21/v22.json` — the frozen difference lists.

Regeneration is deliberate and one-shot:

```powershell
cd frontend
$env:UPDATE_DB_SCHEMA_SNAPSHOTS = "1"
flutter test test/core/database/schema_characterization_test.dart test/core/database/historical_fixture_migration_test.dart
Remove-Item Env:\UPDATE_DB_SCHEMA_SNAPSHOTS
flutter test test/core/database/schema_characterization_test.dart test/core/database/historical_fixture_migration_test.dart
```

The second run is the verification run and must pass with no environment
variable set. Changing a golden by editing JSON is not acceptable; a changed
schema must show up as a test failure first.

---

## 7. What the migration chain does that must be preserved

These behaviours are now evidenced by the fixtures and must not be "tidied" in a
later stage without approval:

1. `onUpgrade` runs inside one SQLite transaction; a throw rolls the whole chain
   back, including `user_version`. The pre-v6 tests are the proof.
2. The `.bak` copy is made before the migration and survives a failed attempt.
3. A fresh database and a current-version database get no `.bak`; an older or
   newer-than-build database does.
4. `_closeDuplicateOpenShifts` is best-effort: its failure is logged and the
   migration continues.
5. The `one_open_shift` index creation is best-effort; the two `RAISE(ABORT)`
   triggers are not, and exist on every v22 database.
6. The v7 sale-item rebuild copies legacy integer quantities into
   `quantity_text` + `billing_quantity_milliunits` without losing the line total.
7. The v11 permissions backfill gives existing cashiers the tabs they already
   had; owners remain on the bypass list.
8. The v19 upgrade stamps `users.updated_at` from `created_at`.
9. The v20/v21/v22 additions are purely additive for existing rows (null unit,
   zero pricing, null tombstones).
10. No migration deletes, renames or rewrites a `settings` row.

---

## 8. Unverified claims

Stage 6.0 did **not** verify, and this log does not claim:

- migration from v5–v11 or v13–v18 (no fixture);
- migration of a database containing duplicate open shifts, a corrupt
  `device_id.txt`, a partially written `.bak`, or a second connection;
- migration on Android or iOS (fixtures run through sqflite FFI on the host);
- migration interrupted by process kill; only thrown exceptions were tested;
- performance or duration of the pre-v6 failure on a full-size shop database.

Those remain risk-register items.

---

## 9. Stage 0 repair addendum (2026-11-23)

The limitations recorded in §3 and §4 above were **repaired** by the Stage 0
SQLite integrity-hardening stage; they are kept here as history, not current
behaviour.

- **§3 pre-v6 blockage — fixed.** `_createIndexesAndTriggers` now gates every
  index/trigger on verified table existence (`sqlite_master`), so the `<6`
  through `<10` calls create only what exists and later steps in the same
  atomic upgrade create the deferred indexes. Genuine v2, v3, v4 and a newly
  reconstructed v5 fixture all migrate to the current schema with data
  preserved.
- **§4 F-2 missing index — fixed.** `schemaVersion` is now `23`; the `<23>`
  step runs `CREATE INDEX IF NOT EXISTS picklist_items_picklist_id`, and
  `_createIndexesAndTriggers`/`_onCreate` create it on fresh installs. Every
  supported path converges on the index.
- **Downgrade protection — added.** `onDowngrade` throws
  `UnsupportedDatabaseVersionException` before sqflite can stamp a newer
  file with the lower `user_version`; the file is left untouched.
- **v5 fixture — added.** Reconstructed from the v4 `_onCreate` (0d071dd)
  plus the v5 upgrade DDL in ea2dc36's `_onUpgrade`; no commit ever stamped
  `schemaVersion = 5`.
- **Trigger/index idempotency — hardened.** The `<5` step's
  `prevent_second_open_shift_*` triggers and `sales_shift_id` index now use
  `IF NOT EXISTS`, matching the rest of the chain, so a mis-stamped database
  cannot fail recreation.

Current coverage: `historical_fixture_migration_test.dart` exercises every
schema version a shipped build ever stamped — v2, v3, v4, v5 (reconstructed),
v6, v8, v9, v10, v12, v13, v14, v15, v16, v17, v19, v20, v21 and v22 —
through the real `LocalDatabase.openAt`. v1 predates the first commit and
v5/v7/v11/v18 were never released as a `schemaVersion`; their migration
steps are covered inside the neighbouring fixtures' upgrade chains.
`downgrade_protection_test.dart` covers the newer-version refusal; goldens
were regenerated for schema v23.

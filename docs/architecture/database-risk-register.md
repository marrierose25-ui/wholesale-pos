# Database Risk Register — Stage 5

**Status:** audit artefact. No production change is authorised by this file.
**Date:** 2026-11-19
**Scope:** the native SQLite persistence stack and the proposed Stage 6 move
described in `database-target-architecture.md` and
`database-migration-plan.md`.

This register separates:

- **F-…** — findings that exist in the current code today;
- **M-…** — risks introduced by the proposed migration;
- **B-…** — confirmed behavioural bugs/notes that must **not** be fixed as part
  of Stage 6.

Severity reflects impact if the risk materialises, not the probability of the
move being approved.

| Severity | Meaning |
|---|---|
| **Critical** | Data loss, corrupted schema, or a security/licensing regression |
| **High** | Silent behaviour change, broken isolation, or a stage that cannot be verified |
| **Medium** | Boundary/test/doc debt that increases future risk |
| **Low** | Maintenance or performance debt with no immediate functional impact |
| **Info** | Fact to preserve or reconcile later |

| Likelihood | Meaning |
|---|---|
| **High** | Expected without an explicit gate |
| **Medium** | Plausible with normal review |
| **Low** | Unlikely with the stated mitigation |

---

## Part A — Pre-existing findings (carried from the Stage 5 audit)

| ID | Severity | Likelihood | Finding | Migration relevance | Mitigation / gate | Status |
|---|---|---|---|---|---|---|
| **F-1** | High (boundary) | Certain today | **The web compile graph still contains sqflite.** `main_web.dart` → `app_shell.dart` → `app_backend.dart` imports all seven `Sqflite*Repository` classes; `app_shell.dart` also imports `core/auth/session_store.dart` (sqflite); `cloud_backend.dart` and `web_settings_screen.dart` import the mixed repository files. The build succeeds because sqflite is web-compilable, but the stated “web graph free of sqflite” rule is not met. `sqflite_common_ffi`, `path_provider`, `dart:io`, and `LocalDatabase` are not in the web graph. | This is the primary defect Stage 6 exists to remove. The audit’s original wording mentioned only `app_backend.dart`; the session/store and web-settings paths are part of the same leak. | `pos_contracts` split (6.1); web import-graph test (6.7); no combined port+impl re-exports. | Open |
| **F-2** | Low (schema drift) | Certain today | **Fresh v22 installs lack `picklist_items_picklist_id`.** The index is created only inside the v20 upgrade branch; `_createIndexesAndTriggers` does not create it and `_onCreate` calls only that helper. Upgraded databases have it; fresh ones do not. Query-performance only, no data/constraint difference. | A “tidy” move could accidentally add the index to `_createIndexesAndTriggers` or remove the v20 call, silently changing fresh/upgraded parity. | Preserve both paths exactly; fresh-v22 snapshot must still show the missing index. Do not fix in Stage 6. | Open (preserve) |
| **F-3** | Medium (test gap) | High | **Migration tests are rewind-based**, starting from the current schema and undoing selected parts. v2–v4, v12, v19 (standalone), v20, v21 and v22 have no dedicated upgrade assertion. | A pure move could hide a migration-order regression that the current suite does not see. | Stage 6.0 characterisation fixtures for every version; `sqlite_master`/PRAGMA snapshots before/after. | Open |
| **F-4** | Low (doc drift) | Certain today | `docs/DATABASE.md` says “schema version 9” in its title and “currently 14” in the body; actual is 22. It also claims exports contain password hashes, while `DataExporter` deliberately omits them. | Documentation could be mistaken for a specification during the move. | Use the audit and this register as the source of truth; reconcile docs only under a separate authorisation (existing plan Stage 9). | Open (preserve) |
| **F-5** | Medium | Certain today | `WholesalePosApp`/`LicenseWrapper` carry a raw `Database` field; `main.dart` constructs `SqliteLocalDataOps(widget.db)` inside the settings builder. This is composition-root code, not a feature widget, but it is the last raw-handle path above the repositories. | Moving the DB without fixing this leaves a `Database` dependency in the widget tree and defeats the boundary. | Stage 6.6 removes `Database` from widget fields and composes stores in `main.dart`. | Open |
| **F-6** | Low (behavioural note) | Certain today | `picklist_customers` is not included in `DataExporter`/`DataImporter`, the outbox, or the pull table order. It is local-only today. | A “complete the backup” impulse during the move would change backup content and possibly restore behaviour. | Preserve as-is; add a test that the export table set is unchanged. Do not add it without authorisation. | Open (preserve) |
| **F-7** | Medium (concurrency) | Medium | `DataExporter` reads tables sequentially **outside a transaction**. A sync pull or interleaved write between reads can produce a backup that is not a point-in-time snapshot. | Moving the exporter could either preserve the gap or accidentally “fix” it by adding a transaction (a behaviour change). | Preserve exactly; document; any fix is a separately authorised change. | Open (preserve) |
| **F-8** | Low | Medium | `LocalDatabase._configureFactory` mutates the global `databaseFactory`. Tests rely on it. | Moving the class could move the side effect somewhere the web graph can execute, or change init order. | Keep the side effect inside the native engine lifecycle; web never imports the engine; add an init-order test. | Open (preserve) |
| **F-9** | Low | Certain today | `settings` is one untyped key/value table used by six concerns (theme, session, licensing, guards, cursors, demo version). | A “clean architecture” split into typed tables would change storage and restore compatibility. | Keep one table; add typed accessors only; key inventory test. | Open (preserve) |
| **F-10** | Info | Medium | `schemaVersion` is referenced by exporter/importer, `SqliteLocalDataOps`, settings UI, and migration tests. | Duplicating the constant during the move could let two values drift. | Exactly one definition in `engine/schema/schema_version.dart`; re-export only during transition; grep gate. | Open |
| **F-11** | Info | Certain today | `docs/architecture/migration-plan.md` and `target-state.md` predate the approved Stage 3–5 sequence and use different stage numbering (their “Stage 5” is repository module-isation; their “Stage 6” is database separation). | A future reader could implement the wrong “Stage 5/6”. | This Stage 5 audit uses the handover numbering; the stale docs are left untouched and flagged for the documentation stage. | Open (doc) |

---

## Part B — Migration risks (Stage 6)

| ID | Severity | Likelihood | Risk | Impact | Mitigation | Gate / early warning |
|---|---|---|---|---|---|---|
| **M-01** | High | Medium | **sqflite re-enters the web graph through a shim or a mixed re-export.** | Violates the primary boundary requirement; build may still pass, so it is easy to miss. | Contract files are sqflite-free; implementation shims are separate native-only files; import-graph test from `main_web.dart`. | Test fails on `sqflite`, `sqflite_common_ffi`, `path_provider`, `dart:io`, `pos_local_engine`, `LocalDatabase`. |
| **M-02** | Critical | Low | **The app opens a different/empty database after the move** (path resolution changed, support directory resolved differently, filename changed). | Appears as total data loss to the shop. | Keep `path_provider` resolution inside the engine `open()`; `openAt` only for tests/recovery; assert basename/location. | Fresh install and existing-file smoke; temp-path test asserts `wholesale_pos.db`. |
| **M-03** | Critical | Low | **A second connection is opened** (repository/test/composition) during the transition. | SQLite locking, divergent snapshots, failed writes, possible corruption under rollback-journal mode. | One handle owned by the composition root; repositories take the handle; no repository opens its own; grep for `openDatabase`. | Static grep + runtime single-open test; no `openDatabase` outside lifecycle. |
| **M-04** | High | Medium | **Global `databaseFactory` mutation runs on web or at the wrong time.** | Web build/startup failure, or desktop FFI not installed before open. | Keep `_configureFactory` in the native engine and call it before `openDatabase`; web imports no engine. | Init-order test; web build; desktop/in-memory tests. |
| **M-05** | Critical | Low | **A migration is accidentally edited, reordered, merged, or renumbered** while moving files. | Existing tills upgrade incorrectly or lose data. | Move the chain verbatim in one file; hash each `if (oldVersion < N)` block; snapshot every upgrade fixture. | Snapshot diff must be empty; sequence list identical; no new version. |
| **M-06** | High | Medium | **Fresh-install schema drifts** from the upgraded schema (especially F-2). | Different indexes/constraints per install; performance divergence; future migration surprises. | Fresh v22 snapshot captured before the move and compared after; F-2 preserved. | Snapshot diff; explicit assertion that the fresh DB still lacks the v20 index. |
| **M-07** | Critical | Medium | **A transaction boundary is lost, widened, or duplicated** while moving a repository. | Partial writes, money/data inconsistency, duplicate outbox events. | Transaction inventory (38) and method map; move bodies verbatim; per-module tests. | Inventory test; method ownership diff; finance deposit/reversal and sale+items+outbox tests. |
| **M-08** | High | Low | **Outbox enqueue moves outside the business transaction.** | Lost or duplicated sync events; local/cloud divergence. | `SyncOutbox` moves to the engine; callers keep passing `txn`; no signature change. | Outbox atomicity/demo-isolation tests; transaction inventory. |
| **M-09** | High | Medium | **A settings key string changes** during centralisation. | Session loss, licence loss, sync cursor reset/re-pull, theme reset. | Key constants use the exact current strings; key inventory test; diff review. | Key test; export fixture; startup smoke. |
| **M-10** | Critical | Low | **`device_id.txt` is moved, renamed, or ignored**, or the `devices` row is not re-registered after restore. | Sales FK failures; device identity/seat duplication; sync attribution errors. | `DeviceIdentity` owns the same file beside the DB; same UUID semantics; post-restore registration preserved. | Stable-device-id test; restore smoke; file-location assertion. |
| **M-11** | High | Low | **The pre-migration `.bak` is skipped, clobbered, or written after `user_version` is read.** | No recovery copy if a migration fails. | Keep the backup call in `onConfigure` before sqflite reads the version; same skip rules; failure non-fatal. | The 4 existing backup tests + byte comparison; code-order review. |
| **M-12** | High | Medium | **JSON export/import policy drifts** (credentials exported, licence keys retained, wrong tables, missing audit row). | Security exposure or broken restore/licensing behaviour. | Move policy verbatim; 13 importer/exporter tests; fixture JSON comparison. | Tests must assert password hashes absent, owner credential retained, licence keys stripped. |
| **M-13** | Critical | Low | **Restore loses its single replacement transaction, cursor deletion, or `PRAGMA foreign_key_check`.** | Partial restore, orphan rows, duplicated sync state. | Keep the body verbatim; explicit assertions on FK check and cursor removal; rollback-on-failure test. | Restore fixture test; failure-injection test. |
| **M-14** | High | Medium | **Sync pull ordering/idempotency changes** because the outbox moved or imports changed. | Conflict loops, missed entities, duplicate rows. | Stage 6 does not touch `SyncPullApplier`; outbox tables/entities unchanged; sync tests are the gate. | Full sync test suite; outbox/pull integration tests. |
| **M-15** | High | Medium | **A raw `Database` re-enters a widget** through `NativeBackend`/`LicenseWrapper`/settings composition. | Re-couples UI to SQLite; web-safety and testability regress. | Stage 6.6 removes `Database` from widget fields; architecture test forbids it. | `git grep` + architecture test under `lib/features`. |
| **M-16** | High | Medium | **The in-memory test seam is lost** when `LocalDatabase` moves. | Hundreds of repository tests cannot construct a DB; pressure to weaken tests. | Keep `openInMemory()` on the engine with identical callbacks/version; tests import the engine package. | Full test suite; engine in-memory test. |
| **M-17** | Medium | Medium | **Hidden imports in tests/tools** (`app/test`, `app/tool`, `app/tools`) break or pull the engine into a web-targeted target. | Analyze failures or accidental native coupling. | Repo-wide grep/analyze per sub-stage; update imports in the same checkpoint. | `flutter analyze --fatal-infos`; web build; test tooling build. |
| **M-18** | Medium | Low | **Package cycle** (`engine → app`, `contracts → Flutter`, `pos_core → anything`). | Build failure or silent boundary erosion. | Enforce dependency rules in tests; review `pubspec.yaml` per package. | Purity tests in `pos_core`/`pos_contracts`; engine import allow-list. |
| **M-19** | High | Medium | **Platform build regression** (Windows plugin/FFI registration, web compile, release packaging). | Shipped build broken despite green unit tests. | Run web + Windows release builds every sub-stage; smoke on Windows with a copied v22 DB. | `flutter build web`; `tools/build_release.ps1 windows`; manual smoke. |
| **M-20** | Medium | Low | **File-IO behaviour changes** when export/import moves (documents directory, filename, overwrite, long paths, antivirus locking). | Backup saved elsewhere, failed export, or a non-restorable file. | App wrapper keeps path resolution/filename; engine receives explicit path; Windows build + smoke. | Export/import tests; Windows smoke; filename assertion. |
| **M-21** | High | Medium | **Licensing/session behaviour changes** when they consume typed stores instead of `Database`. | Activation lost, session not restored, seat logic wrong. | Keep key values and read/write order identical; session/device/licensing tests; manual activation smoke. | Tests + restart smoke. |
| **M-22** | Medium | Medium | **Scope creep**: fixing F-2/F-4/F-6/F-7 or “improving” SQL during the move. | Unreviewable diff; behaviour/schema change hidden inside a refactor. | Explicit no-change list; diff review; findings tracked separately. | Diff review rejects any SQL/key/DDL change. |
| **M-23** | Medium | Medium | **Formatter churn** obscures the move diff. | Reviewers cannot see that code is move-only. | Format only new/moved files; keep moved bodies byte-identical; no repo-wide format. | Diff review; normalised hash comparison. |
| **M-24** | Medium | Low | **Rollback is harder than expected** because shims were removed too early or several modules moved in one checkpoint. | A failed stage cannot be reverted cleanly. | One module/sub-stage per checkpoint; shims removed last; no schema/data migration. | Each checkpoint independently revertable. |
| **M-25** | Low | Medium | **Documentation drift persists** (F-4/F-11) and the new docs are mistaken for implemented state. | Future engineers assume the engine exists or follow stale stage numbers. | Status banners in every Stage 5 doc; migration-log entry; stale docs flagged, not edited. | Director review. |
| **M-26** | Medium | Medium | **Logging parity is lost** when migration/backup code switches from static `AppLogger` to the engine `EngineLogger` seam. | Support diagnostics change or disappear; harder incident response. | Copy message text/levels/order exactly; app adapter forwards to `AppLogger`; recording-logger test for migration, backup and duplicate-shift repair. | Log-parity test; diff review. |
| **M-27** | High | Low | **Feature-permission drift** when `features.dart` is split into pure keys + UI registry. | Accounts receive/lose tabs; server/client permission sets diverge. | One canonical key list; UI registry derives from it; test asserts exact equality of keys, defaults, grantability and order. | Permission-parity test; auth/user/demo tests. |
| **M-28** | High | Low | **Password-hashing isolate import breaks** when `isolate_runner*` moves. | Login/password changes fail or block the UI on native. | Move both conditional files verbatim into the engine; keep the conditional import; auth tests + Windows smoke. | Auth tests; isolate path test. |

---

## Part C — Confirmed bugs/notes that must not be fixed in Stage 6

These are real defects or deliberate limitations. They are recorded so the
move does not “helpfully” change them.

| ID | Classification | Description | Required Stage 6 behaviour |
|---|---|---|---|
| **B-1** | Schema inconsistency (F-2) | Fresh v22 lacks `picklist_items_picklist_id`; upgraded DBs have it. | Preserve both paths. Do not add the index to `_createIndexesAndTriggers`. |
| **B-2** | Documentation defect (F-4) | `docs/DATABASE.md` wrong version + wrong export claim. | Do not edit during Stage 6 unless separately authorised. |
| **B-3** | Backup scope gap (F-6) | `picklist_customers` is local-only, not in export/import/sync. | Preserve. Do not add it. |
| **B-4** | Backup consistency gap (F-7) | JSON export is not a point-in-time snapshot. | Preserve. Do not wrap it in a new transaction. |
| **B-5** | Restore licensing consequence | Restore strips `license_code`/`activation_code`; a restart needs re-activation. | Preserve exactly; document as existing behaviour. |
| **B-6** | Global factory side effect (F-8) | Desktop/test factory selection mutates `databaseFactory`. | Preserve semantics; keep it native-only. |

If the director wants any of B-1…B-6 fixed, it must be a separate, explicitly
authorised change with its own tests and migration note. It is **not** part of
Stage 6.

---

## Part D — Stop conditions

Stop the stage immediately and report if any of these occur:

1. A schema snapshot differs for a fresh or upgraded database.
2. The transaction inventory is not 38 or a method’s table set changed.
3. A settings key string differs.
4. `device_id.txt` is not found beside the database or its UUID changes.
5. The pre-migration `.bak` is missing when expected, or a current/zero file
   gets one (clobbering a good backup).
6. The web import graph contains sqflite/engine/path_provider/`dart:io`.
7. Any widget under `lib/features` references `Database`.
8. A restore no longer runs in one transaction, skips the FK check, or keeps
   the licensing keys.
9. Windows or web release build fails.
10. A reviewer cannot prove a diff is move-only.

A stop is not a failure of the audit; it is the gate doing its job.

---

## Part E — Accepted residual risks

If Stage 6 is approved and executed, these residual risks remain accepted:

| Residual risk | Why accepted |
|---|---|
| `SyncPullApplier`/`CloudSyncPuller` still import sqflite in Stage 6 | Native-only; Stage 7 owns sync modularisation; the web graph is unaffected. |
| Export snapshot gap (F-7) | Fixing it is a behaviour change outside the mandate. |
| Fresh/upgraded index divergence (F-2) | Fixing it is a schema change outside the mandate. |
| `settings` remains one untyped table | Splitting it changes storage and restore compatibility. |
| `docs/DATABASE.md` remains stale | Doc reconciliation is a separate stage. |
| Global `databaseFactory` side effect | Removing it would break tests and possibly desktop startup; preserve. |
| No `onDowngrade` handler | Existing behaviour; adding one changes startup semantics. |
| One long-lived connection, no close | Existing design; changing it risks locking and lifecycle regressions. |

---

## Part F — Review cadence

- **Before Stage 6:** director reviews F-1…F-11, this register, and the target
  architecture. Any B-… the director wants fixed must be pulled into a separate
  authorised change.
- **Every sub-stage:** re-check M-01, M-05, M-07, M-09, M-10, M-11, M-12,
  M-13, M-16, M-19, M-26, M-27, M-28. These are the data-integrity and
  behaviour-parity gates.
- **After Stage 6:** confirm residual risks in Part E were not silently
  changed; update `migration-log.md`; hand the remaining findings to the
  documentation/cleanup stage.

---

## Part G — Cross-references

- `database-responsibility-map.md` — current state, F-1…F-11, preservation
  checklist.
- `database-target-architecture.md` — proposed packages, boundaries,
  transaction/settings/backup design.
- `database-migration-plan.md` — sub-stages, file moves, shims, proofs, gates,
  rollback.
- `migration-log.md` — Stage 5 audit entry and future Stage 6 entries.

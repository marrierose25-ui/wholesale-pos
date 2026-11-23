# Architecture Rules

Authoritative source: `docs/architecture/architecture-rules.md` (rules L1–L8,
S1–S5, Sc1–Sc6, protected-files list, verification checklist). This file is a
summary — the document wins on conflict.

## Package boundaries

- `backend/dart/pos_core` — pure Dart domain entities. No Flutter, SQLite,
  Supabase, or presentation dependencies.
- `backend/dart/pos_contracts` — platform-independent interfaces and contracts
  (repositories, `AppBackend`, sync contracts, `LocalDataOps`, licensing
  contracts). Depends only on `pos_core` + `meta`.
- `backend/dart/pos_local_engine` — SQLite/native persistence: `Sqflite*`
  repositories, `LocalDatabase` (single `schemaVersion = 22`), outbox, backup/
  restore, licensing implementations.
- `backend/dart/pos_cloud_engine` — cloud transport and cloud repositories
  (`SupabaseSyncBackend`, `SyncGatewayBackend`, `Cloud*Repository`). No
  Flutter/SQLite/`dart:io`.
- `frontend/` — Flutter shell: features, UI, composition roots (`main.dart`,
  `main_web.dart`), the `AppBackend` compatibility seam
  (`lib/core/backend/app_backend.dart`).

## Hard rules

- Never import private `src/` paths; use public package barrels.
- The web entry graph must never reach `sqflite`, `dart:io`, `path_provider`,
  or `LocalDatabase` (enforced by `frontend/test/architecture_test.dart`).
- `pos_contracts` must stay platform-independent — no Flutter widgets, no
  screen factories (those live on the frontend `AppBackend` seam).
- `backend/supabase/migrations/` is the single source of truth for server
  schema. `docs/*.sql` files are historical reference only.
- No new compatibility shims; converge on the package structure.

## Known accepted debt (do not "fix" silently)

- Duplicated cloud repositories: `frontend/lib/core/cloud/*` (used by
  `CloudBackend`) vs `pos_cloud_engine` cloud repos — consolidation pending.
- Dead file: `frontend/lib/core/sync/sync_gateway_backend.dart` (production
  uses the `pos_cloud_engine` version).
- Documented legacy gap: pre-v6 databases cannot migrate to v22 (see
  `database-safety.md`).

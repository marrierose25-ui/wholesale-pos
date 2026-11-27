# Migration Plan — Wholesale POS Refactor

Ordering principle (Part 0.8): one bounded group at a time; after every stage
format → analyze → test → build affected target → inspect diff → update
`migration-log.md` → report → stop.

Baseline (Part 1): analyze clean; 637 tests + 1 skip green; web release and
Windows release builds green. Any later regression is attributable to the
stage that introduced it.

## Stage 0 — Documentation (this part)

- [x] Audit + baseline + these docs.

## Stage 1 — Move sales-domain models into `domain/` (lowest risk, highest leverage)

Files: `features/sales/{sale,sale_item,shift,void_request}.dart` are pure Dart.
Move to `lib/domain/sales/` (or `lib/core/models/` if a domain layer is
deferred — decide at implementation time; the key win is that `core/` stops
importing `features/`).

- Update imports in: `core/repositories/{sale,shift}_repository.dart`,
  `core/cloud/{cloud_sale,cloud_shift}_repository.dart`,
  `features/**` consumers, `app_shell.dart`, `main.dart`, tests.
- No behavior change; pure move + import rewrite.
- Verify: analyze, full test suite, web build (import-graph sensitive).

## Stage 2 — Break `core → features` edges

- `cloud_backend.dart` imports `features/web/*` widgets: invert by having the
  web entry (`main_web.dart`) inject the gate/settings widgets into
  `CloudBackend` (constructor params), keeping `core/` feature-free.
- Re-check: no `core/` or `domain/` file imports `features/`.

## Stage 3 — Converge the two shells

- Extract the shared navigation model (`_NavItem`/`_ShellDestination`, tab
  switching, feature filtering via `kFeatures`) from `main.dart` +
  `app_shell.dart` into one `shell/` implementation parameterized by
  `AppBackend` + platform widgets.
- Introduce `NativeBackend implements AppBackend` wrapping the SQLite
  repositories so `main.dart` uses the same seam as web.
- Highest-risk stage for UI regressions; keep both entries compiling
  throughout; rely on the layout/widget test matrix.

## Stage 4 — Split `UserRepository` / `SaleRepository` responsibilities

- Extract auth (hashing, login guards, credential migration, demo user) →
  `AuthService`; account CRUD stays in `UserRepository`.
- Extract reporting queries from `SaleRepository` → read-side report
  repository(ies) per module.
- Preserve every public signature used by features/tests or update callers
  atomically in the same commit.

## Stage 5 — Module-ize repositories by business area

Reorganize `core/repositories/*` into per-module folders
(`sales/`, `register/`, `catalog/`, `finance/`, `warehouse/`, `identity/`),
keeping interfaces stable. Resolve cross-repo reads (`sale→shift summary`,
`finance→cash_movements`) through explicit APIs. `SyncOutbox` stays central.

## Stage 6 — Database layer separation

Split `local_database.dart`: connection/migration runner vs runtime helpers
(`getSetting`, `registerCurrentDevice` → owning modules). Schema version and
migration chain untouched.

## Stage 7 — Sync pull applier modularization

Split `sync_pull_applier.dart` into per-entity appliers behind one
coordinator. Ordering, transactions, `synced_at` reconciliation, and cursor
handling byte-identical. Sync tests are the gate.

## Stage 8 — `pos-api` internal modules

Split `index.ts` into `lib/*.ts` per domain; `index.ts` keeps serve/CORS/auth/
dispatch. Action names, payloads, auth order, and responses unchanged.
Deploy = same single function.

## Stage 9 — Backend schema source-of-truth reconciliation

Fold or annotate `docs/*.sql` vs `supabase/migrations/`; fix `DATABASE.md` /
`CLOUD_SYNC.md` drift (schema version, DDL source).

## Stage 10 — Cleanup

`util/` vs `utils/` merge, `tool/` vs `tools/` merge, stray
`supabase/supabase/.temp`, dead code (`supabase_sync_backend` opt-in path —
keep if still referenced by tests/private flag).

## Risks register

| Risk | Mitigation |
| --- | --- |
| Model move breaks serialization symmetry (local `toMap` vs cloud JSON) | Move is path-only; both sides update in one commit; repo + cloud tests cover round-trips |
| Shell convergence changes nav behavior/permissions | `kFeatures` filtering already centralized; widget/layout matrix + back-button tests are the gate |
| `AppBackend` seam leaks sqflite types into web graph | Web build in CI is the hard gate; conditional imports preserved |
| Repository split alters transaction/outbox atomicity | Outbox enqueue stays inside the same `txn`; sync outbox tests + repository tests verify |
| `pos-api` split changes auth/order semantics | Pure code-motion; dispatch table and middleware order reviewed line-by-line; verify scripts exist for live smoke |
| Hidden consumers of moved files (tests, tools, `tool/seed_cloud.dart`) | Repo-wide grep per stage; analyze catches all Dart breakage |
| Windows-only code paths (`dart:io`) pulled into web graph | Web release build is mandatory per stage |

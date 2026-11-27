# Target-State Architecture

Derived from the master refactoring prompt (Parts 0–1+). This document
describes the architecture the migration moves toward — it does not authorize
any implementation yet.

## 1. Governing model: modular monolith

- One deployable Flutter app per platform family (native, web/PWA), one
  Supabase backend.
- Business capability is organized into **modules** with explicit boundaries.
- Modules are independently organized inside the monolith; they do NOT each
  get a server, database, or network hop.
- Deployment boundaries that already exist are preserved:
  - `pos-api` stays ONE Edge Function (internally modular).
  - `sync` stays its own Edge Function.
  - `licensing` stays its own Edge Function.

## 2. Flutter application — target layering

```text
frontend/lib/
├── main.dart / main_web.dart        # thin entry points only
├── app/                             # composition root
│   ├── native/                      # native wiring (license, sqlite, sync loop)
│   └── web/                         # web wiring (CloudBackend, activation gate)
├── shell/                           # ONE adaptive shell (nav, gates, scaffold)
├── core/                            # shared kernel — no business modules depend
│   │                                #   on each other through it
│   ├── database/                    # connection + migration runner only
│   ├── sync/                        # outbox, service, backends, pull applier
│   ├── licensing/                   # license verify, device activation
│   ├── auth/                        # session store, feature registry
│   ├── platform/                    # AppBackend seam + per-platform impls
│   ├── theme/                       # design system
│   └── util/                        # pure helpers (money, dates, logging, io)
├── domain/                          # pure Dart business models + value objects
│   ├── sales/    (Sale, SaleItem, Shift, VoidRequest)
│   ├── catalog/  (Product)
│   ├── finance/  (FinanceEntry, FinanceCategory)
│   ├── warehouse/(Picklist*)
│   └── identity/ (User)
└── features/                        # UI modules — screens + view state only
    ├── pos/, register/, sales-history/, warehouse/, finance/,
    ├── dashboard/, reports/, users/, audit/, settings/, auth/, licensing/
```

Rules:

- `core/` may depend on `domain/` and platform packages — never on `features/`.
- `features/<x>/` may depend on `core/`, `domain/`, and shared UI primitives —
  never on another feature's internals. Shared widgets (e.g. the day
  browser currently `sales_by_day_screen`) move to a shared UI location or
  become part of the owning module's public surface.
- `domain/` is pure Dart: no Flutter, no sqflite, no HTTP.
- UI widgets contain no business rules; rules live in module application
  services / repositories.
- One shell implementation serves both entries; platform differences enter
  through the `AppBackend`-style seam and injected widgets, not duplicated
  navigation code.

## 3. Data access — target shape

- One shared SQLite database remains (atomic cross-module transactions are a
  hard requirement — Part 0.4).
- `LocalDatabase` shrinks to: open, migrate, backup-before-migrate. Runtime
  helpers (`getSetting`, `registerCurrentDevice`) move to the owning module
  or a small `core/database` support API.
- Each business module owns its repository interface + SQLite implementation
  - (where applicable) cloud implementation:

```text
features-or-modules/
  sales/       SaleRepository (writes, void workflow) + SaleReportRepository (reads/analytics)
  register/    ShiftRepository (shifts, cash movements, drawer math)
  catalog/     ProductRepository
  finance/     FinanceRepository
  warehouse/   PicklistRepository
  identity/    UserRepository + AuthService (hashing, guards, sessions)
```

- Reporting/analytics queries currently on `SaleRepository`
  (`getRevenueTrend`, `getDashboardStats`, `getAuditLogs`,
  `getProductSalesSummary`, `getCashierPerformance`, `getTodayRevenue`)
  separate into a read-side repository so write and report concerns can
  evolve independently — same SQL, same results, different owner.
- Authentication concerns inside `UserRepository` (PBKDF2 hashing, login
  guards, credential migration, demo-user provisioning) extract to an
  `AuthService`/`IdentityService`; `UserRepository` keeps account CRUD.
- Cross-module reads (`sale → shift summary`, `finance → cash_movements`)
  are resolved through explicit module APIs or read models — never by a
  repository reaching into another module's tables ad hoc. The transactional
  outbox stays centralized (`SyncOutbox`) because it must see every write.
- `AppBackend` becomes the single composition seam for BOTH entries:
  a `NativeBackend` wraps the SQLite repositories; `CloudBackend` wraps the
  `pos-api` clients. `settings_screen` stops taking a raw `Database`.

## 4. Sync — target shape (behavior frozen)

The sync protocol is a contract, not refactorable surface (Part 0.5):
entity names, payload shapes, aliases, actions, acks, retry/backoff,
conflict policy, dependency ordering, cursors, idempotency, demo isolation,
ledger ownership — all preserved byte-for-byte.

Internal organization may improve:

- `sync_pull_applier.dart` splits into per-entity appliers behind one
  `PullApplier` coordinator; transaction boundaries and ordering unchanged.
- `SyncOutbox` remains the single enqueue point invoked inside business
  transactions.
- `SyncService`/`SyncRuntime`/`SyncBackend` interfaces unchanged.

## 5. Backend — target shape

`pos-api/index.ts` (2399 lines) splits into internal modules WITHOUT changing
the deployed function or its action contract:

```text
supabase/functions/pos-api/
├── index.ts            # Deno.serve, CORS, auth/JWT/feature gating, dispatch
├── lib/
│   ├── auth.ts         # login, setup_owner, has_users, change_password, JWT verify
│   ├── products.ts
│   ├── sales.ts        # insert/search/void/void-requests
│   ├── register.ts     # shifts, cash movements, snapshots
│   ├── users.ts        # CRUD, permissions, demo user
│   ├── finance.ts
│   ├── warehouse.ts    # picklists, customers
│   ├── reports.ts      # dashboard, revenue trend, audit list
│   └── shared.ts       # ctx, helpers, OWNER_ONLY, ACTION_FEATURES
```

- `sync/index.ts` and `licensing/index.ts` get the same internal-module
  treatment (they are already cohesive single files; split only if it aids
  review — behavior identical).
- Server schema truth lives in `supabase/migrations/`; `docs/*.sql` scripts
  are reconciled (either folded into migrations or clearly marked
  dashboard-only runbooks).

## 6. Security invariants (unchanged)

Ed25519 license verification + canonicalization, device activation/seat
limits, JWT auth, `token_version` revocation, tenant isolation via
`customer_id`, owner-only and feature-tick authorization **server-side**,
PBKDF2 password hashing, `SECURITY DEFINER` RPC restrictions, service-role
containment, license-gated sync gateway. Frontend permission checks remain
UX-only.

## 7. What "done" looks like per module

- No `features/` imports from `core/` or `domain/`.
- No raw `Database`/`sqflite` types in feature widgets.
- No business rules in widgets.
- No circular imports; module dependency graph is a DAG.
- Every stage: `flutter analyze --fatal-infos` clean, `flutter test` green,
  affected build green, migration log updated.

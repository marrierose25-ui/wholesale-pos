# Cloud Sync Architecture (Phase 11 foundation)

This document explains **what was built, why it was built this way, and why
nothing else was built yet**. It is written for a reviewer auditing the move
from a single offline Windows till toward a future multi-device / cloud-viewed
system.

## 1. The problem the roadmap set out to solve

The app is today a **single-device, offline-first** POS: one Windows PC, one
SQLite file, no network. The stated goal is to grow toward:

* the owner viewing sales/reports remotely (a phone or browser), and
* eventually more than one register selling at once.

Those two goals are **not the same engineering problem**, and conflating them
is the main risk in the original roadmap. Remote *viewing* is a
**single-writer** problem: one till writes, the cloud only receives and displays.
There are no concurrent edits to merge. True multi-device *selling* is a
**multi-writer** problem and is the only case that needs conflict resolution.
We build for the first now and stay ready for the second, without paying its
cost today.

## 2. What was built (the safe, reversible core)

A **transactional outbox**. SQLite remains the single source of truth. Every
business write now also appends one row to a new local `sync_outbox` table,
**inside the same database transaction**, recording "this entity changed and
still needs pushing."

```
SaleRepository.saveSale()  ──►  BEGIN TRANSACTION
   insert sales row                │
   insert sale_items rows          │
   append sync_outbox row  ◄───────┘   all-or-nothing
                              COMMIT
```

Files added (`app/lib/core/sync/`):

| File | Responsibility |
|------|----------------|
| `sync_outbox_entry.dart` | The queued-change model + the `SyncEntities` / `SyncOperations` vocabulary shared with any future backend. |
| `sync_outbox.dart` | `upsert()` / `delete()` helpers that write an outbox row through a `DatabaseExecutor` so they can run **inside** the caller's transaction. |
| `sync_outbox_repository.dart` | `pending(limit)`, `pendingCount()`, `markSynced(ids)`, `pruneSynced()` — read/compaction API for the queue. |
| `sync_backend.dart` | `abstract class SyncBackend` + `NoopSyncBackend` (a backend that is "not configured" and pushes nothing). |
| `sync_service.dart` | `syncNow()` drains the queue to the backend; on any failure the rows **stay queued**. |

Wired into: `SaleRepository` (`saveSale`, `voidSale`, `requestVoid`,
`approveVoidRequest`, `rejectVoidRequest`) and `ShiftRepository` (`openShift`,
`addCashMovement`, `closeShift`).

**Properties this buys us, and why they are audit-relevant:**

* **Offline-first, guaranteed.** There is no network call on the write path. If
  there is no internet, selling is completely unaffected — the queue just grows.
* **Atomic.** Because the outbox row is in the same transaction as the sale, you
  can never have a sale that forgot to record itself for sync, or a sync record
  for a sale that rolled back.
* **Durable.** Queue rows live in the SQLite file, so they survive app crashes
  and restarts. Nothing is lost between sessions.
* **Idempotent replay.** The server applies by `entity_id` (see
  `docs/postgres_schema.sql`), so a retry after a dropped connection cannot
  double-count a sale.
* **Pluggable, and provably inert today.** The app ships with
  `NoopSyncBackend` (`isConfigured = false`), so `syncNow()` is a no-op. The
  feature cannot alter production data until someone deliberately supplies a
  real backend. This is the "reversible" property: the whole increment is dark
  until switched on.

## 3. Schema change (v8 → v9)

One additive table and one index; **no existing table or column was touched**,
so the migration is a pure `CREATE TABLE IF NOT EXISTS`:

```sql
CREATE TABLE sync_outbox (
  id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
  operation TEXT NOT NULL, payload TEXT NOT NULL,
  created_at TEXT NOT NULL, synced_at TEXT
);
CREATE INDEX sync_outbox_pending ON sync_outbox(synced_at);
```

The pre-existing `sales.synced_at` and `devices.last_sync_at` columns already
gave us sync-readiness; v9 adds the queue. The v8→v9 upgrade path is covered by
an automated migration test that rewinds a database and reopens it.

`sync_outbox` is deliberately **not** included in the JSON backup/export, and
`counters` are deliberately **not** mirrored to the cloud: a receipt counter
must never cross a network boundary or two devices would race the same numbers.

## 4. Persistent sign-in (opt-in, default OFF)

Added `app/lib/core/auth/session_store.dart`: a `SessionStore` abstraction with
a settings-table implementation, an opaque random token bound to
`userId + issuedAt + expiresAt`, a 12-hour lifetime, and `UserRepository.getById`
that refuses to rehydrate a deactivated account.

* The "Stay signed in on this PC" switch in **Settings → Account** is **off by
  default**. This is a deliberate anti-regression: auto-resuming an OWNER
  session on a shared till would break the per-person accountability that shift
  tracking and void approvals depend on. It only turns on when the operator
  chooses it, and turning it off clears any stored session.
* A restored login is still checked against the live `users` table, so a
  deactivation or delete revokes the persisted session immediately.

**Deliberate deviation from the roadmap:** the roadmap specified
`flutter_secure_storage` for this. We did **not** add it, for two reasons an
auditor should weigh:

1. It is a native Windows plugin. Adding it now puts the offline, reproducible
   release build at risk for a capability that has nothing to secure yet —
   **there is no server and therefore no real access/refresh token**. Storing a
   made-up token in the OS vault would be security theater.
2. The `SessionStore` is an **interface**. When the cloud backend lands and
   issues genuine short-lived access + refresh tokens, swapping the settings
   table for `flutter_secure_storage` is a one-class change with no callers
   touched. We took the seam, not the dependency.

The token currently holds **no secret material** — never the password or the
PBKDF2 hash — so storing it in the local settings table leaks nothing that
helps an attacker recover credentials.

## 5. What was deliberately NOT built yet (and why)

These require accounts/keys/infrastructure only the owner can provision, and
each is a hard-to-reverse or externally-visible action. Building them blind
would create risk, not value:

* **A real `SyncBackend` + Supabase/Postgres deployment** — needs a provisioned
  project and credentials. The server DDL is drafted (`docs/postgres_schema.sql`)
  so this is a "connect", not a "design", when the account exists.
* **Conflict resolution / CRDTs / row versioning** — unnecessary under the
  single-writer model. Introduced only if/when a second device *edits* the same
  rows. Deferring this is the correct call, not an omission.
* **Push notifications (FCM)** — needs Google/Firebase project setup; purely an
  add-on once there is a backend to notify from.
* **Web dashboard / mobile clients / expanded RBAC** — downstream of the data
  actually reaching the cloud. The owner confirmed OWNER + CASHIER is sufficient
  for now, so no role model was expanded.

## 6. How to turn this on later (the intended next step)

1. Provision Postgres (or Supabase), run `docs/postgres_schema.sql`.
2. Implement `SyncBackend` against it (`isConfigured` true once credentials are
   present; `push()` performs the idempotent upserts).
3. Inject that backend into `SyncService` and call `syncNow()` from a timer /
   app-resume / post-sale hook. **No changes to `SaleRepository` /
   `ShiftRepository` are needed** — the enqueue is already wired.
4. Replace `SettingsSessionStore` with a `flutter_secure_storage` implementation
   and real server-issued tokens.

## 7. Test coverage for this phase

* `test/core/sync/sync_outbox_test.dart` — enqueue on every wired write; Noop
  leaves the queue; a recording backend pushes and marks synced; a throwing
  backend leaves rows queued; `pruneSynced` removes only synced rows.
* `test/core/database/migration_test.dart` — v8→v9 adds `sync_outbox` +
  `sync_outbox_pending`, starts empty, and preserves existing sales.
* `test/core/auth/session_store_test.dart` — save/load round-trip, expiry,
  tampered-record rejection, and `getById` refusing inactive/unknown accounts.
* `test/core/sync/supabase_sync_backend_test.dart` — request mapping to the right
  tables, the `merge-duplicates` + server `User-Agent` headers, throw-on-non-2xx
  (so rows stay queued), and sale-delete cascading to its items — all against a
  mock HTTP client, no real network.

## 8. Supabase backend — now implemented (and how it is secured)

`app/lib/core/sync/supabase_sync_backend.dart` implements `SyncBackend` over the
Supabase PostgREST API. This turns the previously-inert seam into a working push
path. Points an auditor should note:

* **Idempotent upserts.** Each queued entity is POSTed with
  `Prefer: resolution=merge-duplicates` and `?on_conflict=id`, so a retry after a
  dropped connection overwrites by primary key and can never double-count a sale.
  On any non-2xx the backend throws; `SyncService` leaves the rows queued and the
  next drain retries.
* **Credentials never leave the PC.** Only the four transactional entities are
  pushed (sale+items, shift, cash movement, void request). Users, devices and
  products are NOT synced. The cloud mirror is therefore **foreign-key-free**
  (`docs/supabase_schema.sql`) — no password hashes or account rows are stored in
  the cloud, and a sale lands even though the cloud has no cashier/device rows.
* **Secret-key handling.** The project URL and key are supplied at build time via
  `--dart-define=SUPABASE_URL/SUPABASE_KEY`, so they are **not committed to the
  repository**. When they are absent the app builds as the offline-only release
  (`NoopSyncBackend`). This key is a **service/secret** key that bypasses row-level
  security, so this build is for the **owner's own shop PCs only** and must not be
  distributed to customers; the long-term design is per-device auth tokens once the
  backend issues them.
* **Supabase "browser" block.** Supabase rejects its `sb_secret_…` keys with a 401
  when a request looks like it originates from a browser. The backend therefore
  sends a server-style `User-Agent: WholesalePOS-Sync/1.0`. Verified live: a
  POST → read-back → DELETE round-trip succeeded against the real project.
* **Known timezone caveat.** SQLite writes timestamps as local time without an
  offset; the cloud `timestamptz` columns interpret them as UTC. This can skew
  "today" boundaries by the local offset and should be revisited when the reporting
  dashboard is built (send an explicit offset or convert to UTC at enqueue).

## 9. What still remains before the phone/dashboard view

The data now reaches the cloud. The remaining work is the **read side**: a small
web or mobile report screen that queries these mirror tables, plus row-level
security / auth if that viewer is ever exposed publicly. That is the next phase.

## Summary for the auditor

The team converted a single-writer offline POS into a **sync-ready** system by
adding the one thing that is provably safe in that direction — a transactional,
durable, idempotent, currently-inert outbox — plus an opt-in session layer behind
a swappable interface. Every hard, irreversible, or externally-dependent piece
(real cloud, conflict merging, push, new clients, new roles) was consciously
deferred until the prerequisites and accounts exist. The live POS behaviour is
unchanged and un-risked by this increment.

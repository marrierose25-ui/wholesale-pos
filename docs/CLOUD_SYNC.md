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

```text
SaleRepository.saveSale()  ──►  BEGIN TRANSACTION
   insert sales row                │
   insert sale_items rows          │
   append sync_outbox row  ◄───────┘   all-or-nothing
                              COMMIT
```

Files added (`frontend/lib/core/sync/`):

| File | Responsibility |
| ------ | ---------------- |
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

Added `frontend/lib/core/auth/session_store.dart`: a `SessionStore` abstraction with
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

`frontend/lib/core/sync/supabase_sync_backend.dart` implements `SyncBackend` over the
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

### 8a. Mobile sync — safe default and the private-use opt-in (SUPERSEDED by §8b)

> **Phase 18 note:** the whole embed-the-secret question below is obsolete for
> phone and buyer builds — the license-gated sync gateway (§8b) now takes
> precedence over this path automatically whenever the licensing function URL
> is baked in. Kept for the developer's own desktop secret path and history.

A phone build inherits the same `SUPABASE_URL` / `SUPABASE_KEY` defines, but
the APK is a distributable artifact: anyone who has the file can unpack it and
extract the key. That is why `SupabaseSyncBackend.fromEnvironment()` adds one
extra rule for Android/iOS:

* **Safe default (`NoopSyncBackend`)** — on mobile, if the URL and key are
  baked in but the operator has *not* explicitly opted in, the app refuses
  the credentials, prints a one-shot startup notice explaining why, and
  behaves exactly like the offline release. A `flutter build apk --release`
  with the licensing define but no sync flag therefore produces a **shippable
  APK that cannot leak the key** — sync is simply off on the phone.
* **Private-use opt-in** — for the shop's own handful of phones on the owner's
  own network (never distributed, never posted to a store), pass:

  ```powershell
  flutter build apk --release `
    --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<hex> `
    --dart-define=SUPABASE_URL=<project-url> `
    --dart-define=SUPABASE_KEY=<secret-key> `
    --dart-define=WHOLESALE_POS_UNSAFE_EMBED_SYNC_SECRET=true
  ```

  The name of the flag is intentional: `UNSAFE_EMBED` makes it awkward to
  add by accident and easy to grep in CI logs. When this flag is set the
  phone behaves like a shop PC — sync runs, mirror tables fill.

  Trade-offs the owner accepts by flipping it: the secret is inside the APK
  on disk and in memory; anyone with the APK (or the phone) can extract it;
  RLS cannot help because the key bypasses RLS by design. So the key must
  match a Supabase project whose only entry point is this shop, and the
  owner should rotate the key from the Supabase dashboard if a phone or APK
  is ever lost. If the app is going to be distributed beyond the shop or
  listed on an app store, **do not use this flag** — wait for the
  anon-key + row-level-security backend (see §9).

* **Unit-testable** — the branching lives in `SupabaseSyncBackend.selectBackend(
  url, key, unsafeAllowEmbed, isMobile)`, a pure function covered by
  `test/core/sync/backend_selection_test.dart`. The tests assert all four
  combinations (empty key → Noop, desktop → live regardless of flag, phone
  without flag → Noop, phone with flag → live) so an accidental change to
  the rule fails CI rather than ships.

### 8b. Phase 18 — the license-gated sync gateway (multi-tenant, sellable)

The Phase-12 problem: sync authenticated with the project **secret key**, which
bypasses RLS entirely, so it could only ever live inside the owner's own locked
desktop builds — never in a distributable. The Phase-18 replacement reuses the
trust primitive the licensing system already mints: the **signed v2 license**
(Ed25519, device-bound, contains `customer_id`).

```text
client (no keys)                    sync Edge Function (service role)
  outbox batch ───────────────────►  1. verify Ed25519 signature + expiry
  { action:'push',                   2. license row not revoked server-side
    license:<signed payload>,        3. (code,fingerprint) holds an ACTIVE seat
    entries:[…] }                    4. upsert rows, STAMPING customer_id from
                                       the license — caller cannot address
                                       another shop's partition
```

* **Server** (`supabase/functions/sync/index.ts`, deployed, JWT-verify off like
  `licensing`): mirrors `push` / `pull` / `ping`. Authenticates with the license
  itself — the anon key is never sent and has `REVOKE ALL` plus RLS-with-no-
  policies on every mirror table, so direct PostgREST access is dead even with
  a valid-looking request. `customer_id` is taken ONLY from the verified
  license payload, never from client JSON. Seat deactivation cuts sync on the
  next drain (registration check per request).
* **Schema** (`docs/supabase_sync_multi_tenant.sql`, applied live): every
  mirror table gained `customer_id uuid NOT NULL REFERENCES customers(id)`,
  PK became `(customer_id, id)` (local uuids are namespaced per shop), and
  read indexes lead with `customer_id`. One Supabase project now hosts many
  shops without cross-reads possible at any layer below the function.
* **Client** (`lib/core/sync/sync_gateway_backend.dart`): implements the same
  `SyncBackend` seam. Reads the license lazily per drain from the
  `license_code` setting — activate mid-session and the next 30-second tick
  starts flowing, no restart. Un-activated devices throw before any HTTP call,
  so `SyncService` keeps rows queued and selling is unaffected.
* **Selection priority** (pure + tested in
  `test/core/sync/sync_gateway_backend_test.dart`, 13 cases): desktop with
  baked secret → legacy direct path (unchanged, owner PCs only). Otherwise
  gateway whenever its URL resolves (explicit
  `WHOLESALE_POS_SYNC_FN_URL` define, or derived by swapping the licensing
  URL's `/licensing` suffix for `/sync` — so `tools/build_release.ps1`
  enables it with zero extra flags). Otherwise the legacy mobile opt-in.
  Otherwise Noop. **A phone build with the release script's defines can no
  longer sync through the secret path even if the UNSAFE flag is passed —
  the gateway preempts it.**
* **Verified live 2026-10-24**: real license minted by the licensing function
  → `ping` ok; push in client vocabulary (`sale`/`UPSERT`) → 2 rows landed
  stamped with the right `customer_id`; `DELETE` cascaded sale_items;
  forged license rejected 401; `has_table_privilege('anon',…)` false on every
  mirror table.

## 9. What still remains before the phone/dashboard view

The write path is now sellable. The remaining work is the **read side**: the
`pull` endpoint exists server-side (delta cursor on `received_at`), but no
client screen consumes it yet — the phone viewer / web dashboard showing a
shop's live sales is the next phase. Multi-register *selling* (two tills, same
shop) additionally needs the outbox to start pulling reference data, which
stays deliberately out of scope under the single-writer rule (§1).

## 10. Multi-device rules (two or more tills on one shop)

A second device turns every "the local row is the truth" shortcut into a silent
divergence, because nothing crashes — the other device simply keeps a different
opinion. The rules below are the ones that had to be made explicit; each is
enforced in code and covered by a test.

### Server

* **An UPDATE must move the row forward** (`docs/supabase_sync_delta.sql`).
  The pull is a keyset walk over `(received_at, id)`, and `received_at` was a
  `DEFAULT now()` — stamped on INSERT and never again. A void, a decided void
  request or a closed drawer changed the row in place and kept its original
  stamp, so it never re-entered the feed: till B kept counting voided money,
  kept showing decided requests as pending, and could not open a drawer at all
  (one OPEN shift per shop). A `BEFORE UPDATE` trigger now stamps it on every
  mirror table, so *no* writer can forget. Moving later in the ordering is also
  safe for the walk: the worst case is a second delivery, and re-applying a
  known row is a no-op.
* **Device ≠ user (Request 3 actor grants).** The signed license proves the
  DEVICE, never which person is at the till, so `pos_sync_apply` no longer
  trusts actor ids inside pushed payloads (`cashier_id`, `user_id`,
  `created_by`, `requested_by`). After a password sign-in the native client
  calls pos-api's public `issue_actor_grant` action — which re-verifies the
  password AND the signed license — and receives an opaque token bound to
  (tenant, user, device). The sync gateway stores only its SHA-256 digest in
  `sync_mirror.actor_grant_hash`; `pos_sync_apply` resolves the digest to a
  live user and uses THAT user for every actor column, then enforces the
  user's feature permissions (`pos`/`register`/`finance`/`warehouse`) through
  permission-wrapped RPCs. A missing/expired/revoked grant leaves the row
  PENDING (`ACTOR_AUTH_REQUIRED`) and the client reports it `deferred` — the
  outbox entry stays queued, nothing is discarded or falsely acked. The
  primary grant is always the entry's OWN actor: when the payload names an
  actor whose grant is absent, the row defers rather than borrowing the
  signed-in user's grant (Request 3 final corrections). Owner
  accounts are never mutable through device sync: devices may provision
  CASHIER accounts under an owner grant, but cannot create/promote owners or
  change any existing credential — those go through live pos-api only.
  Grants expire, are bound to the issuing device fingerprint, and die on a
  `token_version` bump (password/status change) or explicit revocation.
  Offline tills keep selling; authorization is proven at push time, and a
  row that cannot yet be verified simply waits in the outbox.
* **Explicit sync outcomes and durable quarantine** (Request 3 acceptance).
  Every staged row resolves to `APPLIED`, `DEFERRED` (actor grant or
  prerequisite missing — stays PENDING), `RETRYABLE` (transient
  infrastructure failure — deadlock, serialization, connection loss — stays
  PENDING with a `RETRYABLE:` marker and is never a verdict on the record),
  or `REJECTED` (permanent validation/authorization refusal). The client
  acks ONLY `applied`; deferred/retryable/stored rows stay queued. A
  rejected row moves to a durable quarantine on the device (original
  payload, entity identity, server error, timestamps — schema v24) that is
  never auto-retried and never pruned; the operator reviews it under
  Settings → Cloud Sync → Rejected sync records with deliberate retry or
  confirmed discard. Retry is a real server-side recovery, not a local
  requeue: the client calls the sync gateway's `recover` action, which runs
  `pos_sync_recover` — it re-queues ONLY rows still marked `REJECTED` back to
  `PENDING` (never `APPLIED`, never an already-`PENDING` row), writes a
  `SYNC_RECOVERY` audit entry preserving the previous refusal, then re-runs
  `pos_sync_apply` so grants, permissions and payloads are genuinely
  re-validated. The apply RPCs' own idempotency (sale/movement ids, the
  one-deposit/one-reversal-per-collection guards) means recovery cannot
  duplicate an already-applied financial transaction. A record the gateway
  refused before staging reports `missing` and stays quarantined; a backend
  without recovery support tells the operator so honestly instead of
  pretending the requeue did anything. Unchecked `*_unchecked` money RPCs
  are not executable by `service_role` — only the permission-checked
  wrappers are.
* **Per-actor finance attribution** (Request 3 acceptance). 
  `sync_mirror.actor_grant_hashes` carries one grant digest per actor the
  payload names (`created_by`, `completed_by`, `deleted_by`), so a finance
  entry created by cashier A and completed by cashier B lands with
  `created_by = A`, `completed_by = B`, and the cash deposit attributed to
  the completer through the locked `pos_complete_finance` RPC. Payload actor
  ids only SELECT which staged grant to resolve — the resolved user is what
  is recorded, so a forged id cannot re-attribute the entry. The final
  `DELETED` status is not treated as the whole history: `pos_sync_apply`
  replays each independently authorized transition in order — insert PENDING
  under the creator, `pos_complete_finance` under the completer (its own
  audit row and cash deposit), `pos_delete_finance_entry` under the deleter
  (its own audit row and reversal) — so a create+complete+delete that all
  happened offline before first sync keeps every actor, and CASH
  collections get exactly one deposit and one reversal because the device's
  cash legs carry `source_finance_entry_id` and the server-side reversal
  skips legs the device already posted. Since migration
  `20261204000000_request3_financial_integrity` the dedup is atomic: a unique
  index on `(customer_id, source_finance_entry_id, type)` lets one DEPOSIT and
  one WITHDRAWAL exist per collection, and `pos_add_cash_movement` /
  `pos_complete_finance` / `pos_delete_finance_entry` all insert with
  `ON CONFLICT DO NOTHING`, so two devices racing different movement ids for
  the same leg converge on one row — the loser is handed the existing
  movement, never a financial failure.
* **Legacy unlinked reversals** (Request 3 financial integrity). Tills that
  queued a cash reversal before `source_finance_entry_id` existed send a
  WITHDRAWAL with no collection link. The server never matches on amount
  alone: a legacy leg is adopted only when its EXACT generated reason
  (`Reversal: deleted cash collection from <category> (<source>)`), amount,
  and actor evidence identify exactly ONE collection — either at movement
  insert (`pos_legacy_reversal_entry_candidates`) or at delete time
  (`pos_legacy_reversal_candidates`, which then links the movement and
  audits `LEGACY_REVERSAL_LINKED`). Two or more matching unlinked reversals
  are ambiguous: the delete refuses with `LEGACY_REVERSAL_AMBIGUOUS`, the
  staged `finance_entry` stays PENDING with that durable marker (payload and
  movements preserved, nothing acknowledged), and an operator links the
  correct movement before retry. A missing reversal still gets exactly one
  server-written leg; a uniquely identifiable one is never duplicated.
  Devices with older pending outbox records need no special upgrade step:
  the next sync push carries the same payload and the server reconciles it
  under the rules above.
* **First-owner bootstrap** (Request 3 acceptance). A native install creates
  its OWNER offline and reconciles through pos-api's `setup_owner` (activation
  code + one-owner policy + rate limits), passing the local user id and its
  cloud-format credential so local and cloud identities match.
  `pos_setup_owner` is idempotent for the same id and serializes concurrent
  attempts per tenant; a different existing owner yields a conflict, never a
  silent overwrite. A same-id retry is idempotent ONLY when the submitted
  username and credential (`pw_salt` + `pw_hash`) match the stored owner row
  exactly. Pass-the-hash is closed (Request 3 final corrections): the
  pre-hashed credential is a replayable verifier, not proof of the plaintext
  password, so pre-hashed creation and pre-hashed same-id retry return a
  SESSION-LESS success (`ok` + `user_id`, `created`/`reconciled`) and never
  mint an OWNER JWT — `OwnerBootstrapService` marks reconciliation done on
  that response without needing a token. Only the plaintext-password path
  (web bootstrap, password verified server-side) issues a session; normal
  OWNER login always goes through the real password verification flow.
* **Privileged transitions are never applied from pushed payloads** (Stage
  4.1 / audit H1). A license proves the device, never WHICH USER acted, so
  the gateway stages and applies only data: `pos_create_sale` hardcodes
  `COMPLETED` and `pos_sync_apply` inserts void requests as `PENDING`. A
  pushed `VOIDED`/`APPROVED`/`REJECTED` payload can no longer mint an
  authoritative transition. Owner-authorized voids recorded offline are
  kept in the local `pending_owner_actions` store and released through
  `pos-api`'s JWT-authenticated `void_sale`/`approve_void`/`reject_void`
  actions, where `p_user` is carved from the verified token — see
  `frontend/lib/core/sync/owner_action_reconciler.dart`.
* **Cloud-side void invariants** (`backend/supabase/migrations/
  20261125000000`–`20261127000000`). A `BEFORE INSERT` trigger on
  `void_requests` takes `SELECT ... FOR UPDATE` on the sale row, which
  serializes request insertion against `pos_void_sale`/`pos_approve_void`:
  insert-first commits PENDING and the void's settle trigger approves it;
  void-first makes the insert fail. An `AFTER UPDATE` trigger on `sales`
  settles still-PENDING requests in the same transaction, attributed to
  `voided_by` — and only when it is non-NULL, so no unattributed approval
  can be manufactured. A composite FK `(customer_id, sale_id)` →
  `sales(customer_id, id)` rejects requests for missing or cross-tenant
  sales, and a partial unique index allows at most one PENDING request
  per sale.

### Client (`lib/core/sync/sync_pull_applier.dart`)

* **A pulled row is never dropped for a missing foreign key.** `sales` requires
  `cashier_id`, `shift_id` and `device_id`, and the till that made a sale may
  be the only one that has seen the cashier or the drawer. A dropped insert
  loses the sale, its line items and its movements silently. The applier now
  mints the missing parent first — an inactive, soft-deleted placeholder user
  that cannot sign in and is hidden from the staff list, a closed zero-cash
  drawer, an "Unknown register" device — and then keeps the sale.
* **Only one-way transitions are applied.** A stale `COMPLETED` page can no
  longer un-void a sale; a void request only moves PENDING → decided; a shift
  only moves OPEN → CLOSED. Anything still queued in this till's own outbox is
  left alone, and the local row wins everywhere else.
* **Cloud-owned account fields are adopted.** Role, `is_active`, `deleted_at`
  and `permissions` follow the cloud, so a cashier switched off (or a role
  changed) in the browser stops signing in on every till. A local password is
  never overwritten — the browser credential is stored beside it (schema 15).
* **Parents are pulled before their children.** The puller pages one table at
  a time in dependency order and stops the run as soon as a table was not
  exhausted, instead of pulling `sale_items` while `sales` still has a backlog
  and refusing every orphan.

## Summary for the auditor

The team converted a single-writer offline POS into a **sync-ready** system by
adding the one thing that is provably safe in that direction — a transactional,
durable, idempotent, currently-inert outbox — plus an opt-in session layer behind
a swappable interface. Every hard, irreversible, or externally-dependent piece
(real cloud, conflict merging, push, new clients, new roles) was consciously
deferred until the prerequisites and accounts exist. The live POS behaviour is
unchanged and un-risked by this increment.

## Rate Limiting — Best Effort Only

Login attempts are rate-limited by an in-memory counter inside the
`pos-api` Edge Function (see `loginThrottle` in `index.ts`). This is
best-effort by design:

* **Does not span isolates.** If Supabase scales the function to N
  containers, each container has its own counter. Effective rate limit
  is N × the configured maximum.
* **Resets on container recycle.** A cold start zeroes the counter.
* **Not durable.** No database, no Redis — only the process's memory.

The mitigation layered on top is PBKDF2-HMAC-SHA256 at 210,000
iterations per attempt (~50ms of CPU on modest hardware). A brute-force
attacker is slowed but not stopped.

**Current posture is acceptable** for a single-tenant shop with a small
isolate pool. If the tenant is targeted by sustained credential
stuffing, deploy a durable rate limiter (Redis, or a Postgres-based
counter with TTL). This is a real decision for scale, not a bug.

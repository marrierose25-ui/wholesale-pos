# Stage 4.1 / Audit H1 — Closure Report

Date: 2026-11-24 · Branch: `stage4/h1-sync-authorization` · Base: `a491942`

## 1. PostgreSQL environment actually used

No staging database credentials exist on this machine, and the linked
Supabase project (`aymen`, ref `trcthxyyuapwavzeisvm`) is **production** —
nothing was applied to it. The environment used instead:

- `supabase db pull --remote --declarative` (read-only) exported the real
  production schema to `backend/supabase/supabase/schemas/` (pg-delta
  format, per-object files + `.pgdelta-export.json` load order).
- A local `postgres:17` Docker container (`h1pg`, port 55432) was loaded
  with that export in dependency order (functions → tables → views →
  event triggers/default privileges; roles `anon`, `authenticated`,
  `service_role` created to satisfy grants). Result: a byte-faithful
  replica of the production schema — this is the *actual staging schema*,
  not a docs approximation.
- Migrations `20261125000000`, `20261126000000`, `20261127000000` were then
  applied to the replica with `psql -v ON_ERROR_STOP=1`. All three applied
  cleanly: settle trigger + insert-lock trigger created, composite FK
  `void_requests_sale_fkey` added `NOT VALID` then **validated** (zero
  orphans), partial unique index `void_requests_one_pending_per_sale`
  created (zero duplicate PENDING rows).
- All earlier migrations (through `20261111000000`) are already reflected
  in the production schema export (verified: owner-check bodies in
  `pos_void_sale`/`pos_approve_void`/`pos_reject_void`, latest
  `pos_sync_apply`, `touch_received_at` on picklists).

## 2. Schema weaknesses found and closed

Audit of the two pending migrations against the real schema found:

- **`void_requests.sale_id` had no foreign key.** The insert-lock trigger
  deliberately returned early on a missing sale ("left to the existing
  foreign-key / app-level checks") — but no FK existed. Only app-level
  checks in `pos_sync_apply` and `requestVoid` guarded it. Closed by
  `20261127000000_void_request_sale_fk.sql`: composite FK
  `(customer_id, sale_id) → sales(customer_id, id)`, `NOT VALID` +
  validated-when-clean, plus partial unique index enforcing one PENDING
  request per sale.

## 3. Six database scenarios — actual SQL evidence

Test script: `backend/supabase/tests/h1_void_invariants/h1_void_invariants_test.sql`
(run with `psql -f`; output reproduced below, abridged).

| # | Scenario | Result |
|---|----------|--------|
| S1 | PENDING request + `pos_void_sale` | `APPROVED`, `decided_by=owner1`, `decided_at` set, sale `VOIDED`; replay refused ("already voided") |
| S2 | INSERT request on VOIDED sale | `ERROR: Sale sale-s2 is not voidable (status VOIDED)` — 0 rows leaked |
| S3 | Concurrent insert vs void, **both orderings** (two live psql sessions) | Insert-first: request committed PENDING → void blocked on row lock → proceeded → settle trigger `APPROVED` it (`decided_by=owner1`). Void-first: insert's `FOR UPDATE` blocked → saw `VOIDED` → `ERROR`, 0 rows. Neither ordering can end VOIDED+PENDING. |
| S4 | Missing sale reference | FK violation for nonexistent sale AND for cross-tenant `(customer_id, sale_id)` pair |
| S5 | Sale → VOIDED with `voided_by NULL` | Request stays `PENDING`, `decided_by` NULL — visible, never an unattributed approval |
| S6 | All insertion paths | `pos_sync_apply` on VOIDED sale → mirror row `REJECTED`, 0 rows in `void_requests`; duplicate PENDING → unique-index violation; `pos_void_sale`/`pos_approve_void` with cashier id → "Void requires owner authorization."; `SET ROLE authenticated` → "permission denied for function" |

Concurrency evidence (verbatim):

```
-- insert-first: A: BEGIN; INSERT req-conc-a; pg_sleep(8); COMMIT
--               B: pos_void_sale(...)  -- blocked ~8s, then succeeded
req-conc-a | APPROVED | owner1 | VOIDED | owner1

-- void-first:  C: BEGIN; pos_void_sale(sale-conc-b); pg_sleep(8); COMMIT
--              D: INSERT req-conc-b   -- blocked ~8s
ERROR: Sale sale-conc-b is not voidable (status VOIDED).
leaked rows for req-conc-b: 0
```

## 4. Full H1 implementation review (section-3 checklist)

- **JWT-derived owner identity authoritative** — `pos-api` carves
  `ctx.userId`/`ctx.customerId` from the verified HS256 JWT (`sub`/`cid`),
  re-checks `token_version`/`active`/`deleted_at` per request; RPCs
  re-verify `p_user` is an active OWNER. Confirmed in
  `shared/auth.ts`, `sale_actions.ts`.
- **Device licensing never substitutes for user authz** — `sync` gateway
  applies data only; `push_security_test.ts` proves forged
  VOIDED/APPROVED payloads never reach privileged RPCs (4/4 pass).
- **Client payloads cannot decide privileged states** — `pos_create_sale`
  hardcodes `COMPLETED`; `pos_sync_apply` hardcodes `PENDING`.
- **Direct voids settle pending requests** — local txn
  (`sqflite_sale_repository.dart`) + cloud settle trigger, both verified.
- **Lost responses cannot duplicate** — reconciler re-assesses
  authoritative state before/after calls; `confirmed` only on exact
  actor+parameters match.
- **Conflicting decisions stay pending/visible** — `Verdict.conflict`
  path keeps entries; corrupt store surfaces `PendingOwnerActionsCorrupt`
  with raw preserved.
- **Corrupted pending records cannot silently disappear** — `load()`
  throws before any `_write()`; Settings shows recovery state.
- **Concurrent queue changes cannot lose actions** — `record()`/
  `removeConfirmed()` run inside single sqflite transactions;
  `_ensureOutboxTarget` check-and-insert is transactional.
- **Settings recovery owner-only** — tile lives inside the `if (_isOwner)`
  "Data Management" block; server re-verifies regardless.
- **Credentials/JWTs not persisted** — `CloudApiClient.token` is
  memory-only; `auth_session`/license/activation keys are stripped from
  backups (`data_exporter.dart` secret list).
- **Backup/restore preserves pending ops** — `pending_owner_actions`
  lives in `settings`, which is exported/imported and is not a secret key.
- **Retry after missing sync target** — `_ensureOutboxTarget` re-queues
  the outbox row from local data inside a transaction before assessing.

## 5. Test results (actual commands run)

| Command | Result |
|---|---|
| `deno check index.ts` (pos-api, sync) | clean |
| `deno fmt --check` (pos-api, sync) | clean (34 + 2 files) |
| `deno test --allow-env --allow-read --allow-net tests/` (pos-api) | **33 passed, 0 failed** |
| `deno test --allow-env tests/` (sync) | **4 passed, 0 failed** |
| `flutter analyze --fatal-infos` (frontend) | **No issues found** |
| `flutter test` full suite, run 1 | **749 passed, 1 skipped, 0 failed** |
| `flutter test` full suite, run 2 | **749 passed, 1 skipped, 0 failed** |
| `flutter test test/core/database/interrupted_migration_test.dart` | 3/3 pass (post-fix) |
| PostgreSQL integration (S1–S6 above) | all pass on real PG17 |

### Flaky-test fix

`interrupted_migration_test` spawned `dart run`, whose frontend can leave
the kernel alive as a child process — `Process.kill()` then orphaned a
child still holding the SQLite file (intermittent "migration finished
despite the kill" / locked-file failures). `dart compile exe` was tried
and rejected: compiled exes cannot resolve the `sqlite3` native asset.
Fix: `_killTree()` uses `taskkill /PID <pid> /T /F` on Windows (plain
`process.kill()` elsewhere, where `dart run` is in-process). No test was
skipped, weakened, or deleted.

## 6. Files changed (this closure)

- `backend/supabase/migrations/20261127000000_void_request_sale_fk.sql` — new
- `backend/supabase/tests/h1_void_invariants/h1_void_invariants_test.sql` — new
- `frontend/test/core/database/interrupted_migration_test.dart` — tree-kill fix
- `docs/CLOUD_SYNC.md` — H1 sync/void-invariant documentation
- `docs/architecture/stage4-h1-closure.md` — this report

## 7. Remaining limitations

- The local replica is schema-faithful but contains no production *data*;
  the FK/index guards reported zero orphans/duplicates locally. When the
  migration is applied to production, the `NOT VALID` + guarded-index
  design means it cannot fail on dirty data — it enforces new writes
  immediately and warns if historical cleanup is needed.
- `sales.status` / `void_requests.status` still have no CHECK constraint
  (pre-existing; only `COMPLETED`/`VOIDED` are produced by any code path).
- `requested_by`/`decided_by` remain unconstrained text (sync path can
  legitimately carry `''`); attribution is enforced by the RPC owner
  check + settle trigger instead.
- Docker daemon and Supabase CLI were used only for a local replica;
  **no migration was applied to any hosted database.**

## 8. Recommendation

**APPROVED** — conditional on the standard deploy gate: apply
`20261125000000`–`20261127000000` to the target database through the
normal authorized migration path. All H1 invariants are now enforced in
the database itself, verified against the real production schema on a
live PostgreSQL 17 instance, and the full Flutter/Deno verification
surface is green.

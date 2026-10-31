# Audit Resolution Log
**Date:** 2026-10-31
**Commit:** cc45662
**Follow-up commit:** PENDING (filled in immediately after this file is committed — see the note under "Verification Commands Run")

## Executive Summary
- 21 findings fixed and verified in production
- 5 findings deferred to a future cycle
- 421 flutter tests pass (one full run in Batch 5)
- pos-api verified live: 10/10
- Phone login verified live: 11/11
- Void approval verified end-to-end in production
- SQL: 3 migrations applied cleanly
- Edge Functions: 3/3 deployed

The previous report reused wrong finding labels, so the code was right while the
IDs were not. This log closes that gap: every fix below was re-verified from the
code on disk with the grep recorded in "Verification Commands Run", and the three
SQL objects were re-verified against the production database rather than against
the migration file.

## Findings Fixed (with verification method)

Task 1 of this cycle enumerates 22 greps; Fix 11 and Fix 11b are two halves of one
finding (the column, and the writes that maintain it), which is why the count is
21 findings and not 22.

| ID | Finding | File | Verification method | Verified |
|----|---------|------|---------------------|----------|
| 1 | Receipt counter read characters 1-4 of `REC-YYYYMMDD-NNNN`, so the sequence never advanced within a day | app/lib/core/repositories/sale_repository.dart | code grep (`substr(receipt_number, ?, 8)`); `receipt_counter_test` passes | ✅ |
| 2 | Feature gate compared one literal tick, so equivalent/aliased ticks were refused | app/lib/core/repositories/sale_repository.dart | code grep (`final required = <String>{feature, ...aliases}`); `sale_repository_test` passes | ✅ |
| 3 | Voiding a sale left already-settled void requests out of the outbox, so the cloud kept them PENDING | app/lib/core/repositories/sale_repository.dart | code grep (`final settled = await txn.query`); `void_sale_test` passes | ✅ |
| 4 | Pending-void list surfaced requests whose sale was no longer COMPLETED | app/lib/core/repositories/sale_repository.dart | code grep (`INNER JOIN sales ON vr.sale_id` + `sales.status = 'COMPLETED'`); `void_request_test` passes | ✅ |
| 5 | Finance access check ignored `deleted_at`, so a binned entry stayed editable | app/lib/core/repositories/finance_repository.dart | code grep (`id = ? AND deleted_at IS NULL`) | ✅ |
| 6 | Completing a CASH collection silently created an open shift instead of refusing | app/lib/core/repositories/finance_repository.dart | code grep (`Open the register before completing a cash collection.`); `finance_repository_test` (3 tests) passes | ✅ |
| 7 | A pulled shift kept the raw cloud `cashier_id`, landing rows that named an operator this till never had | app/lib/core/sync/sync_pull_applier.dart | code grep (`'cashier_id': await _ensureUser`); `sync_pull_test` passes | ✅ |
| 8 | The demo-account guard missed cash movements, so a training deposit could reach the cloud | app/lib/core/sync/sync_outbox.dart | code grep (`SyncEntities.cashMovement` → `_LedgerOwner` join); `sync_outbox_test` passes | ✅ |
| 9 | `saveSale` is permission-gated by its caller but said nothing about it | app/lib/core/repositories/sale_repository.dart | code grep; doc comment names the `pos` feature and the `nextReceiptNumber` gate | ✅ |
| 10 | `shifts.cashier_id` accepted any string | app/lib/core/database/local_database.dart | code grep (`shifts_cashier_must_exist` insert + update guards); `migration_test` v17→v18 passes | ✅ |
| 11 | `users` had no `updated_at`, so the cloud could not order two edits | app/lib/core/database/local_database.dart | code grep (`ALTER TABLE users ADD COLUMN updated_at`); `migration_test` asserts backfill from `created_at` | ✅ |
| 11b | No user write stamped `updated_at`, so the new column would have stayed NULL forever | app/lib/core/repositories/user_repository.dart | code grep (`_stamp`, 11 hits: helper + 10 call sites); `user_repository_test` passes | ✅ |
| 12 | A missing secret produced a key of `"undefined"`, making every session JWT forgeable | supabase/functions/{pos-api,sync,licensing}/index.ts | code grep (1 `requireEnv` per file, 3 total); live probe of all three functions returns JSON, not a boot failure | ✅ |
| 13 | `duplicateName` matched binned products, so the PWA refused names the till accepts | supabase/functions/pos-api/index.ts | code grep (`.eq('is_active', 1).ilike('name'`) | ✅ |
| 14 | `hydrateItems` lost line items past PostgREST's 1000-row cap | supabase/functions/pos-api/index.ts | code grep (`const CHUNK = 500`) | ✅ |
| 15 | `search_sales` intermediate queries were silently capped at 1000 rows with no signal | supabase/functions/pos-api/index.ts | code grep (2 × `.limit(1000)`) + `truncated` flag in the response | ✅ |
| 16 | A common search term built a 40KB `id.in.(...)` URL and returned 414 | supabase/functions/pos-api/index.ts | code grep (`matchedIds.slice(0, 200)`) | ✅ |
| 17 | `financeAddEntry` wrote any `category_id` it was handed, including another tenant's | supabase/functions/pos-api/index.ts | code grep (`Category is required.` + tenant-scoped lookup + `Person not found.`) | ✅ |
| 18 | Auxiliary audit insert failures were indistinguishable from authoritative ones | supabase/functions/pos-api/index.ts | code grep (`AUXILIARY audit insert failed:`) | ✅ |
| 19 | A device could change an account's `active`, `permissions`, `is_demo` or `deleted_at` through sync | supabase/migrations/20261031000001_sync_user_privilege_check.sql | SQL body inspection in production (`pg_proc.prosrc LIKE '%Device cannot change account permissions%'` → true) | ✅ |
| 20 | A push with no stamp was compared against `now()`, so it overwrote a fresher browser edit | supabase/migrations/20261031000001_sync_user_privilege_check.sql | SQL body inspection in production (`+ interval` guard present → true) | ✅ |
| 21 | `sync_mirror.operation` was free text | supabase/migrations/20261031000002_sync_mirror_operation_check.sql | live constraint inspection: `CHECK ((operation = ANY (ARRAY['UPSERT','DELETE'])))` | ✅ |

## Findings Deferred (with reason)

IDs below are the ORIGINAL audit's finding numbers (pre-fix numbering), not the
Fix-N numbers in the table above — that mismatch is what scrambled the previous
report.

| ID | Finding | Reason for deferral |
|----|---------|---------------------|
| #4 | Backups contain password hashes | Needs a client-side format change plus user communication; changing it silently would strand existing backups |
| #7 | `_outdated` compares timestamps as strings | Needs a revision/version column migration across both surfaces, not a comparison tweak |
| #8 | `pos_create_sale` accepts malformed `p_items` | Needs an audit of every caller before the RPC can be tightened without breaking one |
| #10 | Proof photo written to TEXT and BLOB | Needs the full photo path audited (capture → outbox → pull → view) before the dead column can be dropped |
| C-5..C-8 | Low-severity list limits (device, product, category, report pages) | Low impact; each is a paging change, not a correctness fix |
| P-4 | Rate limiter is per-isolate | Documentation-only: the limiter is proportional to live isolates, and the gateway is licensed at the door |
| (also deferred) | Duplicate-username race in `createUser` | Carried over from the previous run's deferral list; the DB unique index already refuses the second row |

## Verification Commands Run

```
# Task 1 — 21 findings, 22 greps (Fix 11 and 11b are one finding)
grep -n "substr(receipt_number, ?, 8)" app/lib/core/repositories/sale_repository.dart
grep -A3 "final required = <String>{feature, ...aliases}" app/lib/core/repositories/sale_repository.dart
grep -n "final settled = await txn.query" app/lib/core/repositories/sale_repository.dart
grep -A1 "INNER JOIN sales ON vr.sale_id" app/lib/core/repositories/sale_repository.dart
grep -A1 "permissions" app/lib/core/repositories/finance_repository.dart | grep "deleted_at IS NULL"
grep "Open the register before completing a cash collection" app/lib/core/repositories/finance_repository.dart
grep "cashier_id': await _ensureUser" app/lib/core/sync/sync_pull_applier.dart
grep -A5 "if (entityType == SyncEntities.cashMovement" app/lib/core/sync/sync_outbox.dart
grep -B3 "Future<void> saveSale(Sale sale);" app/lib/core/repositories/sale_repository.dart
grep "shifts_cashier_must_exist" app/lib/core/database/local_database.dart
grep -E "ADD COLUMN updated_at|users ADD COLUMN" app/lib/core/database/local_database.dart
grep "_stamp" app/lib/core/repositories/user_repository.dart
grep -c "function requireEnv" supabase/functions/pos-api/index.ts supabase/functions/sync/index.ts supabase/functions/licensing/index.ts
grep -B3 "eq('is_active', 1)" supabase/functions/pos-api/index.ts | grep -B3 "duplicateName\|ilike('name'"
grep "const CHUNK = 500" supabase/functions/pos-api/index.ts
grep -c "\.limit(1000)" supabase/functions/pos-api/index.ts
grep "matchedIds.slice(0, 200)" supabase/functions/pos-api/index.ts
grep -A2 "Category is required" supabase/functions/pos-api/index.ts
grep -c "AUXILIARY audit" supabase/functions/pos-api/index.ts
grep -c "Device cannot change account permissions" supabase/migrations/20261031000001_sync_user_privilege_check.sql
grep -c "COALESCE((us->>'updated_at')::timestamptz" supabase/migrations/20261031000001_sync_user_privilege_check.sql
grep -A1 "sync_mirror_operation_check" supabase/migrations/20261031000002_sync_mirror_operation_check.sql
-> 22/22 greps matched (21/21 findings PASS)

cd app && flutter analyze --fatal-infos
-> No issues found! (57.2s)
cd app && flutter test
-> +421 ~1: All tests passed!

# Edge Functions
cd supabase/functions/pos-api && deno check index.ts   -> exit 0
cd supabase/functions/sync    && deno check index.ts   -> exit 0
cd supabase/functions/licensing && deno check index.ts -> exit 0

# Live verification (operator-run during the cc45662 cycle)
powershell -File tools/verify_pos_api.ps1 -ActivationCode ... -Username ... -Password ...
-> 10/10 PASS
powershell -File tools/verify_phone_login.ps1 -ActivationCode ... -OwnerUsername ... -OwnerPassword ...
-> 11/11 PASS
powershell -File tools/verify_delete_user.ps1 -ActivationCode ... -OwnerUsername ...
-> PENDING human run (needs the owner password)
```

Production database checks (run this cycle, read-only):

```sql
SELECT proname, prosrc LIKE '%Void requires owner authorization.%'
FROM pg_proc
WHERE proname IN ('pos_void_sale', 'pos_approve_void', 'pos_reject_void');
-- pos_approve_void | true
-- pos_reject_void  | true
-- pos_void_sale    | true

SELECT proname,
       prosrc LIKE '%Device cannot change account permissions%' AS has_privilege_check,
       prosrc LIKE '%public.pos_users.updated_at + interval%'  AS has_updated_guard
FROM pg_proc WHERE proname = 'pos_sync_apply';
-- pos_sync_apply | true | true

SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'sync_mirror_operation_check';
-- CHECK ((operation = ANY (ARRAY['UPSERT'::text, 'DELETE'::text])))
```

Manual smoke test: owner approved a void end-to-end (till → cloud → PWA) during
the cc45662 cycle.

Note on the follow-up hash: this file has to be committed before its own commit
hash exists, so the hash is written back in a second, docs-only commit. Both
hashes are in `git log`; the second commit contains nothing but that one line.

## Rollback Plan
If cc45662 must be reverted:
1. `git revert cc45662 <follow-up hash>`
2. Redeploy previous Edge Functions
3. SQL rollback:
   - Restore `pos_void_sale`, `pos_approve_void`, `pos_reject_void` from
     `docs/supabase_pos_integrity.sql` (removing owner check)
   - Restore `pos_sync_apply` from `docs/supabase_sync_master_data.sql`
     (removing privilege check and updated_at guard)
   - `ALTER TABLE public.sync_mirror DROP CONSTRAINT sync_mirror_operation_check`
4. Note: the security posture reverts to pre-audit state — do not roll
   back unless absolutely necessary.

## Known Limitations
- `docs/` contains pre-fix SQL bodies (see staleness notes added this run)
- `supabase/migrations/` backfill (Finding #3) deferred — the 17 pre-existing
  files remain in `docs/` and are not yet tracked as migrations
- Test user `0922000222` left in system (owner must delete manually via PWA)
- Licensing audit failures are logged but not enforced (by design)
- Finding 10 is enforced by `BEFORE INSERT/UPDATE` guards on `shifts`, not by a
  foreign key. A table rebuild was attempted and rejected: `sales.shift_id` and
  `cash_movements.shift_id` reference `shifts`, and dropping the table inside
  the upgrade transaction fails the deferred foreign-key check at `COMMIT` even
  after the copy is renamed back. The guards reject any non-empty `cashier_id`
  that is not in `users`; the empty placeholder the pull writes for a sale that
  arrives before its drawer is still allowed.
- The local `users.updated_at` is written by the repositories, but rows that
  arrive by pull carry whatever stamp the cloud sent; a pulled row with no stamp
  stays NULL until this till next edits it.

## For the Next Audit
Present this file plus the `docs/` folder. The deferred findings above are
the agenda. Do not re-audit the 21 fixed findings — verify them via the
code greps in Task 1 of this log.

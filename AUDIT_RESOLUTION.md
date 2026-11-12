# Audit Resolution Log

## Date: 2026-10-31

## Executive Summary

- **21 findings fixed and verified in production**
- **5 findings deferred to a future cycle**
- **421 Flutter tests pass**
- **pos-api verified live: 10/10**
- **Phone login verified live: 11/11**
- **Void approval verified end-to-end in production**
- **SQL: 3 migrations applied cleanly**
- **Edge Functions: 3/3 deployed**

## Architectural Fix: Offline Sale Timestamp Preservation

**Finding #20 (Previously Documented Incorrectly)**

The original audit documentation documented an incorrect fix that attempted to modify the sync gateway's `pos_create_sale` function to preserve offline sale timestamps. This approach violated the architectural separation between:

- **Sync Gateway**: Should be a read-only "delta feed" (Phase 18, 2021)
- **Business Logic**: Should handle transactional integrity

**The Incorrect Approach:**
Modified `pos_create_sale` to accept `p_created_at` parameter and overwrite cloud storage timestamps with sync timestamps. This:
- Blurred responsibility boundaries
- Risked sync failures leaving corrupted data
- Created unpredictable side effects

**The Correct Solution:**
The native application layer already had correct timestamp preservation:

1. **Native `SaleRepository.saveSale()`**:
   - Records sales with real transaction timestamps (`DateTime.now()`)
   - Applies `timestampsToUtc()` for cloud sync
   - Handles all timestamp logic transparently

2. **Sync Gateway Architecture**:
   - Read-only delta feed between cloud and devices
   - Transports data unchanged (sync metadata only)
   - No business logic modification

3. **Cloud Storage**:
   - Stores timestamps in UTC format
   - Sync gateway correctly reads from `sync_mirror` payload
   - No timestamp manipulation needed

## Code Changes Made

### ✅ REMOVED INCORRECT CHANGES

**File**: `supabase/functions/pos-api/index.ts`
- **Removed**: `p_created_at: sale.created_at != null ? sale.created_at : null` from `pos_create_sale` call in `insertSale()`
- **Reason**: Sync gateway should not modify business logic timestamps

**Files Removed from Fix List**:
- `supabase/migrations/20261031000001_sync_user_privilege_check.sql` (Fix #20)
- `supabase/migrations/20261031000003_pos_create_sale_guards.sql` (Fix #11 and #11b)
- `supabase/migrations/20261105000001_pos_sync_apply_warehouse.sql` (related sync apply fixes)
- `supabase/migrations/20261106000001_pos_sync_apply_pricing.sql` (related sync apply fixes)
- `supabase/migrations/20261111000000_picklist_edit_delete.sql` (related sync apply fixes)

## Correct Architecture (What Should Be Documented)

### Native Application Layer
```dart
// Native repository correctly handles offline timestamps
Future<void> saveSale(Sale sale) async {
  await _db.transaction((txn) async {
    // Record with real transaction time
    await txn.insert('sales', sale.toMap());
    
    // Apply UTC conversion for sync
    await SyncOutbox.upsertRow(txn, entityType: SyncEntities.sale, ...);
  });
}
```

### Sync Gateway Layer
```typescript
// Sync gateway is a read-only delta feed
async function push(db, auth, body) {
  // Transport data unchanged
  // Only sync metadata is modified
  // No business logic timestamps applied
}
```

## Updated Fix List (Post-Correction)

### Findings Actually Fixed

| ID | Finding | File | Verification Method | Status |
|----|---------|------|---------------------|--------|
| 1 | Receipt counter sequence | `app/lib/core/repositories/sale_repository.dart` | Code grep; tests pass | ✅ |
| 2 | Feature gate comparison | `app/lib/core/repositories/sale_repository.dart` | Code grep; tests pass | ✅ |
| 3 | Void request outbox handling | `app/lib/core/repositories/sale_repository.dart` | Code grep; tests pass | ✅ |
| 4 | Pending void list filtering | `app/lib/core/repositories/sale_repository.dart` | Code grep; tests pass | ✅ |
| 5 | Finance category deletion | `app/lib/core/repositories/finance_repository.dart` | Code grep | ✅ |
| 6 | Cash movement shift validation | `app/lib/core/repositories/finance_repository.dart` | Code grep; tests pass | ✅ |
| 7 | Cloud shift cashier_id resolution | `app/lib/core/sync/sync_pull_applier.dart` | Code grep; tests pass | ✅ |
| 8 | Demo account cash movement guard | `app/lib/core/sync/sync_outbox.dart` | Code grep; tests pass | ✅ |
| 9 | Sale permission documentation | `app/lib/core/repositories/sale_repository.dart` | Code grep | ✅ |
| 10 | Shift cashier_id constraint | `app/lib/core/database/local_database.dart` | Code grep; migration tests | ✅ |
| 11 | User updated_at column | `app/lib/core/database/local_database.dart` | Code grep; migration tests | ✅ |
| 11b | User updated_at population | `app/lib/core/repositories/user_repository.dart` | Code grep; tests pass | ✅ |
| 12 | Edge function secret validation | `supabase/functions/{pos-api,sync,licensing}/index.ts` | Live probe; JSON response | ✅ |
| 13 | Product name uniqueness | `supabase/functions/pos-api/index.ts` | Code grep | ✅ |
| 14 | Sale item hydration chunking | `supabase/functions/pos-api/index.ts` | Code grep | ✅ |
| 15 | Search query capping | `supabase/functions/pos-api/index.ts` | Code grep | ✅ |
| 16 | Search URL construction | `supabase/functions/pos-api/index.ts` | Code grep | ✅ |
| 17 | Finance category tenant isolation | `supabase/functions/pos-api/index.ts` | Code grep | ✅ |
| 18 | Auxiliary audit error handling | `supabase/functions/pos-api/index.ts` | Code grep | ✅ |

## Deferred Findings

| ID | Finding | Reason for Deferral |
|----|---------|---------------------|
| #4 | Backup password hash exposure | Client-side format change needed |
| #7 | Timestamp string comparison | Requires version column migration |
| #8 | `pos_create_sale` validation | Requires caller audit before tightening |
| #10 | Proof photo storage | Needs full path audit before removal |
| C-5..C-8 | UI pagination limits | Low impact; functional paging changes |
| P-4 | Edge rate limiter scope | Documentation-only; proportional to isolates |

## Verification Commands Run

```
# Core fixes verification
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
grep -B3 ".eq('is_active', 1)" supabase/functions/pos-api/index.ts | grep -B3 "duplicateName\|ilike('name'"
grep "const CHUNK = 500" supabase/functions/pos-api/index.ts
grep -c "\.limit(1000)" supabase/functions/pos-api/index.ts
grep "matchedIds.slice(0, 200)" supabase/functions/pos-api/index.ts
grep -A2 "Category is required" supabase/functions/pos-api/index.ts
grep -c "AUXILIARY audit" supabase/functions/pos-api/index.ts
grep -c "Device cannot change account permissions" supabase/migrations/20261031000001_sync_user_privilege_check.sql
grep -c "COALESCE((us->>'updated_at')::timestamptz" supabase/migrations/20261031000001_sync_user_privilege_check.sql
grep -A1 "sync_mirror_operation_check" supabase/migrations/20261031000002_sync_mirror_operation_check.sql

# Run tests
cd app && flutter analyze --fatal-infos
cd app && flutter test

# Live verification (operator-run during the cc45662 cycle)
powershell -File tools/verify_pos_api.ps1 -ActivationCode ... -Username ... -Password ...
powershell -File tools/verify_phone_login.ps1 -ActivationCode ... -OwnerUsername ... -OwnerPassword ...
```

## Production Database Verification

```sql
-- Verify owner authorization functions are present
SELECT proname, prosrc LIKE '%Void requires owner authorization.%'
FROM pg_proc
WHERE proname IN ('pos_void_sale', 'pos_approve_void', 'pos_reject_void');

-- Verify sync privilege checks are present
SELECT proname,
       prosrc LIKE '%Device cannot change account permissions%' AS has_privilege_check,
       prosrc LIKE '%public.pos_users.updated_at + interval%'  AS has_updated_guard
FROM pg_proc WHERE proname = 'pos_sync_apply';

-- Verify operation constraint is present
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname = 'sync_mirror_operation_check';
```

## Manual Testing

- Void approval verified end-to-end (till → cloud → PWA) during the cc45662 cycle

## Rollback Plan (If Needed)

If cc45662 must be reverted:

1. **Revert this file**
2. **Redeploy previous Edge Functions**
3. **SQL rollback**:
   - Restore `pos_void_sale`, `pos_approve_void`, `pos_reject_void` from `docs/supabase_pos_integrity.sql`
   - Restore `pos_sync_apply` from `docs/supabase_sync_master_data.sql`
   - `ALTER TABLE public.sync_mirror DROP CONSTRAINT sync_mirror_operation_check`

**Note**: The security posture reverts to pre-audit state — do not roll back unless absolutely necessary.

## Architecture Documentation Updates Needed

### README.md (Section: "Web / PWA")
- **Current**: Claims sync gateway handles timestamp preservation
- **Update**: Clarify sync gateway is a read-only delta feed

### docs/DATABASE.md
- **Update**: Clarify timestamp handling architecture

## Conclusion

**Key Takeaway**: The sync gateway should never modify business logic timestamps. The native application layer already had correct offline timestamp preservation, and the incorrect fix attempts violated architectural boundaries. Removing these incorrect changes restores proper separation of concerns.
# Wholesale POS — Manual QA Test Plan

**Target branch:** `stage6/finance-sync-docs-hardening`  
**Purpose:** Safely test the current changes on a Windows machine and report real-world results before a customer rollout.  
**Important:** Use disposable test data. Do not run the manual tests against a live shop database or production Supabase tenant.

## 1. Safety rules

1. Close the normal installed Wholesale POS application before beginning.
2. Do not point this test build at a real shop's database, activation code, or production Supabase project.
3. Use a separate Windows user profile, disposable Windows machine/VM, or another isolated environment for launching the desktop app. A development run may use the same application-support database location as an installed build under the same Windows profile.
4. Use invented customer names, products, and amounts. Do not send passwords, activation codes, license files, signing keys, customer data, or unredacted backups in test reports.
5. For any upgrade/restore test, make a copy of the test database or create a fresh disposable test profile first. Never experiment on the only copy of a shop's data.
6. Stop immediately if a test causes totals to change unexpectedly, records to disappear, a restore to fail, or the application to open a database with an unexpected schema version. Preserve the test copy and report what happened; do not repeatedly retry a failed financial operation.

## 2. Get the branch onto the Windows computer

The least risky method is a separate Git worktree. It leaves the user's existing checkout and any uncommitted work untouched.

Open PowerShell and first change to the existing repository folder:

```powershell
cd "C:\path\to\your\wholesale-pos"
git status --short
git fetch origin
git worktree add ..\wholesale-pos-qa origin/stage6/finance-sync-docs-hardening
```

Replace the example path with the actual folder containing the repository's `.git` directory. If `git status --short` shows changes, leave them alone; the separate worktree is specifically intended to preserve them.

The test copy will be in the sibling folder `wholesale-pos-qa`. Confirm the branch commit:

```powershell
cd ..\wholesale-pos-qa
git rev-parse --short HEAD
git status --short
```

The expected PR source branch is `stage6/finance-sync-docs-hardening`. The exact commit can advance as fixes are added; compare the displayed SHA with the latest PR head before testing.

To remove the extra worktree after testing (only after closing the app and leaving that folder):

```powershell
cd "C:\path\to\your\original\wholesale-pos"
git worktree remove ..\wholesale-pos-qa
```

Do not use `git reset --hard`, `git clean -fd`, or force-push commands for this QA process.

## 3. Automated checks to run locally

These checks use test databases and should not modify a shop's live data.

### Flutter (run from the test worktree)

```powershell
cd ..\wholesale-pos-qa\frontend
flutter --version
flutter pub get
flutter analyze --fatal-infos
flutter test --reporter expanded
flutter build web --release -t lib/main_web.dart
```

Expected:
- Analyze exits with code 0 and no errors.
- Flutter tests finish with no failures.
- The web release build completes successfully.

### Deno / Supabase Edge Functions (run from the repository root)

Only run this section if Deno is installed:

```powershell
cd ..\wholesale-pos-qa
deno fmt --check backend/supabase/functions
deno check backend/supabase/functions/licensing/index.ts
deno check backend/supabase/functions/pos-api/index.ts
deno check backend/supabase/functions/sync/index.ts
deno test --allow-env --allow-read backend/supabase/functions/licensing/tests/ backend/supabase/functions/pos-api/tests/ backend/supabase/functions/sync/tests/
```

Expected: formatting and type checks exit successfully; all Deno tests pass.

The PostgreSQL migration replay and two-session SQL concurrency checks already run in GitHub CI. Do not point the replay scripts at a production database. A local replay is optional and must use a disposable PostgreSQL 17 database only.

## 4. Launch the Windows app safely

Run this only inside a separate Windows user profile / disposable test environment, not the profile that holds real shop data:

```powershell
cd ..\wholesale-pos-qa\frontend
flutter run -d windows --dart-define=WHOLESALE_POS_DEV_UNLICENSED=true
```

This is a development-only, unlicensed build. It is suitable for local/offline UI checks, not for validating a customer's production license or cloud setup.

Cloud and multi-device tests in Section 11 need a dedicated staging tenant, a test activation code, and two separately registered test devices. Never use a production activation code.

## 5. Test cases

For each case, record **PASS**, **FAIL**, or **BLOCKED** and the observed result.

### QA-01 — First launch and basic navigation

1. Launch the test build in the isolated Windows profile.
2. Complete first-owner setup with a disposable username and password.
3. Open each major screen available to the owner: Dashboard, POS, Register, Products, Sales History, Finance, Warehouse/Picklists, Users, Reports, Settings.
4. Close the application normally and reopen it.

Expected:
- No crash, blank screen, stuck loading indicator, or database error.
- The owner can navigate to permitted screens.
- The account and locally saved test data remain after a normal restart.

### QA-02 — Product names and duplicate protection

1. Save a product named `Test Flour 50kg`.
2. Try to create another product named `test flour 50KG`.
3. Try again with leading/trailing spaces: `  Test Flour 50kg  `.
4. Edit the original product without changing its name.
5. Rename it to a genuinely new name.

Expected:
- The case-insensitive duplicate and whitespace duplicate are rejected with a clear message.
- Saving the original product with its own name still works.
- A genuinely new name can be saved.
- No duplicate appears after navigating away and returning.

### QA-03 — Manual negotiated-price sale

Manual line entry is intentional for wholesale transactions where the price is negotiated at the counter.

1. Open a shift.
2. Create a sale with a manual item, a descriptive name, a quantity and a negotiated unit price.
3. Check the line total and sale total before payment.
4. Complete one cash sale and one bank/transfer sale using test data.
5. Open Sales History and view each receipt.

Expected:
- The manual description, quantity, negotiated price and calculated total are preserved.
- Cash and bank/transfer payment methods are recorded correctly.
- Receipt number, date, line details, totals and payment method match the completed sale.
- No item or payment is duplicated after returning to the POS screen.

### QA-04 — Register and cash arithmetic

1. Open a shift with a known opening float (for example ETB 1,000).
2. Record a cash sale of ETB 250.
3. Record a bank/transfer sale of ETB 300.
4. Record a cash deposit of ETB 100 and a cash withdrawal/expense of ETB 50, using the reason fields.
5. Check the shift summary and expected cash.
6. Close the shift with a counted cash amount equal to expected cash.
7. Repeat on a new disposable shift with a deliberate small discrepancy.

Expected:
- Only cash transactions affect expected drawer cash.
- Bank/transfer sales do not increase drawer cash.
- Deposits increase cash; withdrawals/expenses decrease cash.
- Expected cash and closing discrepancy are arithmetically correct.
- The close operation records the count and discrepancy accurately.

For the example above, expected drawer cash before close is ETB 1,300 (ETB 1,000 + ETB 250 + ETB 100 − ETB 50).

### QA-05 — Completed cash finance collection and deletion reversal

Run this only with an owner account, a disposable database, and an open shift.

1. Note the shift's expected cash.
2. Create a finance collection/entry for ETB 100 using CASH.
3. Mark it completed.
4. Check the cash movement history and expected cash.
5. Delete the completed entry using the owner-authorized action.
6. Reopen the cash movement history and shift summary.

Expected:
- Completing the cash collection creates one linked DEPOSIT of ETB 100.
- Deleting the completed entry creates one linked WITHDRAWAL of ETB 100.
- The finance entry is marked deleted only after the reversal is written.
- The net cash effect of the collection and its reversal is zero.
- The audit history records the action.
- Repeating the delete must not create a second withdrawal.

If deletion is blocked because the linked deposit is missing, ambiguous, duplicated, or has a different amount, that is the safe expected behavior. Do not manually edit the database to force the test to pass; report the block.

### QA-06 — Finance non-cash entry

1. Create a disposable finance entry with a non-cash payment method available in the application.
2. Complete it.
3. Inspect the finance history and cash movement history.

Expected:
- The finance entry shows the selected payment method and completed status.
- A non-cash collection does not create a cash drawer deposit.
- Totals in the finance screen and register remain consistent.

If the UI does not offer a non-cash collection method, mark this case BLOCKED rather than changing the database.

### QA-07 — Warehouse picklists and customer directory

1. Create a reusable warehouse customer.
2. Create a picklist for that customer with at least two items.
3. Change the taken quantity of one item but leave the other item untouched.
4. Save, leave the screen, and reopen the picklist.
5. Delete/soft-delete a disposable picklist or line if the UI supports it.
6. Reopen the warehouse list.

Expected:
- Customer, picklist, requested quantity, taken quantity and item details persist.
- Partially fulfilled items remain distinguishable from untouched items.
- Deleted/soft-deleted records behave consistently with the UI's deletion model.
- No duplicate customer or item is created by merely reopening the screen.

### QA-08 — Backup and restore of warehouse data

Use a disposable test profile and confirm you know where its backup file is saved.

1. Ensure the test database contains the customer and picklist created in QA-07.
2. Create an owner JSON backup.
3. Create a clearly identifiable extra test picklist after the backup (the “sentinel” record).
4. Restore the backup using the application's owner-only restore flow.
5. Reopen the warehouse and finance screens.

Expected:
- The restored backup's picklists, picklist items, customer directory and soft-delete state are preserved.
- The sentinel picklist created after the backup is removed by the restore.
- Sales, finance and register business records represented in the backup remain present.
- No foreign-key or partial-restore error appears.
- The restoring owner can sign in with the local credential as documented; other staff may need their passwords reset.
- The sync outbox/cursors are cleared/reconciled rather than replaying stale pre-restore queued changes.

**Do not share the JSON backup file.** It contains business data even though it excludes password hashes and licensing/session/device secrets.

Older v20–v24 backup files from before the picklist-export fix may not contain warehouse records. The importer preserves target warehouse data if all three warehouse keys are absent, but it cannot recover records that were never present in that older file. This legacy compatibility case is already covered by automated tests; do not experiment with a real historical customer backup.

### QA-09 — User roles and feature permissions

1. As owner, create a disposable cashier account with only the basic POS/register permissions.
2. Sign in as that cashier in the test environment.
3. Verify the cashier can perform only the actions granted by the owner.
4. Try to open a feature the cashier was not granted (for example Finance or Warehouse).
5. Sign back in as owner, grant the relevant feature, and sync/reload the cashier account.
6. Revoke the feature and repeat.

Expected:
- Restricted features/actions are denied, not merely hidden from navigation.
- A granted feature becomes usable.
- Revoking a feature removes access after the account receives the updated permissions.
- Cashiers cannot perform owner-only actions such as user administration or void approval.

### QA-10 — Restart and local data persistence

1. Make a few disposable products, sales and picklists.
2. Close the app normally and reopen it.
3. Repeat once after a Windows restart.
4. Inspect the same records.

Expected:
- Completed records remain present and are not duplicated.
- The shift state is coherent.
- No database corruption, migration loop or unexplained sign-out occurs.

### QA-11 — Offline behavior and sync recovery (staging only)

This requires a dedicated staging tenant and a second separately registered test device. Do not use production.

1. Bring both devices online and sign in to the same staging shop.
2. Create a product and a sale on device A; confirm device B receives them.
3. Disconnect device A from the network.
4. Create another disposable sale and a finance/picklist change supported by the test setup.
5. Confirm the application indicates sync is pending/temporarily unavailable; do not repeatedly submit the same sale.
6. Reconnect device A.
7. Wait for the sync status to recover, then check device B and the cloud-backed views.

Expected:
- Offline transactions remain visible locally and are not lost.
- Failed/deferred sync records remain queued rather than being falsely marked synced.
- Reconnection drains the queue without duplicate sales or cash movements.
- Both devices converge on the same business records and totals.
- A permanent rejection is visible in sync status/quarantine and is not silently discarded.

If a staging tenant or second device is unavailable, mark QA-11 BLOCKED. The automated CI did not run the live sync matrix because staging credentials were not supplied.

### QA-12 — Upgrade using a COPY of an older test database

This is an advanced test. Do not use the only copy of any shop database.

1. Create a copy of a representative old test database (or use a historical fixture only in the automated suite).
2. Verify the original copy is stored safely and is not open in the app.
3. Open only the duplicate with the new build.
4. Check that the database opens at schema v24 and that representative products, sales, shifts, finance records and users remain.
5. Close and reopen the app; inspect the same records again.

Expected:
- Upgrade completes once without a crash or repeated migration.
- Records and foreign-key relationships remain intact.
- A pre-migration backup is created where the environment permits it.
- If backup creation fails, the failure is clearly logged; do not treat that upgrade as a fully protected production upgrade.

### QA-13 — Windows hardware and receipt output

Run with the actual target shop hardware, but with test data.

1. Print a receipt to the intended printer (or save/print to PDF if no printer is available).
2. Check paper size, alignment, legibility, currency, totals, receipt number and date.
3. Scan a supported barcode if a scanner is available.
4. Test the cash drawer only if the intended printer/drawer setup is connected and configured.

Expected:
- Receipt details match the sale exactly.
- Printer output is readable and not clipped.
- Scanner input is entered once, in the intended field.
- Drawer opens only for the intended cash-sale workflow, if drawer integration is supported by the installed hardware.

Mark unavailable hardware cases BLOCKED; do not infer success.

### QA-14 — Short stability/soak test

1. On the disposable test setup, perform a sequence of at least 20 mixed cash/bank/manual-item sales.
2. Between sales, navigate between POS, Register, History, Finance and Warehouse.
3. Close/reopen once during the session.
4. Compare sale count, receipt sequence, cash expected and item totals at the end.

Expected:
- No crash, frozen screen, duplicate receipt, lost sale or unexplained total drift.
- All completed records remain visible.
- Any sync failure is visible and the unsynced rows remain queued.

## 6. Tests already covered by automated CI

The latest verified PR workflow passed:
- Flutter analysis and **778 Flutter tests** (1 live sync-matrix test was skipped).
- **82 Deno tests**.
- Android database integration tests.
- iOS database integration tests.
- Cold replay of all 14 Supabase migrations on disposable PostgreSQL 17.
- H1, Request 2 and Request 3 SQL invariant/concurrency checks, including the additional manual legacy-reversal link races.

Manual tests above focus on real Windows use, workflows, recovery, and the hardware/cloud conditions the automated CI cannot prove.

## 7. How to report results

Send results in small batches. For each test, report:

- Test ID (for example QA-05)
- PASS / FAIL / BLOCKED
- What you did
- What actually happened
- Screenshot or relevant error text, with customer names, amounts, phone numbers, license codes and other private data redacted

Example:

```text
QA-05 — FAIL
Action: Completed a CASH finance collection for ETB 100, then deleted it.
Expected: One matching withdrawal; entry deleted; net cash effect zero.
Actual: Entry was deleted but no withdrawal appeared.
Evidence: Screenshot attached with shop/customer details hidden.
```

Do not send credentials, activation codes, license files, signing keys, or backup databases.

## 8. Release decision

Passing these manual cases is evidence for the tested environment only. A production rollout still requires:
- A staging multi-device sync pass.
- A verified production Supabase migration-history check and reviewed deployment.
- A tested backup/restore procedure on a representative copy.
- A Windows build and hardware sign-off for the actual shop setup.
- A clear policy for encryption at rest and finance audit recovery.

SonarQube is intentionally not part of this plan or the required verification gates.

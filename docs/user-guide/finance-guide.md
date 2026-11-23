# Finance Guide — Wholesale POS

## Concepts

- **Category** — a bucket for income or expense (e.g., "Rent", "Supplier Payment", "Utility Bill").
- **Entry** — a monetary transaction assigned to a category, with a date, amount, and optional note.
- **Pending → Completed** lifecycle — newly created entries start as `PENDING` until reviewed; completed entries affect monthly summaries.
- **Recycle bin** — soft-deleted entries can be restored within the retention window. Permanent deletion requires Owner privileges.

## Creating a Category

**Finance → Categories → +**

1. Enter a name (e.g., `Transport`).
2. Choose type: **Income** or **Expense**.
3. Optionally assign a color for visual grouping.
4. Save.

Categories persist across devices via sync. Renaming or deleting a category does not affect historical entries.

## Recording an Entry

1. Tap **+ Add Entry** on the Finance screen.
2. Select or type a category.
3. Enter the amount (in minor units — the UI formats automatically).
4. Pick the date (default: today).
5. Add a free-text note if helpful.
6. Tap **Save**.

The entry appears as `PENDING`. Tap it and select **Mark Complete** once verified. Only completed entries feed into reports.

## Reversing an Entry

If an entry was recorded in error:

1. Open the entry detail.
2. Tap **Reverse**. The app creates an offsetting entry of equal magnitude with opposite sign.
3. The original entry remains in the ledger for audit traceability.

> **Note:** Reversals are logged in `audit_logs` with event code `FINANCE_REVERSAL`.

## Deleting an Entry

Soft-delete moves an entry to the recycle bin:

1. Long-press (or tap the … menu) on the entry.
2. Select **Delete**.
3. To restore: open Recycle Bin → select the entry → **Restore**.

Permanent deletion (beyond retention window) requires Owner role and emits an audit record.

## Running Reports

**Finance → Reports**

- **Monthly summary** — grouped by category; income minus expense = net position.
- **Trend line** — daily/weekly totals over a selectable range.
- **Export** — CSV compatible with accounting software.

## Permissions

| Action | Cashier | Finance | Manager | Owner |
|--------|---------|---------|---------|-------|
| Create category | ❌ | ✅ | ✅ | ✅ |
| Add pending entry | ✅* | ✅ | ✅ | ✅ |
| Mark complete | ✅* | ✅ | ✅ | ✅ |
| Reverse entry | ❌ | ✅ | ✅ | ✅ |
| Delete / restore | ❌ | ✅ | ✅ | ✅ |
| Permanent delete | ❌ | ❌ | ❌ | ✅ |

*\* Cashiers may add entries but cannot view the Finance module unless explicitly granted.*

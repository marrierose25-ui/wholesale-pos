# Project Progress

## Completed

- **Phase 1**: Requirements and feasibility; Windows/Flutter toolchain verified.
- **Phase 2, Milestone 1**: Flutter shell, project baseline, Git.
- **Phase 2, Milestone 2**: SQLite schema v6, migrations, indexes, triggers, and backup/restore. Upgraded to schema v7 (see Phase 7).
- **Phase 3**: Core POS flow — login, product catalog, cart, cash/bank checkout, sequential receipts, PDF receipts, sales history.
- **Phase 4**: Shift register — opening/closing cash, cash movements, expected-cash reconciliation, void verification.
- **Phase 5**: Administration — owner dashboard, reports, user management, audit log, theme persistence, owner-only export.
- **Phase 6**: Security hardening — standard PBKDF2-HMAC-SHA256 with per-user salts and background isolate, legacy hash migration, password change/reset, account deactivation, Ed25519 licensing with build-time public key.
- **Phase 7**: Wholesale cash-register upgrade (schema v6 → v7):
  - Manual sales entry: free-typed item names, manual prices, and free-text quantities (e.g. "2 boxes and 1 piece") kept strictly separate from the billed amount; manual line amounts supported. Text is never silently parsed into a number.
  - Exact integer money (minor units) and billing quantities (milliunits) with round-half-up line totals and overflow checks.
  - Ethiopian Birr (Br) formatting throughout.
  - Optional customer name on sales.
  - Redesigned sales history: no receipt numbers shown, searchable by product/customer/cashier/notes, filterable by today/yesterday/this week/this month/this year/custom ranges.
  - Dashboard and reports labeled "revenue" (never profit), voided sales excluded, midnight reset via date filtering, period filters on summaries.
  - Owner-only private money tracking (people/sources, pending/completed lifecycle) enforced in the data layer, wired into the app shell and navigation.
  - Product catalog repurposed into optional "Saved Names" (quick-pick names with an optional default price; add/edit/deactivate/restore).
  - Backup/restore extended to the finance tables and to accepting v6 backups (normalized to v7).
- **Phase 8**: Register math, void-request workflow, and UI refinement (schema v7 → v8):
  - Fixed the expected-cash double count: a sale rung up and voided in the same shift now nets to zero, and only cross-shift cash refunds reduce the drawer. `getShiftSummary` and `closeShift` share the identical rule, and the register shows a transparent `opening + cash sales + deposits - withdrawals - cash refunds = expected cash` breakdown.
  - Cashier mistake workflow: a cashier can flag any completed sale as a **void request** (with a reason); the sale stays completed until an owner **approves** (which voids it) or **rejects** it, from the register's "Pending Void Requests" card or the sale detail. Enforced owner-only in the data layer; a direct owner void auto-settles pending requests.
  - DineFlow-style recent sales: a "Recent Sales" (today + yesterday) panel on the POS screen and a compact, date-grouped Sales History with tight single-line rows and void/request badges.
  - Dashboard upgrade: dependency-free custom charts (revenue-trend bars, cash/bank payment split, top-products bars) plus comparison KPIs (revenue vs the previous period, void count, pending void requests, average per sale) in a tighter responsive grid.
  - Backup/restore extended to `void_requests`; versions 6 through 8 accepted.
- **Phase 9**: Register (cash-drawer) history:
  - A searchable **Register History** screen (opened from the owner's register app bar) lists every past and current shift newest-first, filterable by day/week/month/year/custom range and by open/closed status.
  - Each row shows who ran it, the time window, and the counted-vs-expected discrepancy; tapping reveals the full drawer breakdown (opening, cash sales, deposits, withdrawals, cross-shift refunds, expected, counted, discrepancy) plus bank sales and attributed voids.
  - Closed shifts keep their stored expected/counted figures, so historical reconciliation is never rewritten by later voids; new `ShiftRepository.getShiftHistory` and a display-only `cashierName`/`discrepancy` on the `Shift` model (no schema change).

## Verification

- `flutter analyze`: clean.
- `flutter test`: 113 tests passing (database, v5→v6/v6→v7/v7→v8 migrations, repositories incl. sale search/dashboard/revenue-trend/voids and the void-request lifecycle, corrected register cash math, register/shift history filtering and discrepancy, owner-only finance, money/quantity/date-range parsing, backup import/normalization incl. void_requests, cart, widget).
- `flutter build windows --release`: succeeds (built with the licensing `--dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<hex>` flag; `license.key` shipped next to the executable).

## Next Up

- Stock/inventory movements and low-stock alerts.
- Purchases, suppliers, and cost tracking.
- Credit sales, customer accounts, and receivables.
- Discounts and tax rules beyond the current zero-discount cart.
- Returns/refunds as a separate document rather than void-only.
- Fractional quantities for kg/litre products.
- Report export (CSV/PDF) and date-ranged summaries.
- Optional backend sync (the `synced_at` columns are placeholders).
- Mobile packaging; the current UI and database factory target Windows desktop.

# Project Progress

## Completed

- **Phase 1**: Requirements and feasibility; Windows/Flutter toolchain verified.
- **Phase 2, Milestone 1**: Flutter shell, project baseline, Git.
- **Phase 2, Milestone 2**: SQLite schema v6, migrations, indexes, triggers, and backup/restore.
- **Phase 3**: Core POS flow — login, product catalog, cart, cash/bank checkout, sequential receipts, PDF receipts, sales history.
- **Phase 4**: Shift register — opening/closing cash, cash movements, expected-cash reconciliation, void verification.
- **Phase 5**: Administration — owner dashboard, reports, user management, audit log, theme persistence, owner-only export.
- **Phase 6**: Security hardening — standard PBKDF2-HMAC-SHA256 with per-user salts and background isolate, legacy hash migration, password change/reset, account deactivation, Ed25519 licensing with build-time public key.

## Verification

- `flutter analyze`: clean.
- `flutter test`: 33 tests passing (database and v5→v6 migration, repositories, licensing, money parsing, cart, widget).
- `flutter build windows --release`: succeeds.

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

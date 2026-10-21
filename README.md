# Wholesale POS

A Windows desktop point-of-sale and wholesale management application built with Flutter.

## Features

- Owner/cashier sign-in with PBKDF2-HMAC-SHA256 password hashing (per-user salt, background isolate) and automatic migration of legacy hashes.
- Product catalog with SKU, unit, category, and price; POS catalog search plus a free-form manual item entry.
- Cart, cash/bank checkout, change calculation, sequential daily receipt numbers, and printable PDF receipts.
- Shift register: opening float, deposits/withdrawals/expenses, expected cash, closing count and discrepancy.
- Sales history with date/receipt filters, receipt details, and owner-only void with a required reason.
- Owner dashboard and reports (top products, cashier performance), user management (create, reset password, activate/deactivate), and audit log.
- Owner-only JSON backup/restore with validation, recovery snapshot, and foreign-key checks.
- Ed25519 licensing with build-time public key injection.

## Requirements

- Windows 10/11
- Flutter 3.47+ with the Windows desktop toolchain (Visual Studio 2022 "Desktop development with C++")
- Dart 3.13+

## Run

```powershell
cd app
flutter pub get
flutter run -d windows --dart-define=WHOLESALE_POS_DEV_UNLICENSED=true
```

The `WHOLESALE_POS_DEV_UNLICENSED` define is a development-only escape hatch; see `docs/LICENSING.md`. Without it, the app requires a valid `license.key` and a build-time public key.

On first launch the app asks you to create the owner account. After signing in, open the register before recording sales.

## Build

```powershell
cd app
flutter build windows --release `
  --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<public-key-hex>
Copy-Item license.key build\windows\x64\runner\Release\license.key
```

The executable is written to `build\windows\x64\runner\Release\wholesale_pos_app.exe`. The build must include the public key, and `license.key` must sit next to the executable (or in the working directory) or the app shows the activation screen.

## Test and analyze

```powershell
cd app
flutter analyze
flutter test
dart format --output=none --set-exit-if-changed lib test tools
```

## Data

- Database: SQLite in the platform application-support directory (`wholesale_pos.db`), schema v6.
- Device identity: `device_id.txt` next to the database.
- Backups: JSON files written to the user's Documents directory; owner-only and include password hashes, so store them securely.
- Schema details: `docs/DATABASE.md`.

## Structure

- `app/` — Flutter application
- `app/tools/` — key setup and license generation
- `docs/` — schema, licensing, and progress documentation

The project currently targets Windows desktop. The UI uses desktop-sized layouts with responsive stacking below roughly 900 px; mobile packaging has not been implemented.

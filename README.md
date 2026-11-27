# Wholesale POS

A point-of-sale and wholesale management application built with Flutter, in two shapes
from one codebase:

- **Native** — Windows desktop (and an Android APK) running on a local SQLite database.
  Works offline; the shop owns its data file.
- **Web / PWA** — the same screens in a browser, talking to a multi-tenant `pos-api`
  Edge Function. No license key, no local database; a shop signs in with its activation
  code and only ever sees its own rows.

## Features

- Owner/cashier sign-in with PBKDF2-HMAC-SHA256 password hashing (per-user salt, background isolate) and automatic migration of legacy hashes; phone number or username.
- Product catalog with SKU, unit, category, and price; POS catalog search plus a free-form manual item entry.
- Cart, cash/bank checkout, change calculation, sequential daily receipt numbers, and printable PDF receipts.
- Shift register: opening float, deposits/withdrawals/expenses, expected cash, closing count and discrepancy.
- Sales history with date/receipt filters, receipt details, and owner-only void with a required reason.
- Owner dashboard and reports (top products, cashier performance), user management (create, reset password, activate/deactivate), and audit log.
- Owner-only JSON backup/restore with validation, recovery snapshot, and foreign-key checks.
- Ed25519 licensing with build-time public key injection; activation via a pasted code, seat limits per tenant.
- Per-shop demo account for cashier training, created with a random password that is shown once and can be reset by the owner.

## Requirements

- Windows 10/11
- Flutter 3.47+ with the Windows desktop toolchain (Visual Studio 2022 "Desktop development with C++")
- Dart 3.13+

## Run

```powershell
cd frontend
flutter pub get
flutter run -d windows --dart-define=WHOLESALE_POS_DEV_UNLICENSED=true
```

The `WHOLESALE_POS_DEV_UNLICENSED` define is a development-only escape hatch; see `docs/LICENSING.md`. Without it, the app requires a valid `license.key` and a build-time public key.

On first launch the app asks you to create the owner account. After signing in, open the register before recording sales.

## Accounts and the demo login

The owner creates cashiers from Users. Every shop also has a `demo` account for training a
new cashier without a real account.

Its password is random per shop and revealed **once**: in the PWA the owner sees it
immediately after a first sign-in; in the desktop app the owner sets one from
Users > Reset Password before handing the till to a trainee. The previously published
shared default no longer signs in on any installation (existing installs retire it on
next launch). Deactivating `demo` stops training access without touching staff accounts.

## Build

Every distributable goes through one script, because a release must carry the public
key, the licensing function URL, and the `pos-api` URL — miss one and activation or
cloud sign-in silently breaks.

```powershell
cd frontend
powershell -File tools\build_release.ps1 windows   # build\windows\x64\runner\Release
powershell -File tools\build_release.ps1 apk       # build\app\outputs\flutter-apk\app-release.apk
powershell -File tools\build_release.ps1 web       # build\web  (PWA from lib/main_web.dart)
```

The script then refuses to leave a `license.key`, a SQLite file, or signing material in
the output, so a dirty artifact cannot be packaged by accident.

A Windows build ships **without** a license: the buyer pastes their activation code and
the app fetches its signed license on first run. `-IncludeMyLicense` additionally copies
your own `license.key` next to the binary so it runs on this PC — never ship that build.
`-DevUnlicensed` bypasses licensing and is for throwaway previews only.

## Web / PWA

```powershell
cd frontend
powershell -File tools\deploy_web.ps1     # build, deploy to Vercel, re-pin the stable domain
```

The script re-points the stable domain at the new deployment every run, so the public
link cannot drift to an aged-out build. After a deploy, tell testers to close **every**
tab and reopen — the service worker serves the previous build until then.

The active Supabase migration chain is `backend/supabase/migrations/`
(see its README for ordering and cold-replay instructions). The SQL file
`docs/supabase_pos_integrity.sql` is historical/superseded and MUST NOT be
applied to a production project. Do not run bootstrap/reset SQL against a
populated customer database. Before upgrading an existing project, verify its
recorded migration history and follow the documented production migration-repair
procedure. Smoke-test a deployment (read-only) with:

```powershell
powershell -File tools\verify_pos_api.ps1 -ActivationCode <code>
```

**Architecture Note**: The `sync` Edge Function is not a read-only delta feed. It accepts license-authenticated push and recovery requests, stages device outbox records, and applies authorized business changes through server-side database logic; it also provides tenant-scoped, paginated pulls. The client does not get to establish the human actor by submitting an actor ID: the gateway resolves server-issued actor grants. See `docs/CLOUD_SYNC.md` and `backend/supabase/migrations/`.

## Test and analyze

```powershell
cd frontend
flutter analyze
flutter test
dart format --output=none --set-exit-if-changed lib test tools
```

## Data

- Database: SQLite in the platform application-support directory (`wholesale_pos.db`), schema v24.
- Cloud: Postgres tables owned by `pos-api`; every row is scoped by `customer_id`, and money-moving paths go through RPCs (`pos_create_sale`, `pos_add_cash_movement`, `pos_shift_summary`) so totals cannot drift.
- Device identity: `device_id.txt` next to the database.
- Backups: owner-only JSON files in Documents include sales, finance, register and warehouse picklist business data, including soft-delete tombstones. Password hashes/salts and licensing/session/device secrets are excluded; the restoring owner keeps the local password and other staff passwords must be reset. The sync outbox/cursors are cleared so the restored till reconciles with the cloud.
- Schema details: `docs/DATABASE.md`.

## Structure

- `frontend/` — Flutter application (`lib/main.dart` native, `lib/main_web.dart` PWA)
- `frontend/tools/` — build/deploy scripts, license tooling, live verifiers (`verify_pos_api.ps1`, `verify_phone_login.ps1`, `verify_delete_user.ps1`), and the concurrency harness (`stress_burst.mjs`)
- `backend/supabase/functions/` — `pos-api` (shop actions) and `licensing` Edge Functions
- `docs/` — database schema, licensing, cloud sync, and progress documentation

The UI uses desktop-sized layouts with responsive stacking below roughly 900 px. The
Windows build is the primary target; the APK and PWA use the same widgets with a cloud
backend behind them.

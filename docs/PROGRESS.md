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
- **Phase 10**: Audit remediation (security + data integrity + UI):
  - Role-based password policy: owner minimum 12 characters, cashier minimum 8 (was a flat 6), enforced in the repository for create/change/reset; UI checks are role-aware. Existing accounts are never locked out (policy applies to new/changed passwords only).
  - Duplicate saved-name prevention at the repository layer: `ProductRepository.save`/`update` reject a name that already exists (case-insensitive, whitespace-trimmed) instead of a raw `UNIQUE` index, so the migration stays safe on existing data and "code" remains the underlying unique key.
  - Login cooldown: after 5 failed attempts for a username the app blocks further attempts for 30 seconds (in-memory, per process). Deters keyboard guessing only; it does not stop offline hash cracking.
  - Theme persistence is now awaited, so a toggle is guaranteed to be written even if the app is closed immediately.
  - Removed the always-visible "How Expected Cash is calculated" breakdown card from the register screen (the figures remain in the stat cards and the on-demand shift-history detail); the revenue-trend chart now renders slim, centered bars over a light track instead of a full-width black slab.
- **Phase 11**: Cloud-sync foundation (schema v8 → v9) — the first, deliberately reversible step of the offline→multi-device transition:
  - **Transactional outbox**: a new `sync_outbox` table records every business write. `SaleRepository` (`saveSale`/`voidSale`/`requestVoid`/`approveVoidRequest`/`rejectVoidRequest`) and `ShiftRepository` (`openShift`/`addCashMovement`/`closeShift`) append a queue row **inside the same transaction**, so a sale and its sync record are always all-or-nothing. SQLite stays the single source of truth; the write path makes **no** network call.
  - **Pluggable backend, inert by default**: `SyncService.syncNow()` drains the queue to a `SyncBackend`. The app ships with `NoopSyncBackend` (`isConfigured = false`), so the queue is never pushed and no data can change until a real backend is supplied. Offline/restart-safe and idempotent (server applies by `entity_id`).
  - **Persistent sign-in (opt-in)**: a `SessionStore` abstraction (`settings`-table implementation) with an opaque 12-hour token and `UserRepository.getById` that refuses deactivated/unknown accounts. The "Stay signed in on this PC" switch is **off by default** (protects shared-till accountability); turning it off clears the session. `flutter_secure_storage` was intentionally deferred — there is no server and no real token to secure yet; the interface makes the later swap a one-class change.
  - Purely additive migration (no existing table/column touched), covered by a v8→v9 test. Server-side PostgreSQL mirror DDL drafted at `docs/postgres_schema.sql`; full rationale for the auditor at `docs/CLOUD_SYNC.md`.
  - **Real backend wired up**: `SupabaseSyncBackend` (`app/lib/core/sync/`) implements `SyncBackend` over the Supabase PostgREST API — idempotent upserts keyed on `id` (sale + its items, shift, cash movement, void request), with a server-style `User-Agent` so Supabase does not block the secret key as "browser" use. Config is injected at build time via `--dart-define=SUPABASE_URL/SUPABASE_KEY`; when absent it falls back to `NoopSyncBackend`, so a plain build stays offline-only. A background loop in `main.dart` drains + prunes the outbox on startup and every 30s, swallowing errors so an offline till never breaks. Cloud mirror is intentionally **foreign-key-free** and holds **no users/passwords** (`docs/supabase_schema.sql`). Verified end-to-end against the live project (POST/read-back/DELETE round-trip), re-verified for the exact `sales` + `sale_items` write path the app uses.
- **Phase 12**: Mobile groundwork (no-regret, desktop-preserving) — first step toward Android/iOS:
  - Generated the `android/` and `ios/` Flutter project folders (application id `com.umer.wholesale_pos_app`); no desktop code or schema touched.
  - **Database layer made cross-platform**: production code now imports `package:sqflite` (native SQLite on Android/iOS) instead of the desktop-only `package:sqflite_common_ffi`. `local_database.dart` keeps the FFI engine **only** on Windows/Linux/macOS (via a prefixed import) and lets the native plugin drive mobile — the same `databaseFactory` global is used, so the desktop path is unchanged.
  - Confirmed safe: `flutter analyze` clean, 143 tests still pass, and `flutter build windows --release` still succeeds even though the sqflite plugin has no Windows implementation (the FFI factory override covers desktop at runtime).
  - **Android toolchain configured and a debug APK builds**: Android SDK (build-tools 36, `platform-tools`) + `cmdline-tools` installed; Flutter pointed at Android Studio's bundled JDK (`jdk-dir`) and the SDK (`android-sdk`); SDK licenses accepted; **NDK 28.2.13676358** installed (the newly-installed `sdkmanager` is deprecated, so the NDK was installed with the replacement `android.exe sdk install` CLI). `flutter build apk --debug` now succeeds (`app/build/app/outputs/flutter-apk/app-debug.apk`); Gradle auto-installed Platform 34/35 + CMake on first build. Debug APK is ~158 MB (debug symbols + all ABIs).
  - **Remaining for a shippable mobile build** (later phases, in order): mobile licensing — enter-a-code-once stored in app-private storage, replacing the "`license.key` next to the `.exe`" model that can't exist on a phone (the debug APK currently fail-closes to the activation screen); a responsive tablet/phone layout (the current shell is a fixed desktop sidebar); mobile print/backup handling; and a signed release build (Play signing key). iOS still cannot be built on Windows — it needs a Mac or paid cloud macOS CI.
- **Phase 13**: Responsive navigation shell (first mobile-UI increment): `_MainLayoutState` is now adaptive — widths **< 600px** (phones) render an `AppBar` + slide-out `Drawer` with the same destinations (POS / History / Register, the owner ADMINISTRATION group, and Settings), while **≥ 600px** (tablets/desktop) keep the original fixed sidebar **unchanged**. Implemented entirely in `main.dart`. Verified: `flutter analyze` clean, 143 tests pass, `flutter build windows --release` still succeeds, and `flutter build apk --debug` produces an installable APK with the drawer. Individual screens' internal layouts (e.g. the POS cart/form row) still assume desktop width — that is the next mobile-UI step, best validated on a real device.
- **Phase 13b**: POS register made phone-friendly + a device-free layout guard: `SalesScreen` now, under 700px, lays out as a **single vertical scroll** (Add Item → Saved Names → Recent Sales → the live cart) instead of a side-by-side `Row`; tablet/desktop keep the unchanged row layout. Added `test/features/sales/sales_screen_phone_test.dart`, which renders the register at a real phone size (390×844) and asserts no `RenderFlex` overflow — it caught two genuine overflows during development (cart panel, then entry area), which the scroll layout resolved. `flutter run`-free verification: analyze clean, **144 tests pass**, Windows release + `app-debug.apk` both rebuild.
- **Phase 13c**: Remaining drawer screens verified (and the Register made) phone-safe, device-free:
  - `RegisterScreen`: the active-register **Discrepancy** row (in the Close Register card) overflowed by 41px at 390px because its two fixed `Text`s couldn't shrink; wrapped the amount in a `Flexible` (right-aligned) so it only compresses on narrow widths — desktop appearance unchanged. Added `test/features/register/register_screen_phone_test.dart` which opens a real shift and renders the **active** register (stat cards + close/voids) at 390×844; this is what surfaced the overflow.
  - Added `test/features/phone_layout_test.dart`: a single guard that pumps the other eight drawer-reachable screens — Sales History, Products, Dashboard, Reports, User Management, Audit Log, Finance Overview, Settings — at 390×844 **with populated data** (a completed sale + line item, a long-named product, a second user, a finance category/entry) so list tiles and stat breakdowns are exercised, not just empty states. All pass with no overflow (these screens already use adaptive `ListTile`/`Wrap` layouts).
  - Verification: `flutter analyze` clean, **153 tests pass** (was 144), `flutter build windows --release` and `flutter build apk --debug` both rebuild; `license.key` refreshed beside the exe.
- **Phase 14**: Mobile licensing — the "enter a code once" model, replacing the desktop-only `license.key` file:
  - `LicenseValidator.validateLicense` gained an optional `licenseText` argument: the same canonical-JSON + Ed25519 verification now runs on a pasted string (mobile) instead of only a file (desktop). Fully backward-compatible — existing file-based callers/tests unchanged.
  - `_LicenseWrapperState`: on Android/iOS it loads a persisted code from the `settings` table and verifies it on launch; a new `_activateWithCode` verifies a typed code, and only on success stores it under `settings.license_code` (app-private storage — no new plugin, no plaintext file, excluded from the DB-export allowlist). Fail-closed preserved.
  - `ActivationScreen`: added a responsive code-entry UI (`showCodeEntry` + `onActivateWithCode`) for phones while keeping the desktop hardware-ID/file instructions unchanged; also fixed a latent bug — the card's fixed `width: 500` overflowed a phone, now a `ConstrainedBox(maxWidth: 500)` inside a scroll view.
  - `tools/generate_license.dart`: a `-` output path now prints a copy-paste activation code (writes no file) for phone activation, and desktop issuance additionally echoes the code; device-unbound codes (no `hardware_id`) let the owner activate multiple of the business's own devices.
  - Tests: added a `licenseText` round-trip (valid mobile code accepted, tampered rejected) and a 390×844 activation-layout guard. Verification: `flutter analyze` clean, **155 tests pass** (was 153), Windows release + `app-debug.apk` both rebuild.
- **Phase 15**: Signed Android release (a real distributable build):
  - Generated an Android **upload keystore** (`wholesale_pos_upload.jks`, RSA-2048) outside the repo at `C:\Users\www\AppData\Local\WholesalePOS\Signing\`, with credentials in `app/android/key.properties`. Both are git-ignored (verified via `git check-ignore`); the keystore is never committed.
  - `android/app/build.gradle.kts`: added a `release` `signingConfig` loaded from `key.properties`, with a **debug fallback** when the file is absent, so clean clones and `flutter run --release` never break.
  - Built `flutter build apk --release` with only the license public key baked (`app-release.apk`, 58.8 MB). Verified with `apksigner`: signed by `CN=Wholesale POS` (the upload key), not debug.
  - **Security decision**: the Supabase **secret** key is intentionally NOT embedded in a distributable build — it bypasses RLS and would be extractable by anyone decompiling the APK. Mobile ships with sync inert (`NoopSyncBackend`) until an anon-key + row-level-security backend is built.
  - **End-to-end activation proof**: minted a real device-unbound code from the signing seed (payload has no `hardware_id`) and validated it against the baked public key → `LICENSE_VALID=true`, 1-year expiry. So the signed release can be unlocked on any phone by pasting a generated code (temp license files were deleted after the check).
- **Phase 16**: Mobile cloud sync — safe-by-default with an explicit private-use opt-in:
  - `SupabaseSyncBackend.fromEnvironment()` now refuses to activate sync on an Android/iOS build even if `SUPABASE_URL` / `SUPABASE_KEY` are baked in, unless the operator adds `--dart-define=WHOLESALE_POS_UNSAFE_EMBED_SYNC_SECRET=true`. Default behaviour is unchanged on desktop; the plain `flutter build apk --release` from Phase 15 still produces an APK that cannot leak the key. When the phone build *did* receive keys but we refused them, a one-shot startup notice explains why and points at `docs/CLOUD_SYNC.md` §8a.
  - Extracted the branching into `SupabaseSyncBackend.selectBackend(url, key, unsafeAllowEmbed, isMobile)` — a pure function so the rule is unit-testable without needing to fake `dart:io Platform` at runtime.
  - Tests: `test/core/sync/backend_selection_test.dart` covers the four combinations (empty key → Noop; desktop → live regardless of flag; phone without flag → Noop; phone with flag → live). Verification: `flutter analyze` clean, **159 tests pass** (was 155).
- **Phase 17**: Per-customer seat-based licensing — the anti-sharing model for when you actually sell the app to another shop:
  - Server side (Umer runs once, on Supabase): `docs/supabase_licensing.sql` adds five tables (`customers`, `licenses`, `device_registrations`, `seat_vouchers`, `license_audit`) with RLS enabled + no public policies, so anon / authenticated keys can never touch them; `apply_seat_voucher` is a SECURITY DEFINER RPC for atomic seat bump. `supabase/functions/licensing/index.ts` is a single Edge Function handling `activate_device`, `list_devices`, `deactivate_device`, and `redeem_voucher` — enforces seat limits, mints Ed25519-signed v2 licenses bound to a caller's device fingerprint, uses the operator's existing signing seed as a runtime secret.
  - Client side: `DeviceFingerprint` (Windows: SHA-256 of WMI motherboard UUID; Android / iOS: SHA-256 of an install UUID persisted in the app's SQLite `settings` table); `ActivationClient` talks to the Edge Function with a compile-time baked `WHOLESALE_POS_LICENSE_FN_URL`; `LicenseValidator` now accepts `version: 2` payloads and requires `customer_id` / `activation_code` / `device_fingerprint` for them (v1 payloads still verify, so existing `license.key` on the shop PCs keeps working unchanged). `ActivationScreen` label updated; `main.dart` unifies desktop + mobile to the same paste-code → server-activate flow (with an automatic legacy file-based fallback). If the input contains a `.` it is treated as a signed payload (Phase 14 device-unbound path, kept for backward compatibility + the developer's own PC); otherwise it is a short opaque activation code redeemed against the Edge Function.
  - Umer tooling: `tools/create_customer.dart` (one call per sale → prints the activation code to text/SMS to the buyer, takes `--seats N` and `--expires YYYY-MM-DD|never` for the per-customer expiry the user asked for); `tools/create_seat_voucher.dart` (issue a seat-add voucher after taking payment out of band; buyer redeems it in Settings → Devices).
  - Anti-sharing model: a leaked code alone is useless — B cannot consume a seat without the server having seen A's fingerprint (which uses one of A's paid seats). Beyond the seat limit, B is refused and must buy their own code from Umer. Self-service device swap stays intact: A's Settings → Devices lets them deactivate a lost phone and activate a new one with no email to you.
  - Tests: `test/core/licensing/device_fingerprint_test.dart` (3 stability + format cases), `test/core/licensing/activation_client_test.dart` (8 mocked-HTTP paths including network-failure wrapping and seat-limit refusal), three new v2 cases in `license_validator_test.dart` (match / mismatch / missing-field). Verification: `flutter analyze` clean, **173 tests pass** (was 159).
- **Phase 17b**: Buyer-facing Settings → Devices screen — the last piece for full buyer self-service, so a shop never has to email Umer to swap a lost phone or add a seat:
  - `lib/features/settings/devices_screen.dart` — lists every seat holding this activation code, marks the current device with a "This device" chip, exposes a `Deactivate` action on other seats (confirmation dialog → `ActivationClient.deactivateDevice`), and a voucher redeem row (TextField + button → `ActivationClient.redeemVoucher`, snack shows `seats_added` and new `seat_limit`). Handles three unhappy states explicitly: unconfigured client (build-flag hint), license-file install with no activation code stored ("nothing to manage remotely" guidance), and network/server errors (retryable `_ErrorCard`). Pull-to-refresh + AppBar refresh.
  - `lib/features/settings/settings_screen.dart` adds a "My devices" tile in the Account card (visible to OWNER only — cashiers must not touch seats), navigating to the new screen with `activationCodeProvider` (reads `settings.activation_code`) and `fingerprintProvider` (`DeviceFingerprint.get(db)`) wired to production data.
  - Edge-Function bug fix caught while building the UI: `list_devices` was masking non-self fingerprints, so a buyer could not obtain the full fingerprint of a lost device to send a `deactivate_device` for it. Now every row returns its full fingerprint to the caller (RLS still ensures only registered seats for that code can list). Masked value retained as `fingerprint_masked` for display.
  - Tests: `test/features/settings/devices_screen_phone_test.dart` (5 widget tests at 390×844 phone width) — seat list rendering, `This device` chip, deactivate flow calling the client + refreshing, voucher redeem parsing the returned `new_seat_limit`, and the two "not usable" states. Verification: `flutter analyze` clean, **178 tests pass** (was 173).
- **Phase 17c**: Licensing deployed live + loose ends closed (2026-10-24):
  - Server deployed to Supabase project via the Management API: all 5 licensing tables + RLS (no public policies), `apply_seat_voucher` RPC, `license_seat_usage` view hardened with `security_invoker = true` + explicit `REVOKE` from anon/authenticated (clears the Security Definer View lint finding). Edge Function `licensing` deployed with JWT verification off and `LICENSE_SIGNING_SEED_B64URL` set as a secret.
  - Deployment bugs fixed along the way: `docs/supabase_licensing.sql` dropped its trailing `grant`/`alter owner` block (fails `42501` on projects where schema `public` is owned by `pg_database_owner`; Supabase default privileges already cover `service_role`); the Edge Function's `npm:` imports caused `BOOT_ERROR` on the Deno runtime — switched to `esm.sh` CDNs; `create_customer.dart --expires never` was wrongly rejected (null-expiry treated as parse failure).
  - End-to-end verified against the live server: create customer → activate ×2 → deactivate → refill to seat limit → 409 refusal past the limit → issue voucher `V-…` → redeem → previously-blocked device activates at 4/5. The Ed25519 signature from the Edge Function verifies in the Dart `LicenseValidator` with fingerprint match (v2 path).
  - `app/tools/build_release.ps1` — one-command release recipe (`windows` | `apk`) baking both `WHOLESALE_POS_LICENSE_PUBLIC_KEY` and `WHOLESALE_POS_LICENSE_FN_URL`; a distributable can no longer ship with licensing silently missing. First APK produced with it: `build\app\outputs\flutter-apk\app-release.apk` (59.9 MB, upload-keystore signed).
  - Test data purged from the live licensing tables (all back to 0 rows).
  - Remaining manual steps for Umer: revoke the temporary Supabase access token used for deployment (Dashboard → Account → Tokens), rotate the `sb_secret_…` service-role key (Dashboard → Settings → API — the Edge Function picks the new value up automatically), and install the APK on a real phone to activate with a freshly issued code.
- **Phase 18**: License-gated sync gateway — cloud sync is now multi-tenant and sellable (2026-10-24):
  - Replaced the "ship the Supabase secret key in the build" sync auth (Phase 12 limitation, `UNSAFE_EMBED` opt-in) with the **signed v2 license** as the sync credential. New `sync` Edge Function (`supabase/functions/sync/index.ts`, deployed, JWT-verify off, secret `SYNC_LICENSE_PUBLIC_KEY`): verifies the Ed25519 signature + expiry + non-revoked license row + ACTIVE device seat per request, then upserts mirror rows with `customer_id` stamped from the verified payload — a client can never address another shop's partition. Actions: `push` (outbox drain), `pull` (delta feed on `received_at` cursor, for the future read-side), `ping` (auth probe).
  - Mirror schema rebuilt live on Supabase (`docs/supabase_sync_multi_tenant.sql`): all 5 tables gained `customer_id uuid NOT NULL REFERENCES customers(id)`, composite PK `(customer_id, id)`, customer-first indexes, RLS enabled with zero policies + `REVOKE ALL` from anon/authenticated (verified `has_table_privilege('anon', 'sales', 'SELECT') = false`). One project now safely hosts many shops.
  - Contract fix caught during live testing: the function must map the LOCAL entity vocabulary the Dart outbox enqueues (`sale`/`shift`/`cash_movement`/`void_request`, `UPSERT`/`DELETE`) to cloud table names — first deploy only accepted table names/lowercase ops.
  - Client: `lib/core/sync/sync_gateway_backend.dart` implements the existing `SyncBackend` seam; license read lazily per drain from the `license_code` setting (activate mid-session → next 30s tick syncs, no restart; un-activated → rows stay queued, selling unaffected). Gateway URL resolves from `WHOLESALE_POS_SYNC_FN_URL` or is derived from the licensing URL (`/licensing` → `/sync`), so `tools/build_release.ps1` builds enable it automatically. `main.dart` selection priority: desktop-with-baked-secret (legacy owner PCs) → gateway (everything mobile/buyer) → legacy mobile opt-in → Noop.
  - Verified end-to-end against the live server: mint license via licensing `activate_device` → `ping` ok → `push` in client vocabulary applied sale+item stamped correctly → `DELETE` cascaded items → forged license rejected 401. Test seats/rows purged after.
  - Tests: `test/core/sync/sync_gateway_backend_test.dart` — 13 new (URL derivation ×3, selection priority ×5, push behaviour ×5 incl. no-license-throws-without-HTTP and 200-with-ok:false throws). Verification: `flutter analyze` clean, **191 tests pass** (was 178).
- **Phase 19**: Full security audit + fixes (2026-10-24). Deep vulnerability review of the licensing/sync backend using osv.dev (dependency CVEs), live penetration testing against Supabase, and an APK binary audit. Two real defects found and fixed:
  - **CRITICAL — cross-tenant seat theft.** `redeem_voucher` and the `apply_seat_voucher` RPC authenticated the *caller* but redeemed any voucher by code alone, never checking the voucher belonged to the caller's license. Proven live: a device on shop A redeemed shop B's voucher — B's `seat_limit` jumped 3→8 and B's paid voucher burned, with the response leaking B's license state. **Fixed**: `apply_seat_voucher(p_voucher_code, p_activation_code)` now requires the voucher's parent `activation_code` to equal the caller's, and a mismatched code is refused as generic "not found" (no existence oracle). Legacy unbound `apply_seat_voucher(text)` overload dropped.
  - **CRITICAL — SECURITY DEFINER RPCs publicly executable.** Supabase default privileges `GRANT EXECUTE` on every public function to `PUBLIC` (inherited by `anon`/`authenticated`), so `/rest/v1/rpc/apply_seat_voucher` and `/rpc/try_reserve_seat` were callable with just the anon key, bypassing the Edge Function entirely. **Fixed**: `REVOKE EXECUTE … FROM public, anon, authenticated` + `GRANT EXECUTE … TO service_role` on both RPCs (verified `has_function_privilege('anon', …) = false`).
  - **Latent — activation seat TOCTOU.** `activate_device` read the seat count then inserted in two round-trips. **Fixed**: new atomic `try_reserve_seat(p_activation_code, p_device_fingerprint, p_device_name)` RPC serialises on the license row (`SELECT … FOR UPDATE`) and folds revoked/expired/not-found + count + insert into one locked call; Edge Function rewritten to use it. Verified: 8 concurrent activations vs a 2-seat code admit exactly 2.
  - **Defense-in-depth**: `REVOKE ALL` from `anon`/`authenticated` on all five licensing tables (they already RLS-deny 0 rows; now privilege-less too).
  - **Verified clean (no change needed)**: RLS is default-deny everywhere (0 policies, `anon`/`authenticated` have `rolbypassrls=false`); mirror tables + `license_seat_usage` view already hard-denied anon; forged/tampered/expired/revoked licenses all rejected by the sync gateway (401/403), `customer_id` stamp-beats-payload proven (a pushed row forging another tenant lands stamped with the license's own tenant), SQL-injection strings stored literally (PostgREST parameterised), 501-entry batch refused (413), GET refused (405); activation codes are `Random.secure()` 90-bit; **osv.dev: 0 CVEs across 98 Dart + 2 npm deps**; release APK contains **no** service key / signing seed / keystore passwords. All fixes are server-side (Edge Function + DB) so the shipped APK is unaffected.
- **Phase 19b**: Credential rotation completed (2026-10-24). The leaked Management API token and the service-role (`sb_secret_…`) key were both rolled in the dashboard. Verified live: old token now returns 401; the Edge Functions picked up the new managed service key without a redeploy (unknown code → 404 proves the read path, a real activation → 200 + signed license proves the write + signing-seed path); `create_customer.dart` with the new key issued a live activation code (not reproduced here — a code is a bearer credential for its tenant). All 8 audit scratch scripts that embedded the old token were deleted; `git grep` confirms no `sbp_…`/`sb_secret_…` remains in tracked files. `build_release.ps1` bakes only the public key + function URL, so no distributed build was affected by rotation.


- **Phase 20**: Two-step checkout, a permanent training account, and phone-number logins (2026-10-28):
  - Checkout is two steps now: the New Sale dialog captures the line and validates it, then **Next** opens a separate *Payment Method* window that summarises the sale (name, quantity × price, total) and only completes once Cash, Bank Transfer or Credit is chosen. Closing either window cancels without touching stock; register totals, dashboard revenue and receipts are unchanged.
  - **Permanent demo account** `demo` (seeded once natively — schema v13 `users.is_demo`, adopting an existing `demo` row when present — and once per tenant by `pos-api`, `pos_users.is_demo`) on login/setup, always a CASHIER with the default staff ticks. It was seeded with a published default password until Phase 22 replaced that with a per-shop random one. It can never be deactivated (guard in `setUserActive` on both backends) while its feature ticks stay editable so the owner can retrain different trainees; the Users list shows a **Demo** chip and hides Deactivate for it.
  - **Phone-number login**: the account identifier is an Ethiopian mobile number kept in the existing `username` column in one canonical form (`0[79]` + 8 digits). `PhoneNumber` (Dart) and `normalizePhone`/`loginIdentifier` (pos-api) fold `+2519…`, `2519…`, `9XXXXXXXX`, spaces, dashes and parentheses; sign-in passes unrecognised values straight through, so text logins created earlier keep working until renamed. New accounts must be a phone number (names and the reserved `demo` are refused), and the owner gets **Edit phone** in the Users menu — owner-only, unique, demo refused, audited as `USER_PHONE_CHANGED`. The login field is labelled *Phone Number*; the demo account still types `demo`.
  - **Deleting a disabled account** (native schema v14 `users.deleted_at`, cloud `pos_users.deleted_at`): the Users menu now offers *Delete Account* on a deactivated row (never on an active one, the demo account or the owner's own row) behind a confirmation dialog, and `deleteUser` is owner-only on both backends. An account that never recorded a sale, shift, cash movement, finance entry or void request is deleted outright, so its phone number is free again; one that did keeps its row flagged (hidden from the Users list, from login and from session restore) because `sales.cashier_id` is a NOT NULL foreign key and per-cashier reports join it. Re-creating the same phone number reuses that flagged row, so the rehired cashier inherits the attribution instead of a dangling id. Audited as `USER_DELETED`; backups carry `deleted_at` so a restore cannot resurrect a deleted login; `pos_setup_owner`'s bootstrap count ignores deleted rows.

- **Phase 21**: 100-day live walkthrough and heavy-load run against the deployed PWA (2026-10-28):
  - `app/tools/stress_seed.sql` writes a tagged 100-day history (14 names, 99 closed sessions plus the live one, 2,000 sales / 5,000 lines, 100 cash movements, 13 voids, 4 void requests, 3 people and 8 money entries) straight into the tenant, honouring the same totals invariants the app enforces; `app/tools/stress_cleanup.sql` removes every tagged row in one step. Verified after seeding: 0 line-sum mismatches, 0 total mismatches, 0 payment mismatches, exactly 20 sales per day.
  - **Bug found and fixed**: `pos_create_sale` refused `LOAN` while the PWA offered it, so every credit sale failed with *Invalid payment method: LOAN*. The RPC now accepts all three till methods and settles a non-cash sale in full with no change, as the native repository does.
  - `app/tools/stress_burst.mjs` drives live load through `pos-api`: 200 concurrent receipt allocations stayed unique and 300 concurrent reads never failed; at 200-way write concurrency roughly 8% of requests were shed as HTTP 503, while 50-way writes plus 300 reads ran clean (sale p95 776 ms). `USER_DEACTIVATED` audit rows now name the phone number instead of the row id.
  - **Second LOAN defect found and fixed**: after the RPC accepted loans, the cloud dashboard still counted them in *Completed Sales* while revenue/cash/bank stayed loan-free, so Average / Sale fell whenever a credit sale was posted and the PWA disagreed with the Windows build. `pos_sales_totals` now counts only CASH/BANK completed rows (verified live: cloud count 1912 = expected 1912, 201 completed loans excluded). A saved sale also confirms itself now — *Sale REC-… recorded · 7,500.00 Br · Loan (on credit)* — because a loan moves neither the drawer nor revenue and the cashier could otherwise think nothing happened.

- **Phase 22**: External audit remediation — money, time, authorization, reliability (2026-10-28):
  - **The audit**: an independent review graded the cloud/PWA side NO-GO. Every finding was reproduced against the code and the live database before anything was changed; the earlier "ready for commercial use" read on the PWA was too generous, and this phase is the correction.
  - **Money**: `pos_create_sale(p_sale_id …)` is idempotent on the client's own sale id, and `sales_receipt_unique (customer_id, receipt_number)` closes the double-booking window, so a retried checkout returns `duplicate: true` instead of a second row (verified live: two calls, one sale row, one item set, one receipt). Every drawer movement now goes through `pos_add_cash_movement`, which refuses a closed shift — an EXPENSE therefore drains the drawer by exactly its amount (live: 129,000 → 128,950 for 5,000) instead of being ignored, and sales on a CLOSED shift are refused at the RPC. Register totals, the shift report and the dashboard all read `pos_shift_counters` / `pos_shift_summary` SQL aggregates, so three screens can no longer disagree about the same day.
  - **Time**: the receipt day and every trend bucket use the shop zone (`Africa/Addis_Ababa`) rather than the function's UTC clock, and the Dart cloud clients serialize every `timestamptz` argument through `isoInstant()` (`.toUtc()`). This fixes the three-hour skew that could date an evening sale to the next day and made a "today" filter miss the last three hours of trading.
  - **Authorization**: one drawer per tenant (`shifts_one_open_per_tenant` plus the advisory-locked open path) replaces the device-scoped split that let two tills hold separate floats. `list_void_requests` is owner-only now (it hydrates the whole sale behind each request), `request_void` needs `pos`, `history` or `register_history`, a cashier cannot pull a closed shift's summary, and `pos_users_one_owner` refuses a second owner seat with a 409 while the Add-user dialog explains why.
  - **Demo credential**: the published `demo1234` no longer signs in anywhere. The cloud mints a 14-character random password per tenant, returns it to the owner exactly once (`demo_password` on the login/setup response, shown in a one-time dialog), and records `pos_settings.demo_pw_version` so it can never be revealed again. The desktop side stores only a PBKDF2 hash: an install holding the old password verifies it once, rotates it and audits `PASSWORD_RESET`; the owner sets a known password from Users > Reset Password before training. `verify_phone_login.ps1` / `verify_delete_user.ps1` read `$env:POS_DEMO_PASSWORD` or skip the demo step.
  - **Reliability**: `audit()` reports insert failures instead of swallowing them, and every ledger list (`search_sales`, `shift_history`, `list_cash_movements`, `list_audit`, `finance_search_entries`) is capped at 1,000 rows and flags `truncated`, so a large tenant cannot pull its whole history into one response.
  - **Tooling and docs**: `stress_burst.mjs` now asserts the outcome — every sale accepted, receipt numbers unique, dashboard delta equal to the accepted CASH+BANK sales, replaying one sale id booking nothing — and prints the exact cleanup SQL. `README.md` matches `build_release.ps1` (no shipped license, schema v14, PWA/deploy section, demo policy), and the stale 66 KB `app/full_test_log.txt` is gone.

- **Phase 23**: Second audit, wave A — the money, authorization and conflict fixes (2026-10-28):
  - **Scope**: a 28-finding follow-up audit (same reviewer, deeper on the cloud path) was reproduced finding-by-finding before any change. Wave A is the set that can only add safety; the sync redesign is wave B and the receipt-namespace / token-lifetime work stays deferred (wave C) because those change formats or signed-in behaviour.
  - **Licence expiry**: `login`, `setup_owner` and `has_users` each looked up the tenant by activation code and only honoured `revoked_at`, so an expired licence still worked on the PWA. They now share one `licenseForActivationCode` gate that refuses expired and revoked codes alike, and is the only place that resolves a code to a tenant. Verified live: 1 licence, 0 revoked, 0 expired, so no installed tenant is locked out.
  - **Receipt collisions**: when a receipt number already belonged to a *different* sale, `pos_create_sale` returned that other sale as `duplicate: true` — the cashier was told the sale was saved while their own row and lines were never inserted. Only the same sale id is replayed now; anything else raises `Receipt … is already used by another sale.`, and `CloudSaleRepository.saveSale` refuses to report success unless the server echoes the id it sent.
  - **Double deposit**: two concurrent `pos_complete_finance` calls both read PENDING, one updated the row and both deposited the collection. The row is locked `FOR UPDATE`, the update must affect exactly one row, `cash_movements.source_finance_entry_id` plus `cash_movements_one_per_finance_entry` makes a second deposit impossible at the storage layer, and the movement now opens or reuses the shift through `pos_ensure_shift` instead of inserting a shift behind the advisory lock.
  - **Line discounts**: the RPC compared the line total against the undiscounted base, so a discount could be stored without ever being applied to the money. The discount is subtracted before the comparison and validated to 0..line total, matching the native repository.
  - **Money Tracking is owner-only**: the server listed every `finance_*` action as available to any account holding the `finance` tick, while the desktop repository refuses a non-owner. The twelve actions moved into `OWNER_ONLY`, `finance` left `FEATURE_KEYS`, and the client registry marks it `ownerOnly` so it is absent from the tick grid and dropped from any crafted permission list. *(Superseded in Phase 28: the tick is now the whole rule on both backends — see below.)*
  - **Settings surface removed**: `get_setting` / `set_setting` accepted any key from any signed-in account, which let staff overwrite reserved server state (the demo-credential marker included). The PWA keeps its preferences in browser storage and never called them, so both are gone.
  - **Demo credential**: any first sign-in — a cashier's included — could rotate the demo password, and the new secret was only ever returned to an owner, so the trainee was silently locked out. Seeding and rotation now require an owner session, and every write in the path checks its error and row count before the version marker is set.
  - **Account activation**: `set_user_active` validated a deactivation but not an activation: an unknown id updated nothing, was audited as `USER_ACTIVATED` and answered `ok: true`. Both directions load the target, a non-boolean `active` is refused, and the update must touch exactly one row.
  - **Small silent failures**: `finance_summaries` returned zeroed totals when a read failed, a rename answered `ok: true` for a missing or binned person, permanent delete of a person was two requests (now one `pos_delete_finance_category` transaction), `list_void_requests` was unbounded, and the sale-search lookups ignored errors and quietly returned fewer rows.
- **Phase 24**: Second audit, wave B — the sync path can no longer write as it likes (2026-10-28):
  - **Staging, not writing**: a device push used to upsert whatever payload it liked straight into `sales`, `shifts`, `cash_movements` and `void_requests` — device-chosen totals, receipts and cash could be injected beside the till's own records, and a DELETE entry hard-deleted a cloud row. `docs/supabase_sync_mirror.sql` adds `sync_mirror` (one row per customer/entity, append-only, PK `customer_id, entity_type, entity_id`) and a server-owned `pos_sync_apply`. A push only stamps rows into the mirror; the apply step then replays each pending entry through the same RPCs the tills use (`pos_create_sale`, `pos_add_cash_movement`, `pos_ensure_shift`), so the money is re-derived and the shift/receipt invariants hold. Verified live: an empty-line sale is REJECTED with *Sale payload has no line items.*, a device DELETE is REJECTED with *A device cannot delete a cloud record.*, and neither left a row in `sales`.
  - **Per-entry verdicts**: the gateway returns one result per outbox entry — `applied`, `stored` (safe, applied on the next push), `rejected` (permanent, carries the server's reason) or `failed` (retryable) — and echoes the `entryId` so the client cannot confuse two entries for one entity. The outbox acks per entry: an unknown entity type is reported and dropped instead of retried forever, and a stored-but-not-applied entry is not acked away.
  - **Gateway first**: the shipped sync backend used to prefer a desktop-only embedded secret, which is exactly the credential the gateway exists to replace. The gateway is now selected whenever a URL is configured and the embedded secret is only a fallback for a build that deliberately opts in.
  - **RPC privileges closed (found while gating the above)**: all 20 `pos_*` functions were executable by `anon` and `authenticated`. `REVOKE … FROM public` does not undo Supabase's default privileges, which grant EXECUTE to those roles by name, and SECURITY DEFINER bypasses RLS — so anyone holding the published anon key (every web build ships it) could pass another tenant's customer uuid to `pos_create_sale`, `pos_open_shift` or `pos_sales_totals` and read or write that shop's books. `docs/supabase_pos_integrity.sql` now closes every `pos_*` function to `anon`/`authenticated` in one idempotent block (future functions included) and leaves `service_role`, which is what the Edge Functions use. Verified live: 20/20 refuse anon, `service_role` still returns data, and `SET ROLE anon` answers `42501: permission denied for function pos_sales_totals`.

- **Phase 25**: Cloud read-back — every device sees the whole shop (2026-10-28):
  - **The gap**: sync was one-way. `SyncService.syncNow` returned early the moment the outbox was empty (`if (pending.isEmpty) return SyncResult.idle();`), and no backend implemented `pull`, so a till only ever uploaded. A second device — or the same owner on a new machine — saw its own sales and nothing else, even though the cloud already held the shop's history.
  - **Local-first pull** (the operator's choice: keep selling offline, download the rest on sign-in): `SyncBackend.pull` is now real. `sync_pull_applier.dart` writes a page into SQLite in foreign-key order — accounts, device stubs, shifts, sales, lines, cash movements, void requests — inside one transaction, so `PRAGMA foreign_keys = ON` is satisfied and a half-applied page can never exist. `CloudSyncPuller` reads a stored cursor per table, pages until `has_more` is false, and persists the cursor **after every page**: a crash or a closed laptop resumes instead of re-reading a year of trading.
  - **Pages are per table, on purpose.** A keyset cursor is only ordered within one table; asking for six tables at once let the busiest table drag the cursor past rows a quieter one had not delivered yet — silently losing sales. The gateway now accepts a `tables` filter and the client walks one table at a time.
  - **Never over a local row.** Applying is additive; the one exception is a sale's void state, which the owner decides server-side, and even that is skipped while this device still holds an unacked outbox entry for the same sale.
  - **Receipt numbers are per till.** Each register allocates its receipt number locally and offline, so two tills legitimately issue `REC-<day>-0001` on the same day. The tenant-wide `sales_receipt_unique` index rejected the second one and left it rejected in the sync mirror forever; it is now `sales_receipt_per_device (customer_id, device_id, receipt_number)`, and the applier namespaces a pulled receipt that this till already used (`REC-…-0001#<device>`) instead of dropping the transaction. Receipt numbers are internal identifiers, never shown in sales history.
  - **Accounts travel with their hash.** Login is verified offline against the local PBKDF2 hash, so a device that never created the account could not sign it in — which is exactly "log in on the other device". The gateway serves `pos_users` through an explicit column list (never `token_version`) to a device holding a signed licence for the same tenant. Without it, multi-device sign-in is impossible; with it, the exposure is the same one the till's own SQLite file already carries.
  - **Joining a shop is not first-time setup.** On a valid licence with an empty ledger the app now pulls once *before* the login gate decides between "create the first owner" and "sign in", so a second till cannot quietly create a duplicate owner. Every sign-in also forces a refresh (`syncNow(forcePull: true)`); the timer pulls on a slower cadence than it pushes, because a pull costs one request per table.
  - **Another till's OPEN shift is kept as a closed parent.** The local trigger allows exactly one open drawer; a foreign open shift is stored closed so the sales that reference it still land instead of failing their foreign key.

- **Phase 26**: Cloud sync is visible, and a licence it refuses says so (2026-10-28):
  - **The last silent failure**: a PC holding a pre-Phase-17 `license.key` validates locally (the file carries no tenant), so it signs in and sells normally while the sync gateway refuses it with 401 *License format not supported by sync.* — every cycle failed and nothing said so. Sync state is now published as a `SyncStatus` (`sync_status.dart`) after every cycle and shown in **Settings → Cloud Sync**: connected + last sync time + how many records the last pull downloaded, the failure reason, or "off on this build" for a plain offline release.
  - **A refused licence is not a network problem**: `SyncGatewayBackend` raises a typed `SyncAuthException` for a missing licence and for HTTP 401/403, carrying the gateway's own wording, so no amount of retrying is presented as if it might work. Any other failure (offline, 5xx) stays a plain error.
  - **One action fixes it**: an owner sees **Activate this device** in the same row when, and only when, the licence is the problem. It redeems the shop's activation code through `DeviceActivation` — the same implementation the first-run activation screen uses (extracted from `main.dart`, no second copy of the rules) — stores the device-bound licence, then syncs and reports how many records arrived. The local ledger is untouched, so activating an existing till keeps its sales.
  - **The register shows what the pull brought**: `MainLayout` listens to the status and refreshes the dashboard, register, reports, sales and finance screens when a pull wrote rows, so another till's sales appear without a restart or a tab switch.
  - **Manual sync**: the same row has a *Sync now* action that forces the download half immediately (the timer pulls every 2 minutes on its own).
  - **Editor noise (found while deploying)**: the IDE's TypeScript server cannot resolve Deno globals or `esm.sh` URLs and flagged 7 errors in `supabase/functions/sync/index.ts`. `supabase/functions/tsconfig.json` + `deno_shim.d.ts` declare the small surface used (`Deno.serve`, `Deno.env`, the two remote modules) for the editor only; Deno still type-checks against its own lib on deploy.

## Verification

- Load test (`app/tools/k6_load_test.js`, k6 v2.2.0): 910 requests, **0.00% failed**, every check passing. The two Edge Function scenarios ran at 1→20 virtual users: pos-api median 292 ms / p95 685 ms / p99 919 ms, sync gateway median 269 ms / p95 684 ms. Both gates answered correctly under load (403 unknown activation code, 401 missing licence) rather than erroring. Read-only by design — the authenticated sale path was measured in Phase 21.
- PWA delivery: `main.dart.js` is 3.01 MB decoded but **937 kB on the wire** (brotli), served from the Vercel edge cache. The bundle is `Cache-Control: no-store` on purpose (it is what guarantees a fresh app after every deploy), so each app open re-fetches it; time-to-first-byte stays under 1.5 s, while total download time tracked the local link (2 s to 35 s across runs, matching a Cloudflare baseline that was slower still). Publishing the bundle with `max-age=0, must-revalidate` + ETag would replace that download with a 304 and keep deploys immediate, but it is only safe if the ETag changes with content — left as a decision, not a change.
- StackVet 0.3.3 (`stackvet doctor`): health score **92/100, grade A**, 0 critical, 0 errors, 4 warnings. All four were checked and are false positives or expected: two RCT-004 "JSX element in .map() needs a key" hits are `new Set(rows.map(...))` in TypeScript with no JSX, IMP-003 "orphan file" is the new k6 script, and DISC-005 is the 15 MB release zip exceeding its 10 MB scan limit. The tool's dependency audit did not run (it does not read pubspec.yaml), so the osv.dev scan from Phase 19 remains the CVE source.

- `flutter analyze`: clean.
- `flutter test`: 331 tests passing (database, v5→v6/v6→v7/v7→v8/v8→v9/v13→v14 migrations, repositories incl. sale search/dashboard/revenue-trend/voids and the void-request lifecycle, corrected register cash math, register/shift history filtering and discrepancy, role-based password policy and login cooldown, duplicate saved-name prevention, owner-only finance, money/quantity/date-range parsing, backup import/normalization incl. void_requests, cart, widget; the demo account's retired default password, owner-set password and credential-version marker; the sync-outbox enqueue/drain/prune behaviour and the mobile-vs-desktop backend selection rule; the session store; the Supabase backend request mapping via a mock HTTP client; the phone-width responsive layout guards for the register, the active Register screen, the eight other drawer screens, the activation screen, and the new buyer-facing Devices screen; the mobile `licenseText` verification round-trip plus the new v2 fingerprint-bound licenses; the device fingerprint stability across calls; and every ActivationClient path against a mocked HTTP client). Phase 25 adds 11: a pulled sale lands with its cashier/device/shift, local-time timestamps and its credential; replaying a page writes nothing; a receipt clash keeps both sales; another till's OPEN shift lands closed; a remote void applies unless this till still has it queued; the puller pages one table at a time with a per-table cursor; and `syncNow` pulls even with an empty outbox. Phase 26 adds 12: the gateway's 401 bodies become a typed auth failure (and a 503 does not), an un-activated device says so before any HTTP call, the service publishes connected/failed/disabled status and counts what it downloaded, and the Settings row shows the activation prompt (owner only, opens the code dialog) or the healthy "up to date" line as appropriate.
- Live SQL, phase 25: `pos_users.received_at` backfilled (0 rows missing), `sales_receipt_per_device` created and `sales_receipt_unique` dropped, and the `pos_users` projection the gateway serves verified row-for-row. The sync gateway is deployed with the `users` table plus the epoch default for a cursor-less first pull.
  - **Not yet proven live**: the Windows build on this machine holds a legacy **v1** `license.key` (no `activation_code`/`device_fingerprint`), which the gateway refuses by design (`License format not supported by sync.`). Sync therefore stays inert there until the PC is activated once with the shop's activation code — the pull path itself is covered by the tests above and by the deployed gateway.
- `flutter build windows --release`: succeeds through `app/tools/build_release.ps1 windows`, which bakes the licensing public key, the licensing function URL and the pos-api URL and then fails the build if a `license.key`, SQLite file or signing material is present in the output.
- **Phase 23 wave** was gated the same way after `docs/supabase_pos_integrity.sql` was reapplied: all 5 invariant indexes and 19 RPCs present, `cash_movements.source_finance_entry_id` in place, and zero double deposits, duplicate receipts or multi-open shifts in the live tenant. pos-api is deployed at version 15.
- Live SQL, phase 24: `sync_mirror` and `pos_sync_apply` exist and the mirror is empty; the two dangerous shapes land `REJECTED` with their specific reasons and write nothing to `sales`; the table denies `anon`/`authenticated` select, insert and update while `service_role` still inserts, and all 20 `pos_*` RPCs deny anon (call-time `42501`) while `service_role` returns data. The sync gateway is deployed at version 9 and refuses a missing or malformed licence with 401 before touching the database.

### Cross-device sign-in (schema 15)

- **Bug**: an account created or reset in the PWA could not sign in on the Windows/Android app. `pos-api` stores `pw_hash = "<iterations>$<b64>"` derived over the **decoded** salt bytes; the till required its own `pbkdf2-sha256$v=1$i=` prefix and derived over the **salt text**, so the pulled row fell through to the legacy 10k-round comparison and every attempt answered "Invalid phone number or password". The demo hit the same wall: the pull could not reuse the name `demo` (this till had already seeded its own), so the browser password landed on a `demo#<id>` copy nobody types.
- **Fix**: schema 15 adds `users.cloud_pw_hash` / `users.cloud_pw_salt`. The pull writes the browser credential there (never over the local pair, so a password set on either side keeps working), the verifier dispatches on the format it finds (cloud, local, or pre-schema-5 HMAC), and `ensureDemoUser` adopts the cloud demo credential onto the one login named `demo` — covering installs that already hold a `demo#<id>` duplicate.
- `pos-api` (v16) now stamps `pos_users.received_at` on every edit. The gateway pages that table by that stamp, so without it a password reset in the browser was never re-sent to a till that already pulled the row.
- `flutter analyze`: clean. `flutter test`: 337 passing (3 new: a browser-issued password signs in on this device, a pulled demo credential merges onto `demo`, and the pre-schema-15 `demo#` repair).

### Multi-device consistency (Phase 27)

Running two tills on one shop was where the sync design's assumptions started to
cost money without an error message. Seven failures were found by reading the pull
path, the gateway and the mirror schema against each other; all are fixed.

- **A void never left the till that made it.** `sync_mirror` keeps the first
  payload per entity and `pos_sync_apply` replays a sale through
  `pos_create_sale`, which is idempotent by sale id — for a sale that already
  exists that is a no-op. So the second device, and the owner's dashboard, kept
  counting voided money. The gateway (`terminalState`, v11) now applies
  `VOIDED` sales and `APPROVED`/`REJECTED` void requests through the same RPCs
  the PWA calls, after the apply pass; a refused repeat is treated as success
  (a retried entry is exactly a repeat), and a transition whose row is still
  queued behind a backlog is reported retryable instead of acked.
- **An UPDATE never re-entered the delta feed.** `received_at` was `DEFAULT
  now()`, so a void, a decided request or a closed drawer changed the row in
  place and kept its old stamp. `docs/supabase_sync_delta.sql` adds a
  `BEFORE UPDATE` trigger on all six mirror tables (applied live and proved
  with a rolled-back probe: `2026-10-28 16:58:57` → `2026-10-29 05:08:45`).
- **A drawer closed elsewhere locked this one out.** Local `shift` rows were
  never updated on pull, and the database allows exactly one OPEN shift, so a
  foreign OPEN row meant the register could not open a drawer again. A pulled
  `CLOSED` shift now closes the local one (OPEN → CLOSED only, skipped while
  this till still has the shift queued).
- **A cashier switched off in the browser kept signing in on every till.**
  Pulled users only refreshed the cloud credential; role, `is_active`,
  `deleted_at` and `permissions` now follow the cloud too. A local password is
  still never overwritten, and the demo account is exempt.
- **Voided money could come back.** `_refreshVoidState` applied whatever status
  the cloud sent, so a stale `COMPLETED` page un-voided a sale. Void state,
  void-request decisions and shift closes are now strictly one-way.
- **Sales vanished on the second device.** `sales` requires `cashier_id`,
  `shift_id` and `device_id`; a cashier or drawer known only to the making till
  made the insert fail and the whole sale (with its items and movements)
  disappear, silently. The applier now mints the missing parent first — an
  inactive soft-deleted placeholder user that cannot sign in, a closed
  zero-cash drawer, an "Unknown register" device.
- **Children arrived before their parents.** The puller walked tables in order
  but kept going after hitting its per-run page ceiling, so `sale_items` could
  be pulled while `sales` still had a backlog, and every orphan was refused. It
  now stops the run as soon as a table was not exhausted.

- `flutter analyze`: clean. `dart format --set-exit-if-changed`: clean.
  `flutter test`: **343 passing** (6 new: a sale whose cashier and drawer exist
  only elsewhere still lands; a drawer closed in the cloud closes this one too;
  a stale completed page never un-voids; a cashier switched off in the browser
  stops signing in; a void request decided in the browser stops pending here;
  a backlogged parent table holds back its children). Sync gateway deployed at
  version 11.
- **Artifacts rebuilt on top of these fixes**: `app-release.apk`
  (`versionCode 3`, same `com.umer.wholesale_pos_app` package, so it updates
  over an installed till instead of replacing it) and
  `WholesalePOS_Windows_Release.zip` (15 entries, no licence, local DB or
  signing material). The PWA was rebuilt and redeployed in Phase 28, when the
  account editor gained the tick — that change is client-side, so the browser
  build did need it.

### Money Tracking as a permission (Phase 28)

- **The tab was unreachable for staff by design, not by choice.** Money
  Tracking was hard-coded owner-only on both backends: `finance` carried
  `ownerOnly: true` in the client registry (so the tick grid never offered it),
  the native repository re-checked `role = 'OWNER'` inside every read and write,
  and `pos-api` listed all thirteen `finance_*` actions in `OWNER_ONLY`. There
  was no way for an owner to hand the area to, say, a trusted manager.
- **It is now a normal tick, with the same enforcement.** `finance` is a
  grantable feature (still absent from `kDefaultStaffPermissions`, so a new
  cashier never gets it by accident); the native repository accepts an **active**
  account that is the `OWNER` **or** holds the tick, checked inside the same
  transaction as the work; and `pos-api` moved the thirteen actions from
  `OWNER_ONLY` into `ACTION_FEATURES` with `['finance']`, so the server refuses
  exactly the accounts the desktop refuses. The audit argument still names the
  account that actually touched the money, and a CASH collection is still
  credited to it.
- **Revoking works mid-session.** The guard re-reads the acting row on every
  call, and the pull already applies a permission change made in the browser to
  the till's own user row, so unticking Money Tracking closes the area without
  a restart or a re-login.
- `flutter analyze`: clean. `dart format --set-exit-if-changed`: clean.
  `flutter test`: **348 passing** (2 new in `features_test`: the tick is
  grantable, grants the tab and is never a default; 3 new in
  `finance_repository_test`: a ticked cashier keeps the whole area and is the
  audit actor, removing the tick closes it again, and the unticked/deactivated
  accounts stay refused). `pos-api` deployed at version 17.
- **The server-side fixes now have a live regression test.** `docs/fixes_v1.sql`
  is the audited patch set (nine changes, idempotent, one transaction);
  `docs/preflight.sql` and `docs/postflight.sql` snapshot the invariants around
  it, `docs/verify_fixes.sql` asserts each change by name, and
  `docs/smoke_test.sql` exercises the real RPCs — sale, replay, bad payload,
  duplicate line ids, void reason, double void, photo cap, finance delete guard
  — against a throwaway tenant inside a transaction that always rolls back, so
  it reports **8/8 passing** without leaving a row behind. All nine assertions
  and all eight smoke tests pass on the live project.
- **The PWA is live on the new build.** `tools/deploy_web.ps1` rebuilt
  `main_web.dart`, deployed to Vercel, re-pinned `web-xi-seven-15.vercel.app`
  at the fresh deployment and proved it by byte length (3,157,883 bytes served
  = the local bundle), so the browser build's account editor offers the tick
  too. Open it in a fresh tab — the service worker keeps serving the old bundle
  until the tab is fully closed and reopened.

### Bidirectional master data and the 3-second cycle (Phase 29)

Only sales, shifts and cash movements travelled before this phase: accounts,
the product catalog and Money Tracking were local-only, so a cashier created on
the desktop did not exist on the phone, and a browser could not see what a till
was selling. Syncing those three domains is what made the 3-second cadence
worth having — and it exposed two failures that were breaking real sales.

- **The premise "native sales are REJECTED in `sync_mirror`" did not hold.**
  At diagnosis the tenant sat at 8 APPLIED / 0 REJECTED, so there was no fresh
  rejection row to read. The symptom had three separate causes, all fixed:
  - **A release that never sent anything.** `build_release.ps1` shipped without
    `WHOLESALE_POS_SYNC_FN_URL`, so sync was inert in exactly the builds that
    were handed out. All three endpoints are now derived from one licensing
    constant, which a build cannot forget.
  - **`pos_sync_apply` RAISEd on the `shift` branch.** Every shift entry was
    refused, so the open drawer a sale depends on never landed and the sale
    followed it with *"Sale requires an open shift"*. `docs/supabase_sync_master_data.sql`
    orders the apply pass by dependency (`user → shift → sale → cash_movement →
    void_request → finance_category → finance_entry`) and turns a transient
    failure into `CONTINUE` — the entry stays PENDING and retries — instead of
    aborting the whole pass over one row.
  - **A second register could not take a payment at all.** `sales.receipt_number`
    is `TEXT UNIQUE NOT NULL` locally, but `nextReceiptNumber()` consulted only
    *this device's* day counter. A till that joined the shop had already
    **pulled** the first register's `REC-<day>-0001…0004`, was handed `0001`
    anyway, and `saveSale` threw `SqliteException(2067)` — so the sale never
    even reached the outbox. Allocation now starts above the highest receipt
    present locally for the day, inside the same transaction, and writes the
    bumped counter back. Proven live: the harness sale reached the cloud as
    `REC-20261029-0005`.
- **Master data is mutable, a ledger is not.** `user`, `product`,
  `finance_category` and `finance_entry` are re-staged with
  `ignoreDuplicates: false` and a fresh `received_at` so the newest edit wins,
  while sale/shift/cash_movement keep the one-shot ledger replay. The gateway
  maps client entity names to mirror tables, and `SyncPullApplier` lands all
  seven table groups with the one-way state rules from Phase 27 intact.
- **The tick is 3 seconds, from one constant.** `SyncIntervals.cycle` feeds
  both `main.dart::_startSyncLoop` and `SyncService.pullInterval`, so the
  cadence cannot drift apart between the timer and the pull staleness window.
  The single-flight guard (`if (_inFlight) return SyncResult.idle();`) is what
  makes 3 seconds safe: a slow cycle skips a tick rather than overlapping it and
  locking SQLite. **The PWA has no timer to change** — it is cloud-direct
  through `pos-api`, so the browser reads the live tables and its freshness is
  bounded by how fast the natives push.
- **The matrix now has a live test**
  (`app/test/integration/sync_matrix_live_test.dart`). Two registers on their
  **own SQLite files** with their own seats and licenses, plus real HTTP to
  `pos-api` as the browser. `openInMemory()` cannot be used here: under the FFI
  engine every `:memory:` handle in an isolate is the *same* database, so both
  tills would share one device, one outbox and one cursor — and the run would
  prove nothing. Opt-in through `MATRIX_CODE`/`MATRIX_USER`/`MATRIX_PASS`; with
  no credentials every test **skips**, so an offline run can never report a
  false pass. Result: A 9,338 ms, B 9,923 ms, C 9,953 / 11,521 ms, D 11,012 /
  4,588 / 10,225 ms, both outboxes drained, and the server holding **16 APPLIED
  / 0 REJECTED / 0 PENDING** for the tenant.
- **Checked in the browser too** (PWA as owner): the matrix cashiers on Users,
  the 100.00 Br sale as **VOIDED** with its reason in Sales History, the
  `Matrix Person` collection **COMPLETED** in Money Tracking and the four
  **+100.00 Br** deposits on the Register. Two UI gaps surfaced that are product
  decisions, not sync ones: **there is no product catalog screen at all**
  (`lib/features/products/` is empty, the sale dialog is free-text by design),
  so test B could only be run against `save_product` and verified on the tills;
  and a **voided sale exposes no receipt number** in the UI, only its UUID in
  the audit log.
- **A stale dev license vetoed every ship build.** `flutter build` leaves the
  output folder alone, so the `license.key` that `-IncludeMyLicense` copies in
  for the developer's own PC survived and made the cleanliness check throw on
  every later customer build. A ship build now drops it before the check, which
  still rejects a fresh copy, a local DB and any signing material.
- `flutter analyze`: clean. `dart format --set-exit-if-changed`: clean.
  `flutter test`: **353 passing** (18 new master-data tests across the outbox,
  the pull applier and the three repositories, plus the receipt-allocation
  regression). SQL applied and the `sync` function deployed with
  `--no-verify-jwt`.
- **All three artifacts rebuilt on this code**: `WholesalePOS_Windows_Release.zip`
  (16 entries, no licence, local DB or signing material), `app-release.apk`
  (59.4 MB, same package so it updates over an installed till) and the PWA
  re-pinned at `web-xi-seven-15.vercel.app` and byte-verified (3,157,883 bytes
  served = the fresh bundle).

### One deposit per collection on every surface (Phase 30)

Completing a CASH collection on a native till put the money in the register
**twice** — the cashier's own `DEPOSIT` plus a second row pulled back from the
cloud — while the PWA listed it once. The stated cause ("`pos_sync_apply` calls
`pos_complete_finance`, which inserts a second row") turned out not to be what
the code does, so both halves of the failure had to be fixed separately.

- **What the duplicate on the till actually was.** `pos_sync_apply` never calls
  `pos_complete_finance`: its `finance_entry` branch writes the entry row, and
  the deposit arrives as a separate `cash_movement` entity. The second local row
  came from `pos_add_cash_movement`, which **discarded the uuid the till sent**
  and inserted `gen_random_uuid()::text`. The device kept `UUID-1`, the pull
  handed it `UUID-2` for the same 100.00 Br, and the cloud — which held only one
  row — is exactly why the browser looked correct.
- **The genuine cloud-side double payment** is the browser/till race: whoever
  completes the entry through `pos_complete_finance` writes a deposit, and the
  pushed deposit writes another. `cash_movements_one_per_finance_entry` exists to
  stop that, but it indexes `(customer_id, source_finance_entry_id) WHERE … IS
  NOT NULL`, and the pushed row had NULL in that column — locally the column did
  not even exist.
- **Client (schema 16 → 17).** `cash_movements.source_finance_entry_id TEXT` is
  added by a guarded `ALTER TABLE` and in the fresh-install DDL.
  `FinanceRepository.markCompleted` stamps it on the movement map, which *is* the
  outbox payload, so the tag travels in the same write. `SyncPullApplier` skips a
  cloud deposit whose entry this till has already paid, and carries the column
  through, so the guard survives the next pull.
- **RPCs.** `pos_complete_finance` now inserts `IF NOT EXISTS` for that entry —
  fallback writer, not second writer. `pos_add_cash_movement` gained
  `p_movement_id` and `p_source_finance_entry_id` (both defaulted, so the
  browser's 7-argument call is unchanged), is idempotent on either key, inserts
  `ON CONFLICT (customer_id, id) DO NOTHING` with `GET DIAGNOSTICS`, and a replay
  returns the existing id **without** a second `CASH_MOVEMENT_ADDED` audit line.
  The `OPEN` shift check moved *after* the replay tests: a row re-sent after its
  shift closed is the same money already in the drawer, not a failure.
  `pos_sync_apply`'s `cash_movement` branch passes `rec.entity_id` and the entry
  id through. No TypeScript change was needed — the gateway stores
  `entry.payload` verbatim.
- **`DROP FUNCTION` first.** Adding defaulted parameters changes the signature,
  and PostgreSQL reads a different argument list as a *new* function, so the
  deployed 7-arg overload survived and the file died on `42725: function name
  "pos_add_cash_movement" is not unique` at its unqualified `REVOKE`.
- **The data repair** (`docs/supabase_finance_movement_dedupe.sql`) is a view of
  the actions plus a function that runs them: delete the newer half of a
  confirmed pair, then stamp the survivor. Delete-then-stamp is forced by the
  partial unique index — the survivor cannot claim the entry id while the tagged
  twin still exists. Pairing only accepts a **mutual nearest** match on tenant,
  type, amount, reason and a sub-day clock distance, because two collections
  from one person for the same amount are ordinary. Live result: **9 TAGGED /
  0 DELETED**, 119 movements before and after (no money left the database), and
  every completed CASH collection except one now has exactly one tagged deposit.
  Four untagged deposits were deliberately left alone — their collections no
  longer exist (orphans of deleted people), and one completed entry has no
  deposit at all, which predates this fix. The view and the function were
  dropped after the run.
- **Old duplicates on a till are not guessed at.** Migration 17 adds the column
  and rewrites nothing: an exact-twin heuristic would also delete two legitimate
  identical collections, so a device that already shows the doubled deposit keeps
  it until the drawer is reconciled by hand.
- `flutter analyze` clean, `dart format --set-exit-if-changed` clean, **357
  tests passing** (+4: the tag in the queued payload, the pull guard both ways,
  the v16→v17 column, and one-deposit-per-completion at the repository). The
  live matrix's test D no longer asks `deposits.any(...)` — it requires exactly
  one movement for the entry on the phone, exactly one in the browser's own
  ledger, and **the same id and amount on all three surfaces**. Run: A 25,818 ms,
  B 10,598 ms, C 11,854 / 11,930 ms, D 12,373 / 12,834 / 15,125 ms, both outboxes
  drained.
- **Artifacts rebuilt on this code**: `WholesalePOS_Windows_Release.zip` (16
  entries, no licence, no local DB), `app-release.apk` (59.4 MB) and the PWA
  re-pinned at `web-xi-seven-15.vercel.app`, byte-verified (3,157,883 bytes
  served = the fresh bundle).

### Training-account money stays on its own till (Phase 31)

The demo login exists so a new cashier can practise on the shop's real products
and people. Nothing anywhere stopped its rows from being queued, so every
practice sale was pushed like real money: measured live, **1,702 of 2,152 cloud
sales belonged to training accounts** (4,252 line items, 80 shifts, 76 cash
movements, 4 void requests), and one shop's dashboard reported roughly four times
what it had actually taken.

- **Three doors, not one.** The client's outbox is the obvious place, but it only
  covers tills that update. `pos_sync_apply` is the door that works against old
  builds too. The one nobody expected was `pos_create_sale`: the PWA has no local
  store, so a browser session logged in as the demo account wrote straight into
  `sales`. Three more practice receipts (`REC-20261030-0001..0003`, the largest
  10,224,070.00 Br) arrived through that door *after* the gateway guard went in —
  that is how the hole was found rather than assumed.
- **Client (`SyncOutbox`).** A `_ledgerOwners` map names the table and actor
  column per entity, and `upsert`/`delete` return before queueing when the row's
  operator has `is_demo = 1`. Central, so a future writer cannot forget it. It
  answers false when the row or the operator is unknown — a sale whose cashier
  has no account row is real money and must still sync. Master data is
  deliberately unguarded: the demo's own `user` row is how its login reaches
  every device, and products and people are shared on purpose.
- **A collection is two rows.** The deposit that pays it is written by whoever
  completed the entry, so a finance entry is judged on `created_by` **or**
  `completed_by` in both the client and the gateway. Judging only `created_by`
  would let a demo completion push the entry and hold its money — reopening the
  "completed collection with no deposit" hole Phase 30 closed.
- **The shared drawer is the reason reports had to change too.** One till keeps
  exactly one `OPEN` shift (`ensureActiveShift` plus the
  `prevent_second_open_shift_insert` trigger) and every login books onto it, so
  practice money lands in the real cashier's session. `getShiftSummary`,
  `getRegisterSnapshot` and the cash-refund sum exclude it alongside the five
  named reports, and the cloud equivalents do the same
  (`pos_shift_counters`, `pos_shift_summary`, `pos_close_shift`,
  `pos_expected_cash`) — otherwise the dashboard's revenue and its expected cash
  would disagree with each other.
- **One definition per side**: `notDemoOperator()` (`core/utils/report_filters.dart`)
  for SQLite, `pos_is_demo(uuid, text)` (`STABLE SECURITY DEFINER`, empty
  `search_path`, service_role only) for the eight report and drawer RPCs, and
  `excludeDemoRows()` in `pos-api` for the four hand-built lists, because
  PostgREST cannot express `NOT IN (SELECT …)`. The aggregates needed no
  TypeScript — `dashboard_summary`, `revenue_trend` and `report_summary` already
  call the SQL.
- **`docs/verify_demo_isolation.sql`** proves the live behaviour instead of
  asserting it: it stages a 100 Br demo sale and a demo-completed collection,
  runs the gateway, and checks nothing landed and both mirror rows were filed
  `APPLIED` with the reason (a till whose queue holds a refused entry must be
  able to drain it). Then it posts at `pos_create_sale` twice, because a refusal
  only means something next to a control: as the demo it is refused, as the owner
  it fails later on `Sale requires an open shift.` Live: `deferred: 2`, every
  `*_landed=false`, `revenue_match=true` at 46,273.10 Br, `demo_sale=refused`,
  `owner_sale=passed the flag`.
- **The cloud rows** (`docs/supabase_demo_data_cleanup.sql`) are gone: 1,703
  sales, 4,253 line items, 78 cash movements, 80 shifts, 4 void requests across
  three tenants, `kept_demo_movements: 0` — no demo deposit paid a real person's
  collection, so no completed collection lost its money (`entries_without_deposit`
  unchanged at 1, the pre-existing orphan from Phase 30). Real rows are
  untouched: 450 sales left, and the purge totals match the dry report exactly.
- **And the honest part: that purge deleted without its archive.** The rewrite
  that copies every row into `demo_purge_rows` as jsonb before deleting was
  written into the file, but the copy *installed in the database* was the earlier
  draft, because the file had not been re-applied since. The user approved "run
  it now, archive kept" and got a plain delete. The script now leads with that
  rule — a one-time SQL file IS the function, and an edit to it does nothing
  until it is applied again — with the query that shows which version is live.
  The rows themselves came from the tills that pushed them and those tills still
  hold their own SQLite copies; the three receipts that were browser-only had no
  second copy. Re-running the purge now is a no-op, and the archive table stays
  in place for anything else that needs it.
- **A training session in the browser now gets told**, rather than silently
  polluting: the five ledger RPCs raise
  `Training-account data stays on the till that made it.`
- `flutter analyze` clean, `dart format --set-exit-if-changed` clean, **368
  tests passing** (+16: nothing queued for a demo sale, void request, movement,
  shift or collection; a real one on the same shift still queues; the master-data
  and positive-control cases; and every report and drawer sum showing the shop's
  money only).
- **Artifacts**: `app-release.apk` rebuilt on this code (59.5 MB). The web bundle
  came out byte-identical (3,157,883 bytes) because the SQLite repositories are
  not reachable from `main_web.dart` — the PWA's exclusion is server-side, in
  `pos-api` and the RPCs. Those are live: the SQL is applied, and `pos-api` is
  redeployed as part of shipping this phase.

## Next Up

- Stock/inventory movements and low-stock alerts.
- Purchases, suppliers, and cost tracking.
- Credit sales, customer accounts, and receivables.
- Discounts and tax rules beyond the current zero-discount cart.
- Returns/refunds as a separate document rather than void-only.
- Fractional quantities for kg/litre products.
- Report export (CSV/PDF) and date-ranged summaries.
- Optional backend sync (the `synced_at` columns are placeholders). *(Done in Phases 11/24/25: outbox, mirror staging, licence-gated gateway, and bidirectional sync — a till now uploads its own sales and downloads every other device's.)*
- Mobile packaging: platform folders, cross-platform DB, responsive phone UI, mobile licensing, and a **signed release APK** are done; cloud sync on the phone is available behind the private-use opt-in flag (`WHOLESALE_POS_UNSAFE_EMBED_SYNC_SECRET=true`, Phase 16) for the shop's own devices, while the shippable-by-default APK keeps sync inert. Per-customer seat-based licensing is implemented end-to-end: server (Phase 17) + buyer self-service UI (Phase 17b). Deploying it takes one SQL paste and one Edge-Function paste in the Supabase dashboard (see `docs/LICENSING.md` § "Selling the app"). Remaining: anon-key+RLS backend to replace the private-use sync opt-in before wider distribution, mobile print/backup handling, and iOS (needs a Mac or paid cloud macOS CI).

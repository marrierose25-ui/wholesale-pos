# License signing and key rotation

Licenses use `base64url(canonical-json).base64url(Ed25519-signature)`. Canonical JSON is UTF-8 compact JSON with every object key recursively sorted; arrays retain order. Version 1 payloads require `format`, `version`, `product`, `entitlements`, `issued_at`, and `expires_at`. `hardware_id` is optional; when present it is checked against the machine fingerprint (Windows WMI UUID, falling back to the hostname).

Version 2 payloads (issued by the licensing Edge Function since Phase 17) additionally require `customer_id`, `activation_code`, and `device_fingerprint`. A v2 license is always bound to a specific device: on Windows the fingerprint is `sha256("win|" + motherboard UUID)`, on Android/iOS it is `sha256("and|<install_uuid>")` where the install_uuid is generated on first launch and stored in the app's SQLite `settings` table. `hardware_id` is not used in v2. The validator accepts both versions so existing `license.key` files keep working on shop PCs unchanged.

The commercial workflow that surrounds v2 — issuing a code to a new buyer, adding seats after they pay you, handling a lost phone — is described under "Selling the app (v2 licensing)" further down this file.

The app never embeds the private key. The public verification key is supplied at build time:

```powershell
flutter build windows --release `
  --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<64-hex-char-public-key>
```

When the key is absent, licensing fails closed and the activation screen explains how to configure it. The former HMAC license format is rejected; the old HMAC secret is compromised. Existing HMAC licenses must be reissued.

## Operator setup

From `app/`, run:

```powershell
dart run tools/setup_keys.dart <private-key-path-outside-project>
```

The tool refuses to write inside the repository or overwrite an existing key. It writes the private seed outside the project and prints the public key plus the exact build command. Keep the private key in an access-controlled, backed-up location and never commit it. The public key is not secret, but it is injected at build time instead of being edited into source so multiple builds can target different keys.

If the printed public key is lost, re-derive it from the escrowed seed:

```powershell
dart run tools/print_public_key.dart <private-key-path> [license-key-path]
```

The tool prints the public key and, when a license path is supplied, verifies that the license signature matches the key.

Issue a license with:

```powershell
dart run tools/generate_license.dart <hardware-id-or-> <private-key-path> <output-license-path-or->
```

Use `-` only for an intentionally unbound license. The tool refuses to overwrite an existing output. Place the resulting file next to the executable (or in the working directory) as `license.key` for the customer. `flutter build windows` replaces the executable but leaves extra files in the release folder alone, so copy `license.key` into `build\windows\x64\runner\Release\` after each clean build and include it in any distribution archive.

## Mobile activation

Phones and tablets have no file system the user can drop a `license.key` next to, so mobile uses a **one-time activation code** instead. The code is the exact same signed token (`base64url(payload).base64url(signature)`) — only the delivery changes from "a file" to "a string the owner pastes once".

- The activation screen shows a text box; whatever is entered is verified against the build-time public key with the identical Ed25519 path as desktop, and on success is persisted in the app's `settings` table (which lives in app-private storage on Android/iOS, so it is not exported and survives restarts). Nothing is stored if verification fails.
- Mobile licenses are normally **device-unbound** (no `hardware_id`), so the owner can activate any number of the business's own phones/tablets with codes you issue. A bound code still works but must match the device fingerprint.
- Mint a copy-paste code for a phone (writes no file, prints the code):

```powershell
dart run tools/generate_license.dart - <private-key-path> -
```

The resulting string is what the owner pastes into the app. It expires after one year like a desktop license; re-issue to renew. A shippable mobile build must be compiled with the real public key baked in — `flutter build apk --release --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<hex>` — and must NOT use `WHOLESALE_POS_DEV_UNLICENSED` (that bypass is for developer preview APKs only).

### Two different signing keys (do not confuse them)

- The **Ed25519 license seed** (`owner-ed25519.key`) proves a *license*. It lives outside the repo and is used only by `tools/generate_license.dart`.
- The **Android upload keystore** (`wholesale_pos_upload.jks`, `CN=Wholesale POS`) proves the *APK package identity* so Android accepts installs/updates. It is referenced by `android/key.properties` (both git-ignored) and consumed by `android/app/build.gradle.kts`; when `key.properties` is missing the release build falls back to debug signing so local `flutter run --release` still works. Back this keystore up: if it is lost you cannot publish updates that install over the existing app under the same signature.

A signed release is produced with the one-command recipe (bakes the public key AND the licensing Edge Function URL, so activation works out of the box):

```powershell
powershell -File tools\build_release.ps1 apk      # Android
powershell -File tools\build_release.ps1 windows  # Windows desktop
```

The script (`frontend/tools/build_release.ps1`) contains the shop's real public key and function URL. Building with bare `flutter build` instead of the script produces an app that cannot activate — prefer the script for every distributable.

Deliberately, the Supabase secret key is not baked into distributable builds (it would be extractable and bypass row-level security); mobile ships with sync inert by default — a phone build refuses the baked-in key unless you add the private-use opt-in `--dart-define=WHOLESALE_POS_UNSAFE_EMBED_SYNC_SECRET=true` for the shop's own devices only. See `docs/CLOUD_SYNC.md` §8a for the full trade-off and the eventual anon-key + RLS replacement.

## Selling the app (v2 licensing)

Use this section once you want to hand Wholesale POS to another business. Your own shop PC keeps working through the legacy `license.key` file (v1) forever; nothing here changes how you run your till day-to-day.

### One-time server setup (deployed ✅ — done 2026-10-24, live on project `trcthxyyuapwavzeisvm`)

The steps below were executed once and are complete; they are kept as a reference for rebuilding the environment or setting up a second project:

1. **Supabase → SQL Editor.** Ran `docs/supabase_licensing.sql` — creates `customers`, `licenses`, `device_registrations`, `seat_vouchers`, `license_audit`, the `apply_seat_voucher` RPC, indexes, RLS with no public policies, and the `license_seat_usage` view (`security_invoker = true`). Note: the explicit `grant`/`alter owner` lines were removed from the file — Supabase default privileges already cover `service_role`, and the grants failed with `42501` because schema `public` is owned by `pg_database_owner` there.
2. **Supabase → Edge Functions → create one named `licensing`.** Paste the whole of `supabase/functions/licensing/index.ts`. Uncheck "Confirm deployments manually" and "Verify JWT" (this function is authenticated by the (activation_code, device_fingerprint) pair the caller presents, not by a Supabase JWT — see the header comment in that file). Save and Deploy.
3. **Supabase → Edge Functions → Settings → Add secrets**, three of them:
   - `LICENSE_SIGNING_SEED_B64URL` — the contents of `C:\Users\www\AppData\Local\WholesalePOS\Signing\owner-ed25519.key` (a 43-char base64url string). This is the SAME private key you already use with `generate_license.dart`. The Edge Function holds it as a runtime secret; it is never in the client or in Git.
   - `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by Supabase for every Edge Function, so you normally do not need to set them. If the "Secrets" panel doesn't list them, add them (URL from Settings → API, service_role key from the same page).
4. **Redeploy** the function so the secrets are picked up.

### Selling to a new customer

1. Get paid (bank transfer, cash, Chapa — anything out of band).
2. Run the tool:
   ```powershell
   $env:SUPABASE_URL    = "https://<your-ref>.supabase.co"
   $env:SUPABASE_SECRET = "sb_secret_..."   # service_role key
   cd frontend
   dart run tools/create_customer.dart `
     --name "Mercato Textiles" `
     --seats 3 `
     --expires never
   ```
   The tool prints one `ACTIVATION_CODE=XXXX-XXXX-XXXX-XXXX-XX` line. Send that to the buyer.
3. The buyer opens the app on their first device, pastes the code into the activation screen, the app auto-generates their device fingerprint, calls the licensing function, and gets back a signed per-device license which is stored locally. They can now sell offline indefinitely.
4. Buyer installs on a second device → pastes the same code → gets another seat. Third device → same. Fourth device (if seat_limit=3) → the app shows "Seat limit reached" and points at Settings → Devices.

### Adding seats after payment

1. Buyer contacts you; you take payment out of band.
2. `dart run tools/create_seat_voucher.dart --activation-code "XXXX-…-XX" --seats 2` → prints a `VOUCHER_CODE=V-XXXXXXXX` string. Send it to the buyer.
3. Buyer pastes it into Settings → My devices → "Add more seats". The Edge Function bumps their `seat_limit` atomically via the `apply_seat_voucher` RPC; nothing on your end changes and the voucher cannot be reused (a second redemption returns "already redeemed").

### Handling a lost or replaced device

The buyer does this themselves in **Settings → My devices** (visible to the OWNER account only — cashiers cannot touch seats) — no email to you:
- The screen lists every active seat with a masked fingerprint and the device name; the caller's own row is marked "This device".
- Tap **Deactivate** on the lost phone (a confirmation dialog explains the seat becomes free immediately) → seat is freed.
- On the replacement phone, open the app → paste the same activation code on the activation screen → it takes the freed seat.

If the buyer lost their ONLY device and cannot reach Settings, use the Supabase dashboard (Table Editor → `device_registrations` filtered by `activation_code`), delete the stale row, then tell them to re-activate. This is the only support case that needs you.

### What protects you against a buyer sharing the code

A stolen code, without a matching device fingerprint, can only consume the ORIGINAL buyer's seats. It cannot create a fresh workspace for the thief, because every sync table is (or will be) partitioned by `customer_id` from the signed license. Two of the buyer's seats going to a friend means the friend sees the buyer's data (which the buyer will notice fast, and can stop from Settings → My devices by deactivating the thief's seat). Selling beyond the seat count means the friend simply cannot activate. Either way, they have to come to you for a bigger code.

The one thing software cannot stop: a buyer physically handing an already-unlocked activated phone to a friend. If that becomes a real problem, the mitigation is a per-shop PIN lock (Phase 17c).

## Server access model & security audit (Phase 19, 2026-10-24)

A full penetration test was run against the live licensing/sync backend (osv.dev dependency CVE scan, direct PostgREST/RLS probes, license forgery/tampering, SQL-injection, seat/voucher logic abuse, and an APK binary audit). The trust boundary is: **clients hold only a signed license and the anon key; every privileged operation goes through an Edge Function that authenticates that license, and the only DB role that can touch the tables is `service_role`.**

Enforced invariants (all verified live):

- **RLS default-deny everywhere.** No policies exist on any public table and `anon`/`authenticated` have `rolbypassrls = false`, so those roles read 0 rows from every licensing/mirror table. The licensing tables and the `license_seat_usage` view additionally `REVOKE ALL` from `anon`/`authenticated` as defense-in-depth.
- **Licensing RPCs are service_role-only.** `apply_seat_voucher` and `try_reserve_seat` are `SECURITY DEFINER` (they run as `postgres` and skip RLS), so `EXECUTE` is revoked from `public, anon, authenticated` and granted only to `service_role`. They are never reachable via `/rest/v1/rpc/…` with an anon key — only the Edge Function calls them.
- **Seat redemption is tenant-bound.** `apply_seat_voucher(p_voucher_code, p_activation_code)` only redeems a voucher whose parent `activation_code` equals the caller's; a foreign or guessed code returns the generic "not found", so one shop can neither burn another's voucher nor learn which voucher codes exist.
- **Activation is atomic.** `try_reserve_seat` locks the license row (`SELECT … FOR UPDATE`) around the revoked/expired check + seat count + insert, so concurrent activations cannot over-admit past `seat_limit`.
- **The sync gateway authenticates cryptographically.** Ed25519 signature, embedded expiry, license-row revocation, and an active registered seat are all checked per request; `customer_id` is taken only from the verified payload (a client cannot write into another tenant's partition); PostgREST parameterisation neutralises injection in pushed values.

Two live-exploitable defects found in that audit — cross-tenant voucher/seat theft and publicly-executable `SECURITY DEFINER` RPCs — were fixed as above and re-verified (the attack now fails; legitimate in-tenant redemption still works). See `docs/PROGRESS.md` Phase 19. The repro/verification harness is kept in `frontend/tools/sec_*.ps1`; those scripts embed the deploy token, which must be rotated.

## Development without a key

To run the app locally before a production key exists:

```powershell
flutter run -d windows --dart-define=WHOLESALE_POS_DEV_UNLICENSED=true
```

This escape hatch is compiled in only when the define is explicitly set and no public key is configured. It must never be used for a distributed build. `flutter test` does not need it; tests inject a verification key directly.

## Rotation

Generate and securely escrow a new private key, rebuild with the new `WHOLESALE_POS_LICENSE_PUBLIC_KEY`, distribute the signed application update, and reissue every license. The current verifier trusts one public key, so old licenses stop validating when the new build ships; plan an orderly transition. Removing `app/license.key` from the latest Git revision does not remove it or the old HMAC secret from public Git history. History rewriting and coordination with every clone/fork owner require a separate operator-led incident response.

## Limitations

- The license file is a signed document on disk, not a server-verified entitlement. A machine administrator can delete or restore it, but cannot forge a valid signature. *(Applies to the legacy v1 file path.)*
- v2 activation codes are verified against the licensing Edge Function at activation time and against the local signed license on every launch after that; there is no periodic phone-home. A buyer who never reconnects to the internet keeps their last-signed license until it expires — the enforcement point is device-swap and new activations, not every sale.
- The verifier rejects licenses whose `issued_at` is more than one day in the future (a coarse clock-rollback check). It does not persist the last-seen time, so a clock set backwards within the license validity window is not detected.

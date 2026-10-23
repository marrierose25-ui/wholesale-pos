# License signing and key rotation

Licenses use `base64url(canonical-json).base64url(Ed25519-signature)`. Canonical JSON is UTF-8 compact JSON with every object key recursively sorted; arrays retain order. Version 1 payloads require `format`, `version`, `product`, `entitlements`, `issued_at`, and `expires_at`. `hardware_id` is optional; when present it is checked against the machine fingerprint (Windows WMI UUID, falling back to the hostname).

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

A signed release is produced with:

```powershell
flutter build apk --release `
  --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<64-hex-char-public-key>
```

Deliberately, the Supabase secret key is not baked into distributable builds (it would be extractable and bypass row-level security); mobile ships with sync inert until an anon-key + RLS backend exists.

## Development without a key

To run the app locally before a production key exists:

```powershell
flutter run -d windows --dart-define=WHOLESALE_POS_DEV_UNLICENSED=true
```

This escape hatch is compiled in only when the define is explicitly set and no public key is configured. It must never be used for a distributed build. `flutter test` does not need it; tests inject a verification key directly.

## Rotation

Generate and securely escrow a new private key, rebuild with the new `WHOLESALE_POS_LICENSE_PUBLIC_KEY`, distribute the signed application update, and reissue every license. The current verifier trusts one public key, so old licenses stop validating when the new build ships; plan an orderly transition. Removing `app/license.key` from the latest Git revision does not remove it or the old HMAC secret from public Git history. History rewriting and coordination with every clone/fork owner require a separate operator-led incident response.

## Limitations

- The license file is a signed document on disk, not a server-verified entitlement. A machine administrator can delete or restore it, but cannot forge a valid signature.
- The verifier rejects licenses whose `issued_at` is more than one day in the future (a coarse clock-rollback check). It does not persist the last-seen time, so a clock set backwards within the license validity window is not detected.

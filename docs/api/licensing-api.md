# Licensing API

The POS licensing subsystem binds a software license to a specific device using Ed25519 digital signatures. Verification is performed at app startup and periodically thereafter.

## Activation Flow

```text
Device ──(1)──▶ License Server
    │               │
    │◀──(2)── Activation code (email/SMS)
    │
    │◀──(3)── License payload (signed)
    │
    ▼
Store locally → unlock full app
```

### Step 1 — Collect Device Fingerprint

The app computes a fingerprint from:

- Platform identifier (`windows`, `android`, `web`)
- Hardware ID (CPU serial / MAC address, abstracted via `device_info_plus`)
- A random installation UUID persisted to secure storage

### Step 2 — Redeem Activation Code

The user enters a short activation code (e.g., `WP-XXXX-XXXX-XXXX`). The code is sent to the license server (hosted at the Supabase project). The server:

1. Looks up the code in the `licenses` table.
2. Verifies it hasn't been redeemed.
3. Signs a payload binding the code to the device fingerprint.
4. Returns the signed license blob.

### Step 3 — Verify & Store

The app verifies the Ed25519 signature against a build-time embedded public key. If valid, the license is stored in encrypted settings (key `license_data`). Subsequent launches skip remote verification unless the license is near expiry.

## License Payload Shape

```typescript
interface LicensePayload {
  version: 'v1' | 'v2';
  customerId: string;       // tenant UUID
  deviceId: string;         // fingerprint hash
  issuedAt: number;         // epoch ms
  expiresAt: number;        // epoch ms
  seats: number;            // concurrent device limit
  features: string[];       // feature flags (e.g., 'warehouse')
  signature: string;        // Ed25519 hex
}
```

## Expiration Handling

| Time remaining | Behavior |
| --------------- | ---------- |
| > 30 days | Normal operation |
| 7–30 days | Warning banner; no functional restriction |
| 0–7 days | Warning banner + restricted write operations |
| Expired | Hard block on all write operations; read-only access permitted |

Grace periods are configurable at the license-server level. Client-side enforcement is absolute — tampering with local storage cannot extend expiry.

## Seat Management

A license permits up to `seats` concurrently activated devices. When activating a new device beyond the seat count:

1. The oldest inactive device is released automatically.
2. If all seats are active, the user must deactivate a device manually via **Settings → Devices**.

## Transfer Between Devices

Owners may transfer a license to a different machine:

1. Open **Settings → License → Transfer**.
2. The app sends a deactivation request to the license server for the current device fingerprint.
3. The server invalidates the old binding and issues a new code.
4. Enter the new code on the target device.

Transfers require Owner authentication and emit an audit log entry (`LICENSE_TRANSFER`).

## Security Properties

- **Key rotation:** Public keys are baked into the binary at build time. Rotations require a new app release.
- **No server secrets in the binary:** Only the public verification key is embedded. The private signing key lives exclusively on the license server.
- **Replay protection:** Each activation code is single-use. Redeemed codes cannot reactivate.

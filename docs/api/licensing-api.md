# Licensing API

The POS licensing subsystem binds software licenses to devices using Ed25519
signatures. **Policy: one activation code = one business with UNLIMITED
devices.** There are no seats and no seat vouchers.

## Surfaces

| Surface | Auth | Actions |
| --- | --- | --- |
| `licensing` Edge Function | activation code + device fingerprint (enrollment credential — NOT owner identity) | `activate_device` only |
| `pos-api` Edge Function | verified OWNER JWT (token-version checked) | `list_devices`, `deactivate_device` |

The licensing function's `list_devices`, `deactivate_device`, and
`redeem_voucher` actions are **deprecated and return HTTP 410**. Device
management moved behind owner authentication because a bare activation code
plus a fingerprint is not proof of ownership.

## Activation Flow

```text
Device ──(1)──▶ licensing Edge Function (activate_device)
    │               │
    │               ├─ rate_limit_hit (durable, HMAC-keyed)
    │               ├─ register_device RPC (license row lock:
    │               │   revoked/expired checks, idempotent fingerprint,
    │               │   reactivation, insert — atomic, unlimited)
    │               └─ Ed25519-signed license payload
    │◀──(2)── license_code (base64url(payload).base64url(sig))
    ▼
Store locally → verify offline on every launch
```

### License payload (version 2)

`format`, `version: 2`, `product`, `entitlements`, `activation_code`,
`customer_id`, `device_fingerprint`, `issued_at`, `expires_at` — canonical
JSON (recursively sorted keys, no whitespace), signed Ed25519. `expires_at`
is capped at the license row's expiry when one exists, else a rolling
year.

## Device management (pos-api, OWNER only)

- `list_devices` → `{ ok, devices: [{id, device_name, fingerprint_masked,
  activation_code_masked, first_seen, last_heartbeat, is_self}],
  active_devices }`. Full fingerprints are never returned; deactivation is
  keyed by the registration `id`.
- `deactivate_device` → `{ registration_id, device_fingerprint? }`. The
  server refuses self-deactivation (409) and returns 404 for ids outside
  the caller's tenant. Every deactivation is written to `license_audit`
  and `pos_audit_logs`.

## Rate limiting

Public endpoints (`activate_device`, `login`, `setup_owner`, `has_users`)
are throttled by `rate_limit_hit`/`rate_limit_reset` — Postgres-backed
fixed-window counters keyed by HMAC-SHA256 digests (no raw activation codes,
usernames, or IPs stored). Refusals return HTTP 429 with
`retry_after_seconds`.

## Legacy notes

- `licenses.seat_limit` and the `seat_vouchers`/`apply_seat_voucher`
  machinery are retained for historical records only; nothing enforces or
  redeems them.
- Offline signed licenses keep their own expiry semantics; revocation
  blocks future activation/sync per the sync gateway's enforcement.

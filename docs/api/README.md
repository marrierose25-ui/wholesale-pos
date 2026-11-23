# API Reference — Wholesale POS

Reference documentation for the POS API, synchronization endpoints, licensing service, and error contracts.

## Modules

| Document | Description |
|----------|-------------|
| [Authentication](authentication.md) | Login, setup_owner, session management, JWT claims |
| [pos-api Endpoints](pos-api.md) | Full action inventory across 8 modules (catalog, sales, register, finance, warehouse, reporting, users, auth) |
| [Synchronization API](synchronization-api.md) | Push/pull protocol, outbox schema, cursor semantics |
| [Licensing API](licensing-api.md) | Ed25519 activation flow, device binding, expiration handling |
| [Error Handling](error-handling.md) | HTTP status codes, error shape, retry strategies |

## Base URL

All endpoints are behind a single Supabase Edge Function:

```
https://<YOUR_PROJECT>.supabase.co/functions/v1/pos-api
```

For self-hosted deployments, replace with your gateway URL.

## Request Shape

Every mutation uses `POST` with a JSON body:

```json
{
  "action": "insert_sale",
  "payload": { ... }
}
```

Read-only actions may use `GET` where documented.

## Response Shape

**Success:**
```json
{ "ok": true, "data": { ... } }
```

**Business error (client-resolvable):**
```json
{ "ok": false, "error": "Sale not found.", "code": "NOT_FOUND" }
```

**Server error (retry-safe):**
```json
{ "ok": false, "error": "Internal error." }
```

HTTP status codes: `200` for success, `400`–`403` for client errors, `405` for wrong method, `500` for unexpected server failures.

## Authentication

Include a JWT in the `Authorization` header:

```
Authorization: Bearer <jwt_token>
```

JWT fields: `{ sub: userId, cid: customerId, role, tv: tokenVersion, exp }`.

Three actions (`login`, `setup_owner`, `has_users`) do not require authentication.

## Rate Limits

- Login/throttle: 10 attempts/min per `(customerId, username)` pair. Lockout: 5 min.
- General API: none configured at edge-function level; rely on Supabase project limits.

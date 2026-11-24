# Authentication API

## Actions

### `login`

Authenticate with username/password. Returns a JWT.

**Body:**

```json
{
  "username": "admin",
  "password": "secret123"
}
```

**Response (success):**

```json
{
  "ok": true,
  "data": {
    "token": "eyJhbGciOiJIUzI1NiIs...",
    "userId": "uuid",
    "customerId": "uuid",
    "role": "owner"
  }
}
```

**Errors:**

- `"User not found."` — 404
- `"Invalid password."` — 401
- `"Account locked."` — 423 (after 10 failed attempts in 1 min)

### `setup_owner`

Bootstrap the first owner account on a fresh shop. Idempotent — safe to call repeatedly.

**Body:**

```json
{
  "username": "owner",
  "password": "strongPassword123!",
  "phoneNumber": "0912345678"
}
```

**Response (success):**

```json
{ "ok": true, "data": { "userId": "uuid" } }
```

**Errors:**

- `"Shop already has users."` — 409 (call `login` instead)

### `has_users`

Check whether the tenant has any registered users. Used by the provisioning flow.

**Response:**

```json
{ "ok": true, "data": { "hasUsers": false } }
```

---

## Session Management

### Token revocation

Changing a password bumps the `token_version`. All existing JWTs for that user become invalid on next use (the server checks `tv` against the stored version). No explicit logout needed.

### Throttle tracking

Attempt counts reset after 1 minute of inactivity. Lockout duration is 5 minutes from the 10th failed attempt.

---

## Password Policy

| Role | Minimum length |
| --- | --- |
| Owner | 12 characters |
| All others | 8 characters |

Passwords are hashed with PBKDF2-HMAC-SHA256 at 210,000 iterations with a per-user random 16-byte salt. Legacy hashes (pre-migration) are upgraded automatically on next login.

---

## Phone Number Canonicalization

Ethiopian numbers are accepted in these forms and stored in canonical form:

- `09XXXXXXXX` or `07XXXXXXXX`
- `+2519XXXXXXXX` or `+2517XXXXXXXX` (converted to 09/07 prefix)

Somali numbers:

- `+252XXXXXXXX` stored as-is.

Invalid formats return `"Invalid phone number format."` (400).

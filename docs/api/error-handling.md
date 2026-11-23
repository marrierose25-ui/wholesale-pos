# Error Handling Reference

## Response envelope

Every API response wraps the result:

```json
{
  "ok": true,
  "data": { ... }
}
```

```json
{
  "ok": false,
  "error": "Human-readable message.",
  "code": "OPTIONAL_ERROR_CODE"
}
```

Client code should branch on `ok` first; `code` is a programmatic hint for automation.

## Business-error codes

Returned with HTTP 400–403:

| Code | Meaning | Retry? |
|------|---------|--------|
| `NOT_FOUND` | Entity doesn't exist | No — fix input |
| `CONFLICT` | Unique constraint violated | No — resolve collision |
| `FORBIDDEN` | Insufficient role (non-owner accessing OWNER_ONLY action) | No |
| `UNAUTHORIZED` | Invalid or expired JWT | Retry after re-login |
| `THROTTLED` | Too many login attempts | Wait (lockout duration) |
| `INVALID_INPUT` | Field validation failed | No — fix input |
| `LICENSE_EXPIRED` | License past expiry | Renew license |
| `LICENSE_REVOKED` | License deactivated by admin | Contact support |

## HTTP status mapping

| Status | Meaning | Typical cause |
|--------|---------|---------------|
| 200 | OK | Success |
| 400 | Bad Request | Malformed JSON, missing field |
| 401 | Unauthorized | Missing or invalid JWT |
| 403 | Forbidden | Wrong role, owner-only action, demo-user restriction |
| 405 | Method Not Allowed | Used GET on POST-only action |
| 409 | Conflict | Duplicate unique key |
| 423 | Locked | Login throttle lockout |
| 500 | Internal Server Error | Unexpected exception in Edge Function |

## Retry guidance

| Scenario | Strategy |
|----------|----------|
| Network timeout / 500 | Exponential backoff, max 3 retries |
| 401 / 403 | Invalidate cached credentials; prompt re-login |
| 423 (throttle) | Back off for the stated lockout window (usually 5 min) |
| 409 (conflict) | Refresh the entity and re-apply the mutation |
| `LICENSE_EXPIRED` | Block write path; show renewal UI |

Never retry 4xx errors blindly — they indicate client mistakes, not transient faults.

## Null-safety convention

Fields omitted from the response are null, never absent. Client code must treat missing values as `null`, not as "no data". This avoids optional-chaining bugs in the Dart layer.

## Edge Function crash handling

If an unhandled exception escapes the handler, the edge function returns:

```json
{ "ok": false, "error": "Internal error." }
```

with HTTP 500. The message is intentionally generic to avoid leaking internal details. Retry with backoff; if it persists beyond 3 attempts, surface a warning to the user and continue operating offline.

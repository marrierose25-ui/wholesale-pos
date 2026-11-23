# Backend & API

Authoritative sources: `docs/api/*`, `docs/architecture/api-action-inventory.md`,
`backend/supabase/functions/`, `docs/CLOUD_SYNC.md`, `docs/LICENSING.md`.

## Supabase Edge Functions (`backend/supabase/functions/`)

- `pos-api/` — single auth + data authority for the web/PWA build. Browsers
  never hold a Supabase key; they POST with an Edge-Function-signed session
  JWT. `customer_id` is ALWAYS carved from the verified JWT (or the shop's
  activation code at login) — never from the request body.
- `sync/` — sync gateway for native offline clients.
- `licensing/` — device activation and license issuance/validation.
- Passwords: PBKDF2-HMAC-SHA256, 210k rounds, per-user salt — identical policy
  to the native client. Sessions: stateless HMAC-SHA256 JWT.
- Deploy manually: `supabase functions deploy <name> --no-verify-jwt` plus the
  documented secrets. Never deploy without explicit authorization.
- Type-check before any function change: `deno check` on each entry point
  (`pos-api/index.ts`, `sync/index.ts`, `licensing/index.ts`).

## Package backends

- `pos_contracts` defines every repository/backend interface; implementations
  live in `pos_local_engine` (SQLite) or `pos_cloud_engine` (HTTP/Supabase).
- `AppBackend` exists twice on purpose: the pure contract in `pos_contracts`
  and the Flutter-facing seam in `frontend/lib/core/backend/app_backend.dart`
  (which adds screen factories). New backend capabilities go on the contract;
  UI factories stay on the frontend seam.

## API stability

Action signatures and response envelopes (`{ ok: true, ... }` /
`{ ok: false, error }`) are contracts — changing them requires updating the
Dart callers, `docs/api/*`, and the action inventory in the same change.

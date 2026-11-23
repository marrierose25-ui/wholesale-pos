# Testing & Regression

Authoritative sources: `docs/DEVELOPMENT.md`,
`docs/architecture/verification-history.md`, and the verification checklist in
`docs/architecture/architecture-rules.md`.

## Commands (run from `frontend/`)

- `flutter pub get`
- `flutter analyze` — must exit 0. CI runs `flutter analyze --fatal-infos`;
  info-level diagnostics fail the build, so keep imports clean.
- `flutter test` — full suite must pass.
- `dart analyze` / `dart test` inside each `backend/dart/*` package.
- `deno check backend/supabase/functions/<fn>/index.ts` for Edge Functions.

## Rules

- Tests use real SQLite (sqflite ffi) and real repositories where the original
  test did — do not replace real persistence tests with mocks.
- Preserve test scenarios, fixtures, and assertions. Never weaken a test to
  make production code pass; if a test exposes a real defect, report it.
- Historical migration behavior is guarded by fixture databases in
  `frontend/test/fixtures/database/` — extend fixtures for new versions.
- Widget tests must reflect the current `AppBackend` seam; use
  `NativeBackend(db: ..., deviceId: ..., users: ...)` for native-backed screens.
- After code changes, run `graphify update .` from the repo root (see
  `CLAUDE.md`).

## Before declaring work done

`flutter analyze` exit 0 + `flutter test` green + targeted tests for touched
areas + documentation updated. Report exact pass/fail/skip counts — never
"approximate" results.

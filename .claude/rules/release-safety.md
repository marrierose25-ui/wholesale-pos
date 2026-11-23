# Release & Deployment Safety

Authoritative sources: `docs/DEVELOPMENT.md`, `.github/workflows/`,
`docs/architecture/verification-history.md`.

## Authorization gates — never do these without explicit human approval

- `git commit`, `git push`, force-push, branch deletion, history rewrites.
- `supabase functions deploy`, `supabase db push` / migration apply.
- Any deploy of the web build, APK/AAB distribution, or store submission.
- Modifying production data or connecting tests to production services.

## Pre-release verification

- `flutter analyze` exit 0 and `flutter test` fully green.
- Release builds verified: `flutter build windows --release`,
  `flutter build web --release -t lib/main_web.dart`,
  `flutter build apk --release` (or appbundle for store).
- Edge Functions: `deno check` clean on all entry points.
- Confirm no secrets in the diff (`license.key`, `key.properties`,
  keystores are gitignored — keep them that way).

## Git preservation

The working tree holds large amounts of uncommitted migration work. Never
run `git reset`, `git clean`, `git checkout`/`git restore` to discard
changes, or mass deletions of untracked files. Stage and commit only when
explicitly asked, in logical units.

## Known release blockers (as of last audit)

- Live sync/licensing E2E (`sync_matrix_live_test`) requires dedicated
  `MATRIX_*` credentials — unverified against a live tenant.
- Pre-v6 SQLite databases cannot upgrade to v22 (documented limitation).

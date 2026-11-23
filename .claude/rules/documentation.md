# Documentation

Authoritative sources: `docs/` (see `docs/DEVELOPMENT.md` for the map).

## Rules

- Every change updates every affected document in the same change — code,
  schema, API, or behavior docs included. A feature is not complete with
  stale docs.
- `backend/supabase/migrations/` is the ONLY authoritative server schema;
  docs must point readers there, never to `docs/*.sql` (historical only).
- `docs/DATABASE.md` must reflect `schemaVersion = 22`; `docs/DEVELOPMENT.md`
  must reflect the real `frontend/` + `backend/` layout.
- Record verification evidence (commands + exact results) in
  `docs/architecture/verification-history.md` — never invent results.
- User-facing limitations (e.g. restore requires re-activation; pre-v6
  databases cannot upgrade) must be documented where users will see them.
- Do not delete historical audit/migration docs; mark them superseded instead.

## Pointers

- Architecture rules: `docs/architecture/architecture-rules.md`
- Feature/table ownership: `docs/architecture/feature-ownership.md`
- DB schema & backup/restore: `docs/DATABASE.md`
- Sync protocol: `docs/CLOUD_SYNC.md`
- Licensing: `docs/LICENSING.md`
- API contracts: `docs/api/`
- Verification log: `docs/architecture/verification-history.md`

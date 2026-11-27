# wholesale_pos

Wholesale POS — offline-first Flutter POS. Native shell in `frontend/`, shared Dart
packages in `backend/dart/` (`pos_core`, `pos_contracts`, `pos_local_engine`,
`pos_cloud_engine`), Supabase Edge Functions + migrations in `backend/supabase/`.

## The one rule that matters most

**No feature implementation is complete until it is properly owned, tested,
secured, integrated, and all affected documentation has been updated.**

## Before changing code, read the authoritative docs

Do not rely on memory or this file alone. Read the relevant document first:

| Concern | Authoritative document |
| --- | --- |
| Layering, package boundaries, sync/security rules, protected files, verification checklist | `docs/architecture/architecture-rules.md` |
| Which layer/module owns each feature and table | `docs/architecture/feature-ownership.md` |
| Build, test, Supabase, and release commands | `docs/DEVELOPMENT.md` |
| SQLite schema, migrations, backup/restore | `docs/DATABASE.md` |
| Cloud sync protocol and guarantees | `docs/CLOUD_SYNC.md` |
| Licensing model | `docs/LICENSING.md` |
| Server schema authority | `backend/supabase/migrations/` (never `docs/*.sql`) |
| Past verification evidence | `docs/architecture/verification-history.md` |

Focused rule files live in `.claude/rules/` — they summarize and point back to
these documents; the documents win on any conflict.

## Non-negotiables (summary — details in the docs above)

- **Architecture boundaries:** `pos_core` is pure Dart; `pos_contracts` is
  platform-independent; `pos_local_engine` owns SQLite/native persistence;
  `pos_cloud_engine` owns cloud transport/repositories; `frontend/` owns UI and
  composition. Never import `src/` paths, never pull Flutter/SQLite into the
  shared packages, never let the web graph reach `sqflite`/`dart:io`.
- **Contract-first:** depend on `pos_contracts` interfaces; construct concrete
  implementations (`Sqflite*Repository`, cloud repos) only at composition roots.
- **Database safety:** `schemaVersion = 22` has exactly one definition; schema
  changes go through `_onUpgrade` migrations only; migrations must be atomic and
  preserve data; never edit applied SQL migrations.
- **Offline-first:** every business write works without connectivity via the
  transactional outbox; sync is eventually consistent and must never lose or
  duplicate business data.
- **AuthN/AuthZ:** tenant isolation is enforced server-side from the verified
  JWT/activation code — never trust client-supplied `customer_id`; owner-vs-
  cashier permissions are enforced per action.
- **Testing:** `flutter analyze` must exit 0 (`--fatal-infos` in CI) and
  `flutter test` must pass before any change is considered done. Preserve test
  scenarios; do not weaken assertions to make code pass.
- **Documentation:** update every doc affected by a change in the same commit.
- **Release/deploy safety:** no deploy, push, or release without explicit human
  authorization. Edge Functions deploy manually; migrations are never applied
  to production without approval.
- **Git preservation:** the working tree may contain large amounts of
  uncommitted migration work. Never run `git reset`, `git clean`, `git checkout`
  to discard changes, or mass deletions. Do not commit, stage, push, or deploy
  unless explicitly asked.

## Codebase questions → Graphify first

A knowledge graph lives at `graphify-out/graph.json` (built by the graphify skill).

- For any question about code structure, dependencies, "what calls X", "how does Y work", or impact analysis: query the graph FIRST via the graphify skill (`graphify query`, `graphify path`, `graphify explain`) instead of grepping/reading files. Fall back to normal search only if the graph lacks the answer.
- After making code changes (edits, new files, deletions), run `graphify update .` from the repo root to refresh the graph incrementally. It only re-processes changed files and needs no LLM, so it's cheap — do it before finishing a task that touched code.

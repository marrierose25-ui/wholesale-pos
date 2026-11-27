# Development Guide — Wholesale POS

**Purpose:** Developer setup, build commands, testing, and workflow guide for the Wholesale POS project.

**Date:** 2026-11-21

---

## Project Structure

The project uses a 4-package architecture distributed under `backend/dart/`:

| Package | Path | Purpose | Runtime Dependencies |
| --- | --- | --- | --- |
| `pos_core` | `backend/dart/pos_core` | Pure Dart, zero dependencies. All business entities. | — |
| `pos_contracts` | `backend/dart/pos_contracts` | Contract/interface definitions. | `pos_core` |
| `pos_local_engine` | `backend/dart/pos_local_engine` | Local SQLite engine. | `sqflite_common_ffi`, `pos_contracts`, `pos_core` |
| `pos_cloud_engine` | `backend/dart/pos_cloud_engine` | Cloud transport, sync gateway, cloud repos. | `http`, `uuid`, `pos_contracts`, `pos_core` |
| `wholesale_pos_app` | `frontend/` | Flutter application composition (package name `wholesale_pos_app`). | All Flutter SDK + plugins; `pos_contracts`, `pos_local_engine`, `pos_cloud_engine` |

**Entry points:**

- `frontend/lib/main.dart` — Native (Flutter + SQLite + local repos)
- `frontend/lib/main_web.dart` → `app_shell.dart` — Web/PWA (Flutter + CloudBackend)

---

## Build Commands

| Command | Description | Expected Result |
| --- | --- | --- |
| `flutter analyze --fatal-infos` | Static analysis, fail on infos | **PASS** — no issues (run from `frontend/`) |
| `flutter test` | Full test suite | **PASS** — 689 passed, 1 skipped (run from `frontend/`) |
| `flutter build web --release -t lib/main_web.dart` | Web release build | **PASS** (run from `frontend/`) |
| `flutter build windows --release` | Windows release build | **PASS** — built `build/windows/x64/runner/Release/wholesale_pos_app.exe` |
| `flutter build apk --release` | Android release APK | **PASS** — `build/app/outputs/flutter-apk/app-release.apk` (release-signed via `android/key.properties`) |
| `supabase functions deploy pos-api --no-verify-jwt` | Deploy Edge Function | Manual; per `docs/LICENSING.md`; functions live in `backend/supabase/functions/` |
| `graphify update .` | Incremental knowledge graph rebuild | Cheap; no LLM needed; runs on changed files only |

---

## Test Suite

- **689 passed, 1 skipped** — live matrix across core repos, sync, licensing, and widget/layout matrices
- Widget/layout tests pump real screens through both shells (native `main.dart`, web `app_shell.dart`)
- `sync_matrix_live_test.dart` — integration test hitting live endpoints; **skipped by default** (requires `MATRIX_CODE`/`MATRIX_USER`/`MATRIX_PASS` Supabase credentials)
- Repository tests exercise the **same** repository classes the app uses (not mock-based)
- Test files mirror `frontend/lib/` structure: `frontend/test/` covers `core/...`, `features/...`

**Running specific test groups** (from `frontend/`):

- `flutter test test/core/` — core repo tests (repositories, database, licensing, sync)
- `flutter test test/features/` — feature widget/layout tests
- `flutter test test/core/sync/` — sync-specific tests

---

## Knowledge Graph Management

**Command:** `graphify update .`

- Incremental rebuild — only re-processes changed files
- No LLM needed; structurally extracts entities and relationships
- Outputs: `graphify-out/graph.json` (interactive HTML, GraphRAG-ready JSON, plain-language GRAPH_REPORT.md)
- Use `/graphify query "<question>"` to ask questions against the graph
- Build one when you expect many questions against this corpus, the corpus is large or unfamiliar, or structural questions (communities, bridges, import cycles) are needed

**Fast path:** If `graphify-out/graph.json` already exists, jump straight to `graphify query "<question>"` — no need to rebuild unless files changed.

---

## Stage Progression and Current State

The architecture migration into `frontend/` + `backend/dart/` packages is complete: all six migration batches are done, `flutter analyze` reports zero issues, the full suite passes (689 tests), and all three release builds (Windows, Web, Android APK) succeed. Key milestones:

| Stage | Completed | Current Focus |
| --- | --- | --- |
| **Stage 1** | Domain extraction (`pos_core`, `pos_contracts`, `pos_local_engine`, `pos_cloud_engine`) | Baseline established |
| **Stage 2** | Cloud backend separation (`AppBackend` seam) | In progress |
| **Stage 3** | Shell convergence (NativeBackend + AppBackend) | Deferred per Stage 9 requirements |
| **Stage 4** | Repository extraction from monolith | Completed |
| **Stage 5** | Repository responsibility map audit | Completed |
| **Stage 6** | Local engine migration | In progress |
| **Stage 7** | Cloud sync migration (`pos_cloud_engine`) | Completed |
| **Stage 8** | Supabase API modularization (index.ts → router + 28 files) | Completed |
| **Stage 9** | Documentation and schema reconciliation | Completed |
| **Stage 10** | Root cleanup, governance (`CLAUDE.md`, `.claude/rules/`), release-readiness audit | Completed |

**Current baseline checks (all pass):**

- `flutter analyze --fatal-infos` — PASS (0 issues)
- `flutter test` — 689 passed, 1 skipped
- `flutter build web --release -t lib/main_web.dart` — PASS
- `flutter build windows --release` — PASS
- `flutter build apk --release` — PASS
- `deno check backend/supabase/functions/pos-api/index.ts` (and `sync/index.ts`, `licensing/index.ts`) — exit code 0

---

## How to Run the Full Baseline Check Suite

```bash
# 1. Static analysis
flutter analyze --fatal-infos

# 2. Full test suite
flutter test

# 3. Web release build
flutter build web --release -t lib/main_web.dart

# 4. Windows release build
flutter build windows --release   # run from frontend/

# 5. Android release build
flutter build apk --release       # run from frontend/

# 6. Edge function typecheck (Deno, from repo root or backend/supabase/functions/)
deno check backend/supabase/functions/pos-api/index.ts
deno check backend/supabase/functions/sync/index.ts
deno check backend/supabase/functions/licensing/index.ts

# 7. Edge function format check
deno fmt --check backend/supabase/functions

# 8. Edge function behaviour tests (in-memory mock DB, no credentials needed)
deno test --allow-env --allow-read backend/supabase/functions/licensing/tests/
deno test --allow-env --allow-read backend/supabase/functions/pos-api/tests/
deno test --allow-env --allow-read backend/supabase/functions/sync/tests/
```

All checks must pass before considering a task complete. Any failure blocks progression.

---

## Graphify Quick Start

```bash
# If graphify-out/graph.json doesn't exist yet:
graphify .

# Query the knowledge graph:
graphify query "How does user authentication work?"

# Incremental update after code changes:
graphify update .

# Skip viz, just get report + JSON:
graphify . --no-viz
```

---

## Code Conventions

- **No new shims after 6.7** (M-24 gate from risk register)
- **Web graph must be free of sqflite/dart:io/path_provider/LocalDatabase** (F-1 gate)
- **Single source of truth for server schema:** `backend/supabase/migrations/` (16 timestamped files)
- **One `schemaVersion = 26` definition only** — in `backend/dart/pos_local_engine/lib/src/database/local_database.dart`
- **No core → features model imports** (layering violation gate)
- **Transaction inventory must remain 38** (M-07 gate)
- **pos_cloud_engine has no Flutter/sqflite/io imports** — verified by architecture test
- **Error output format:** `{ ok: true, ...data }` or `{ ok: false, error: string }`
- **JWT:** `{ sub, cid, role, tv, exp }` with HMAC-SHA256 signature, 10-year TTL, revocation via `token_version` bump
- **Password hashing:** PBKDF2-HMAC-SHA256, 210k iterations, per-user 16-byte salt, stored as `"<iterations>$<base64_hash>"`
- **Ed25519 licensing:** Build-time public key injection; v1/v2 payload formats; license signing seed stored outside repo
- **Demo account:** Permanent "demo" CASHIER account, never deactivatable, per-shop random password
- **Phone number format:** Ethiopian mobile numbers in canonical form `0[79] + 8 digits`
- **Transactional outbox:** Every business write enqueues `sync_outbox` row in same transaction
- **Sync gateway:** License-gated (Ed25519 v2 license as credential); Phase 18 feature

---

## Troubleshooting

| Problem | Solution |
| --- | --- |
| `flutter analyze` fails | Check for infos (not errors); fix analysis options if needed |
| `flutter test` skip persists | Check for integration tests requiring live Supabase credentials |
| Web build fails | Verify `lib/main_web.dart` entry point; check for `dart:io`/`sqflite` in web graph |
| Windows build fails | Ensure build tools; check `tools/build_release.ps1` output |
| Edge function TS errors | Run `deno check` on each entry point under `backend/supabase/functions/` |
| Schema version confusion | Actual: `LocalDatabase.schemaVersion = 23` in `backend/dart/pos_local_engine`; docs updated to match |

---

## End of Guide

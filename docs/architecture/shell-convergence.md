# Shell Convergence — Audit (Stage 3)

## Current architecture

**Native** (`main.dart`, ~1350 lines):
`main()` → init SQLite (`LocalDatabase.open`), repos, `SyncRuntime`,
`registerCurrentDevice` → `WholesalePosApp` (owns theme state +
MaterialApp) → `LicenseWrapper` (Ed25519 license check → `ActivationScreen`
gate) → `AuthWrapper` (session restore via `SettingsSessionStore(db)`,
remember-login, `LoginScreen`, first-owner setup) → `MainLayout`
(feature nav, sync wake/refresh, `SettingsScreen` with raw db +
syncRuntime).

**Web** (`main_web.dart` + `app_shell.dart`):
`main_web()` → `CloudBackend` (pos-api repos, `WebSessionStore`,
localStorage prefs) → `PosRoot` (theme + MaterialApp) → `AuthGate`
(session restore, `WebActivationGate` when `!isProvisioned`,
`LoginScreen`, feature nav, `WebSettingsScreen`).

## Actual differences

| Concern | Native | Web |
| --- | --- | --- |
| Startup gate | `LicenseWrapper` + `ActivationScreen` (Ed25519, device fingerprint) | `WebActivationGate` inside `AuthGate` (`isProvisioned`) |
| Session store | `SettingsSessionStore(db)` | `WebSessionStore` (localStorage + JWT rehydrate) |
| Settings screen | `SettingsScreen` (backup/restore/devices/sync tile, `LocalDataOps`) | `WebSettingsScreen` (account controls only) |
| Repos | SQLite `*_Repository(db)` | `Cloud*Repository(api)` |
| Picklists | real `PicklistRepository` | `CloudPicklistRepository` (pos-api has no endpoints — effectively stubbed) |
| Sync | `SyncRuntime` outbox engine, `_wakeSync` on local writes | none — every call is a live pos-api request |
| Theme | `WholesalePosApp` state → `'theme_mode'` setting | `PosRoot._themeMode` → same `'theme_mode'` key via `AppBackend.setSetting` |
| deviceId | `registerCurrentDevice` row | uuid in localStorage |

`AuthGate` (in `app_shell.dart`) already duplicates `AuthWrapper`'s job
generically over `AppBackend` — session restore, login, logout, remember
key. `PosRoot`'s nav builder already duplicates `MainLayout`'s destination
assembly (same `kFeatures` order, same permission filtering, same
Settings-last rule, same adaptive sidebar/drawer).

## Proposed convergence

1. `NativeBackend implements AppBackend` — wraps existing SQLite repos,
   `SettingsSessionStore`, `LocalDatabase` settings, `deviceId`,
   `SqliteLocalDataOps`. `core/backend/native_backend.dart`.
2. `PosRoot`/`AuthGate` gain two injected builders (frontend composition,
   no widgets in the contract):
   - `settingsScreenBuilder` — native passes `SettingsScreen` closure
     (captures `LocalDataOps` + `SyncRuntime`); web passes
     `WebSettingsScreen` closure.
   - `activationGateBuilder` — web passes `WebActivationGate` closure;
     native never reaches it (`isProvisioned` always true under
     `LicenseWrapper`).
   `app_shell.dart` then imports **no** `features/web` widgets → the file
   becomes platform-neutral and safe for the native compile graph.
3. `PosRoot` gains optional `onLocalActivity` callback invoked wherever
   `MainLayout` called `_wakeSync` (sale completed, shift updated) so the
   native sync engine keeps its wake semantics.
4. `main.dart`: `WholesalePosApp` keeps theme init but delegates the body
   to `LicenseWrapper(child: PosRoot(backend: nativeBackend, ...))`.
   `AuthWrapper`, `MainLayout`, and `WholesalePosApp`'s own MaterialApp
   nav/shell code are removed once PosRoot covers them.
5. `main_web.dart`: passes the two web builders explicitly; `PosRoot`
   signature stays source-compatible.

## Risks

- `AuthGate._restoreSession` vs `AuthWrapper` session-slide/remember
  semantics — verified identical paths (same `SessionStore.rememberKey`,
  same `SessionData.create` lifetime).
- Sync wake points must match `MainLayout` exactly (sale completed,
  shift updated, pull-applied refresh).
- `WebActivationGate`/`WebSettingsScreen` must leave `app_shell.dart`'s
  import set or the native build breaks (`package:web` is a compile-time
  failure on native).
- Theme persistence key must stay `'theme_mode'` on both platforms.

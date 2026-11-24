# Database Settings Inventory — Stage 6.0

**Status:** characterisation only. No settings key, value shape, writer, reader,
backup rule, or restore rule was changed to produce this document or its tests.

**Date:** 2026-11-19
**Scope:** the SQLite `settings` table on native platforms and the parallel
browser `localStorage` namespace used by the web build.

**Method:** exhaustive search for `settings` table access, settings key
constants, `getSetting`/`setSetting` calls, and the export/import allow/deny
lists; plus the new backup/restore characterisation tests.

---

## 1. Storage shape

```sql
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
```

- Introduced at schema 6 (`CREATE TABLE IF NOT EXISTS`) and created in the
  fresh v22 batch.
- No migration reads, renames, rewrites, or deletes a settings key.
- Writes are `INSERT … ON CONFLICT REPLACE` (`LocalDatabase.setSetting`,
  `SettingsSessionStore.save`, the sync cursor writer, login-guard writer, and
  the demo-password marker).
- Every value is untyped `TEXT`; readers parse JSON where needed. Finding F-8
  (untyped shared settings namespace) is **preserved**, not fixed.
- There is one physical table. Keys use prefixes rather than separate tables.

---

## 2. Native SQLite keys

| Key / prefix | Value shape | Written by | Read by | Purpose | In JSON export? | On JSON restore |
| --- | --- | --- | --- | --- | --- | --- |
| `theme_mode` | `'dark'` \| `'light'` | Shell via `NativeBackend.setSetting` → `LocalDatabase.setSetting` | `main.dart` startup (`LocalDatabase.getSetting`) | Chosen theme | **Yes** | Replaced by the backup's value |
| `remember_login` | `'0'` \| `'1'` (absence means on) | Native/web Settings via `LocalDataOps`/`AppBackend` | `app_shell.dart`, Settings screens | Persistent sign-in preference | **Yes** | Replaced by the backup's value |
| `auth_session` | JSON `{userId, token, issuedAt, expiresAt}` | `SettingsSessionStore.save` | `SettingsSessionStore.load` | Opaque local session (no password/hash) | **No** (stripped) | Deleted with the old table; absent unless the backup carried it. A matching backup is then stripped on export, so normally absent. |
| `license_code` | Signed licence payload string | `DeviceActivation.redeem` via `setSetting` | `main.dart` licence gate; `SyncGatewayBackend` | Offline-verified Ed25519 licence | **No** (stripped) | **Lost.** Restore leaves the key absent; a later restart requires re-activation. |
| `activation_code` | Short seat code | `DeviceActivation.redeem` | `SqliteLocalDataOps.activationCode` → Devices screen | Lets Settings call seat endpoints | **No** (stripped) | **Lost.** |
| `device_hw_uuid` | Windows motherboard UUID | `DeviceFingerprint.get` | `DeviceFingerprint.get` | Cache so a transient CIM failure cannot re-bind a seat | **No** (stripped) | **Lost**; recomputed/cached on next fingerprint read. |
| `device_install_uuid` | Random UUID | `DeviceFingerprint.get` (mobile fallback) | `DeviceFingerprint.get` | Reinstall-stable fallback identity | **No** (stripped) | **Lost**; a new value is generated if needed. |
| `demo_password_version` | `'2'` | `SqfliteUserRepository._markDemoPasswordVersion` | Same file | One-time marker that the published `demo1234` was retired | **Yes** | Restored. A stale backup cannot re-enable the published password because the marker is present. |
| `login_guard:<guardKey>` | JSON `{failures, locked_until}` | `SqfliteUserRepository._persistGuard` | `_loadGuard` | Failed-attempt counter + lockout deadline per login | **Yes** | Restored. A backup can therefore restore an old cooldown; no secret is involved. |
| `sync_cursor.<table>` (11 keys, one per `CloudSyncPuller.tableOrder` entry: `users`, `products`, `picklists`, `picklist_items`, `shifts`, `sales`, `sale_items`, `cash_movements`, `void_requests`, `finance_categories`, `finance_entries`) | JSON `{received_at, id}` | `CloudSyncPuller._writeCursor` | `_readCursor` | Per-table keyset cursor, written **after** a page commits | **Yes** (export) | **Deleted** by `DataImporter` (`DELETE … WHERE key LIKE 'sync_cursor.%'`) so the restored till re-reads the cloud from the start. |
| `sync_backfill.picklist_item_prices.v1` | `'1'` | `CloudSyncPuller._backfillPicklistPrices` | Same file | One-time re-read of picklist lines after the v21 price repair | **Yes** | Restored. Suppresses a redundant re-read on the restored DB. |

### Login-guard key derivation

`login_guard:<guardKey>` uses the lower-cased login identifier
(`name.toLowerCase()`), so `0911...` and `0911...` in a different case share the
same guard. Phone normalization happens before this key is built; legacy text
usernames pass through unchanged.

### Device-based login markers

`UserRepository` also stores account-level demo markers, but those live in
`users` columns (`is_demo`, `deleted_at`, `cloud_pw_hash`, `cloud_pw_salt`), not
in `settings`. They are not settings keys.

---

## 3. Device identity is two different things

| Identity | Storage | Survives JSON restore? | Notes |
| --- | --- | --- | --- |
| This installation's device id | `devices` row whose id is persisted in `device_id.txt` beside `wholesale_pos.db` | **Yes, by re-registration.** The restore replaces `devices`, then `SqliteLocalDataOps.restoreBackup` calls `LocalDatabase.registerCurrentDevice`, which reads `device_id.txt` and re-inserts the row. | Sales have a NOT NULL FK to `devices`; without re-registration every new sale would fail. The backup's own device rows remain, preserving other tills' history. |
| Platform/hardware fingerprint | `device_hw_uuid` (Windows), `device_install_uuid` (mobile fallback), platform id on Android/iOS | **No** (stripped) | Recomputed on the next fingerprint read. A restore must not copy another machine's fingerprint. |
| Seat activation code | `activation_code` | **No** | Re-entry/activation required after a restart. |
| Signed licence | `license_code` | **No** | The running process keeps its validated licence; a restart needs re-activation. |

This split is deliberate. `devices` is business history; the three settings
keys are machine-bound licensing/session state.

---

## 4. Web `localStorage` namespace

The web build never opens SQLite. `CloudBackend` maps settings onto
`localStorage` with a prefix:

| Browser key | Shape | Writer / reader | Native counterpart |
| --- | --- | --- | --- |
| `pos.setting.<key>` (e.g. `pos.setting.theme_mode`, `pos.setting.remember_login`) | String | `CloudBackend.getSetting/setSetting`; `main_web.dart` reads `pos.setting.theme_mode` on first paint | `settings` table rows |
| `pos.activation_code` | String | `CloudBackend` constructor / provisioning | `activation_code` |
| `pos.device_id` | String UUID | `CloudBackend` constructor creates it if absent | `device_id.txt` + `devices` row |
| `pos.session` | JSON session envelope (JWT) | `CloudBackend.session` | `auth_session` |

The web namespace is intentionally separate. Findings F-1 (web graph still
reaches sqflite through four files) and F-8 (untyped settings) are preserved;
Stage 6.0 does not unify the two stores.

---

## 5. Backup / restore matrix

`DataExporter.exportToJson`:

1. Reads every `settings` row.
2. Removes exactly `auth_session`, `license_code`, `activation_code`,
   `device_hw_uuid`, `device_install_uuid`.
3. Writes the remainder under `settings` in the JSON object.
4. Writes a `BACKUP_EXPORTED` audit row **after** the file is on disk.

`DataImporter.importFromJson`:

1. Validates the backup and its required `settings` columns.
2. Captures the restoring owner's live `password_hash`/`salt`.
3. Writes a recovery export (which applies the same secret stripping).
4. In one transaction, deletes **all** settings and re-inserts the backup's
   rows, then deletes `sync_cursor.%`.
5. Runs `PRAGMA foreign_key_check`, writes `BACKUP_RESTORED`, commits.
6. In `SqliteLocalDataOps`, re-registers this device from `device_id.txt`.

Consequences that must be preserved:

- A restore **loses** licence, activation, session, hardware UUID and install
  UUID. This is not a regression; the backup never carried them.
- A restore restores `theme_mode`, `remember_login`, `demo_password_version`,
  login guards, the price-backfill marker and (temporarily) sync cursors; the
  cursors are then deleted.
- A restore writes a recovery snapshot before changing anything, so even a
  failed restore leaves a usable export of the pre-restore state.

New evidence: `frontend/test/core/database/backup_export_restore_characterization_test.dart`
asserts the strip list, the loss on restore, the cursor deletion, the recovery
snapshot, and device re-registration.

---

## 6. Migration history

No migration from v2 to v22 touches `settings` rows or key names. The table is
created with `IF NOT EXISTS` at v6, so older databases gain an empty table and
keep every key they later write. There is no key rename table and no versioned
settings schema.

This is why a fresh v22 install and a v22 upgraded from v2 both use the same
lookup code; only the presence of individual keys differs.

---

## 7. Preservation rules

1. Do not rename, namespace-change, or type any existing key.
2. Do not move a key between SQLite and `localStorage`; the web and native
   stores are separate by design.
3. Do not add a secret key to the export allow-list. Update the strip list only
   with an approved security decision.
4. Do not stop deleting `sync_cursor.%` on restore without replacing it with an
   equally safe resync strategy.
5. Do not make `DataExporter` transactional while characterising F-7; that is a
   separate, approved change.
6. Keep `device_id.txt` as the source of this machine's device id and keep
   re-registration after a restore.

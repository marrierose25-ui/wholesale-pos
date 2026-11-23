# Synchronization

Authoritative sources: `docs/CLOUD_SYNC.md`,
`docs/architecture/synchronization-integrity-report.md`,
`docs/architecture/synchronization-migration-report.md`, and the sync rules
(S1–S5) in `docs/architecture/architecture-rules.md`.

## Ownership

- Contracts (`SyncBackend`, `SyncOutboxEntry`, `SyncOutboxRepository`,
  `SyncAuthException`, `NoopSyncBackend`): `pos_contracts`.
- Local outbox persistence + pull application (`SqfliteSyncOutboxRepository`,
  `SyncPullApplier`, `CloudSyncPuller`): `pos_local_engine`.
- Cloud transport (`SupabaseSyncBackend`, `SyncGatewayBackend`):
  `pos_cloud_engine`.
- Runtime (`SyncService`, `SyncRuntime`, `SyncStatus`): `frontend/lib/core/sync/`.

## Invariants — do not break

- **Transactional outbox (S1):** every business write and its outbox entry
  commit in the same SQLite transaction. Never enqueue outside the transaction,
  never drop entries silently.
- **Cursor safety (S2):** restoring a JSON backup must not resurrect an
  already-applied sync cursor.
- **License/activation on restore (S3):** secrets are stripped on export by
  design; re-activation is required after restore.
- **Backoff/retry:** preserve the existing backoff algorithm and retry
  semantics; conflicts resolve deterministically.
- **Offline-first:** the app must remain fully usable with zero connectivity;
  sync only moves data, it never gates local business operations.

## Testing

Sync behavior is covered by `frontend/test/core/sync/` (real outbox + fakes)
and `settings_sync_tile_test.dart`. `integration/sync_matrix_live_test.dart`
requires `MATRIX_CODE`/`MATRIX_USER`/`MATRIX_PASS` and writes to a live tenant —
never run it without a dedicated test environment.

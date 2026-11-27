# Troubleshooting — Wholesale POS

## Connection & Sync Issues

### "Offline" indicator stays red

- Check Wi-Fi/Ethernet connectivity.
- Verify the Supabase project URL is correct (**Settings → Sync**).
- Try **Force Sync** — if it hangs >30 s, the endpoint may be unreachable.
- On cellular networks, ensure the APN allows HTTPS outbound on port 443.

### Sync stuck pulling same page repeatedly

- Likely a network timeout. Increase the pull interval temporarily in Settings.
- Check for large result sets (>10 k rows) on any single table — paginate more aggressively in **Settings → Sync → Page Size**.

### Outbox growing without draining

- Pushes fail silently if the JWT expired. Log out and back in.
- Check the license expiry date (**Settings → License**); an expired license blocks all pushes.

## Data & Restore

### Import fails with "FK violation"

The imported data references a row (product, user, etc.) that doesn't exist in the target database. Resolution:

1. Identify the missing foreign-key reference from the error message.
2. Create the referenced row first, then re-run the import.
3. Or use the **Validate Only** checkbox before importing — it previews violations without writing.

### Export looks incomplete

The exporter reads tables sequentially without a transaction snapshot. If a sync pull interleaves between reads, a small subset of rows may be absent. Mitigation:

- Trigger an export **after** a full sync cycle completes (watch for the green checkmark).
- For critical backups, run the export twice and compare sizes.

### Restored data differs from source

Restores reset `sync_cursor:*` keys. The next pull fetches everything from the beginning, potentially overwriting local changes made since the source export was created. Always export the current device state before restoring from an older file.

## Licensing

### "License expired" after update

Licenses are binding per-device fingerprint. If the fingerprint changed (OS reinstall, hardware replacement), re-activate with the original activation code on the new device and deactivate the old one first (**Settings → Devices → Remove**).

### Can't reach the licensing server

Ed25519 verification happens against the config-supplied endpoint (`SUPABASE_URL/licensing`). Ensure DNS resolves and the endpoint is reachable. If you migrated projects, update the URL in **Settings → Sync**.

## Authentication

### "Session no longer valid" on launch

Your token version was revoked (usually after a password change on another device). Log out and back in with your credentials.

### Locked out after too many attempts

The throttle locks the account for 5 minutes. Wait it out, or have an Owner unlock the account from **Settings → Users**.

## Performance

### App feels slow on old hardware

- Disable animation effects: **Settings → Display → Reduce Motion**.
- Close background apps that consume RAM.
- Run a local rebuild (clean + rerun) occasionally; SQLite vacuum runs on app startup.

### Large sales history slows the POS screen

Sales search supports pagination (default page size 50). Use the date-range filter to narrow results. Export old data and delete selectively if the table exceeds ~50 k rows.

## Known Behaviors

| Symptom | Why | Impact |
| --------- | ----- | -------- |
| Fresh install lacks `picklist_items_picklist_id` index | Index created only during v20 upgrade path | Lookup slightly slower on brand-new installs; negligible in practice |
| `picklist_customers` doesn't sync to cloud | Intentional design decision | Local-only directory; safe to ignore |
| Pre-v6 databases cannot auto-upgrade past v5 | Migration blocked at schema version gap | Requires manual intervention; see Stage 6 documentation |
| Export omits `pw_hash` and `salt` columns | Credential protection by design | Exports are safe to share; authentication data never leaves the device |

For support beyond this document, contact the vendor with your device fingerprint and a screenshot of the Settings → About screen.

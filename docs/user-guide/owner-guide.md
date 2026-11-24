# Owner Guide — Wholesale POS

## Dashboard Overview

The dashboard shows today's KPIs: total sales, gross margin, number of transactions, and shift status. Tap any card to drill in.

## Managing Users

### Settings → Users

Actions available to Owners only:

- **Add user** — create a new cashier or staff member.
- **Edit permissions** — toggle access to Register, Finance, Warehouse, Reports, Users.
- **Deactivate** — remove access without deleting history.
- **Reset password** — send a one-time link.
- **View audit log** — see every login, permission change, and financial action.

### Permission Matrix

| Role | POS | Register | Finance | Warehouse | Reports | Users |
| ------ | ----- | ---------- | --------- | ----------- | --------- | ------- |
| Owner | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Manager | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Cashier | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Finance | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ |
| Warehouse | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ |

## Viewing Reports

**Reports** tab gives:

- **Sales summary** — daily, weekly, monthly totals with trend lines.
- **Product performance** — top-selling SKUs, low-stock alerts.
- **Audit trail** — who did what and when (read-only).

Use the date-range picker at the top-right. Export to CSV for external analysis.

## Configuring Sync

### Settings → Sync

- **Push interval** — defaults to 3 seconds when online; adaptive backoff up to 60 s during instability.
- **Pull interval** — same adaptive logic applies.
- **Force sync now** — drains the outbox immediately.
- **Disconnected** — all operations work offline; changes queue until connectivity returns.

## Licensing & Device Management

### Settings → Devices

Each activated device appears here with its fingerprint (platform + hardware ID). To transfer a license to a new machine:

1. On the old device: **Settings → License → Transfer** (requires owner auth).
2. On the new device: enter the activation code received via email/SMS.

Expired licenses show a warning banner. Contact support before expiry to avoid service interruption.

## Data Backup & Restore

### Settings → Data

- **Export** — creates a JSON snapshot of all business data. Credentials (password hashes) and sync cursors are stripped automatically.
- **Import** — restores from a previously exported file. A backup is created before the import begins.

> **Warning:** Import overwrites all existing data for the selected tables. Always export first if you might need to recover.

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
| --------- | ------------- | ----- |
| "Invalid activation code" | Code mistyped or already used | Re-check email; codes are single-use |
| Sync stuck on "connecting…" | Firewall blocking outbound HTTPS | Allow `*.supabase.co` or configure custom gateway URL |
| Can't add a second cashier | Already at seat limit | Upgrade license tier or deactivate unused seats |
| Missing products after restore | Export was older than current catalog | Re-export from source system, re-import |

For deeper help, see [Troubleshooting](troubleshooting.md).

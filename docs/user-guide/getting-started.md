# Getting Started — Wholesale POS

## 1. Install the App

**Windows (desktop):** Download `WholesalePOS_Windows_Release.zip`, extract anywhere, run `WholesalePOS.exe`.

**Android:** Install from your preferred app store or side-load the APK.

**Web (PWA):** Open the hosted URL in Chrome/Edge; tap "Install" when prompted.

## 2. First Launch & Activation

On first run you see the **Activation screen**.

1. Enter your **activation code** (a short string provided at purchase).
2. Tap **Activate**. The app contacts the licensing server, verifies the Ed25519 signature, and stores the license locally.
3. If activation fails: check your internet connection, verify the code matches exactly (no trailing spaces), then retry. A device can only be activated once per code.

## 3. Create Your Owner Account

After successful activation you are prompted to create the first user — this user is always an **Owner** with full access.

1. Choose a **username** (e.g., `admin` or your name). Use only alphanumeric characters and underscores.
2. Choose a **password** of at least 12 characters.
3. Enter your **phone number** in Ethiopian format (`09XXXXXXXX` or `07XXXXXXXX`). This is how you receive future communication; it is not a login credential by itself.
4. Confirm the password.

Your shop is now provisioned. Write down the activation code — you will need it if you reinstall on a new device.

## 4. Add Cashiers & Other Users

Log in as Owner and open **Settings → Users** (or the Users tab in the sidebar).

- Tap **+ Add User**.
- Enter username, phone, and assign a role (Cashier, Finance, etc.). The role determines which screens they can see.
- A temporary password is generated — share it securely with the user. They must change it on first login.

> **Security note:** Owner accounts cannot be deleted. Demo cashier accounts are pre-created for training and cannot be deactivated.

## 5. Configure Sync (Optional but Recommended)

If you have multiple devices or want cloud backups:

1. In **Settings → Sync**, enter your Supabase project URL and activation code.
2. Enable automatic sync. Changes push within seconds when online.
3. Devices signed into the same shop automatically stay in sync.

See the [Warehouse Guide](warehouse-guide.md) for warehouse-only setups that skip sync.

## 6. Import Existing Data

To migrate from another system:

1. Export your data from the old system (CSV, Excel, or JSON).
2. In the app: **Settings → Import Data**.
3. Select your file and follow the import wizard. The app validates FK integrity before committing.

For detailed steps see [Troubleshooting → Data Restore](troubleshooting.md).

## 7. Keyboard Shortcuts (Desktop)

| Shortcut | Action |
|----------|--------|
| `F2` | New sale |
| `F3` | Open register |
| `F4` | Finance |
| `F5` | Warehouse |
| `Esc` | Go back / close dialog |
| `Ctrl+S` | Save current form |

Full shortcut list appears in the help panel (press `?` while focused on any screen).

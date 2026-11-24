# Issuing a shop and onboarding it

Everything a shop needs, in order: one activation code, the owner's own
password, and a training account that cannot be mistaken for real trading.

> A code is a bearer credential for that shop's data. It is printed once by the
> command below and stored nowhere else; never commit it, paste it into a chat,
> or keep it in the repository.

## 1. Issue a new activation code

Run from `app/`. The service-role key is read from the environment only, so it
never reaches disk or shell history (Supabase dashboard → **Settings → API →
service_role**).

```powershell
$env:SUPABASE_URL    = "https://trcthxyyuapwavzeisvm.supabase.co"
$env:SUPABASE_SECRET = "<service_role key>"

dart run tools/create_customer.dart `
  --name "Shop Name" `
  --seats 3 `
  --expires never `
  --contact "owner@example.com"
```

It prints:

```text
CUSTOMER_ID=...
ACTIVATION_CODE=XXXX-XXXX-XXXX-XXXX-XX
SEAT_LIMIT=3
EXPIRES=never
```

- `--seats` is how many devices may be activated at once (PC + phones). Running
  out is fixed by buying a seat voucher, or by deactivating a lost device in
  **Settings → My devices** on an already-activated device.
- `--expires never` is a perpetual licence; use `--expires 2027-12-31` to
  enforce a term. The licence gate refuses an expired code at login, at setup
  and at every sync — so choose the term deliberately.
- Issue a **second, separate code** for training if the shop wants a sandbox
  (see §5).

## 2. Retire the current code (only when it should stop working)

Deleting/revoking the licence row stops the code immediately: every device using
it stops syncing and the PWA refuses login. The shop's data stays where it is.

```sql
-- Check first: which licences exist for the tenant you are retiring.
select c.name, l.seat_limit, l.expires_at, l.revoked_at, l.created_at
from licenses l join customers c on c.id = l.customer_id
order by l.created_at;
```

```sql
-- Revoke a single code (keeps the data and the seat history).
update licenses set revoked_at = now() where activation_code = '<the old code>';
```

To remove the tenant completely as well — **irreversible**, and it deletes the
shop's sales, accounts, products and audit trail:

```sql
begin;
delete from sync_mirror     where customer_id = '<customer id>';
delete from void_requests   where customer_id = '<customer id>';
delete from sale_items      where customer_id = '<customer id>';
delete from sales           where customer_id = '<customer id>';
delete from cash_movements  where customer_id = '<customer id>';
delete from shifts          where customer_id = '<customer id>';
-- licences, pos_users, pos_products, finance, audit, settings and counters
-- cascade from here.
delete from customers       where id = '<customer id>';
commit;
```

## 3. What the shop does on their side

1. Install and open the app. The activation screen appears (a fresh PC has no
   licence file).
2. Paste the code from §1 → **Activate**. The device binds to the code and the
   app can now sync.
3. **Create the owner account**: enter the owner's phone number and a password
   of their choosing (the minimum length and rules are enforced on screen). No
   password is ever issued by us — the shop types its own.
4. Sign in. **Settings → Cloud Sync** should read *Synced HH:MM · up to date
   with every device*. If it says the device is not activated, the code was
   pasted into a different device — activate this one too (same code, one seat
   each).
5. Add products, then start trading.

## 4. Additional devices

Each device runs steps 1 and 2 once with **the same code** (one seat each), then
the owner signs in with the same phone number and password.

- Login is verified offline against the account hash that sync downloaded, so a
  brand-new device can sign in before it has ever talked to the cloud.
- On sign-in the device downloads every other device's transactions; the
  dashboard, register, reports, sales and finance screens refresh as they land.
- One drawer per shop: opening a shift on a second till while the first is open
  is refused by design.

## 5. The demo account (training)

Every shop gets a permanent account named **`demo`**:

- It signs in with the username `demo` and a **random password minted per shop**
  at the first owner login. The app shows it **once**, in a dialog, right after
  the owner signs in; store it then, because it is never shown again.
- Lost it? Owner: **Users → Reset Password** on the demo row sets a known one
  before training.
- It is always a CASHIER with the default staff ticks. It can never be promoted
  to owner, can never be deactivated, and cannot change the shop's settings or
  money tracking. Its feature ticks stay editable so the owner can retrain
  different trainees.

**Does training affect the books?** The demo account lives in the *same* shop,
so its sales are real rows, attributed to cashier `demo`. They appear in
reports and totals and must be voided after the session. If the shop wants
training that cannot touch real numbers at all:

- Issue a second activation code (`--name "Shop Name TRAINING"`) and run the
  training on that tenant — for example in the PWA, which needs only a phone
  number and password (no licence file).
- Its data is completely separate: a different `customer_id`, nothing shared
  with the trading books.

## 6. Common first-day issues

| Symptom | Cause | Fix |
| --- | --- | --- |
| Activation refused | code mistyped / revoked / expired | re-paste; check `revoked_at` and `expires_at` |
| "No seats left" | every seat is used by a device | **Settings → My devices** → deactivate a lost one, or redeem a voucher |
| Settings → Cloud Sync says *not activated* | this PC still holds an older `license.key` | **Activate this device** in the same row (owner only); the local ledger is kept |
| Second device offers "create owner" | it had no licence when it pulled | activate it first, then sign in |
| PWA shows old code after a deploy | browser cache | close the tab completely and reopen |

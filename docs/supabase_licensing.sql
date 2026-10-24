-- Wholesale POS — per-customer seat-based licensing schema
--
-- RUN THIS IN THE SUPABASE SQL EDITOR once, before deploying the Edge
-- Functions in supabase/functions/. It is additive: existing mirror tables
-- (products, sales, sale_items, ...) are untouched and keep working for the
-- current desktop build. Rollout order matters — see docs/LICENSING.md
-- section "Selling the app: seat-based licensing".
--
-- What this schema delivers:
--   * customers         — a paying buyer (one shop / one business)
--   * licenses          — an activation CODE sold to that buyer, with a seat
--                         limit and optional expiry (per-customer, not fixed)
--   * device_registrations — each phone / PC that has redeemed the code,
--                         one row per active device; enforces the seat limit
--                         and powers self-service "deactivate a lost phone"
--   * seat_vouchers     — a code Umer issues after receiving payment for an
--                         extra seat, so the buyer can bump seat_limit in
--                         Settings without emailing Umer or touching the DB
--   * license_audit     — append-only trail of activation / deactivation /
--                         voucher redemption events; the only thing that
--                         shows up if a buyer disputes "I never shared my key"

-- ---------------------------------------------------------------------------
-- 1. Customers
-- ---------------------------------------------------------------------------
create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  contact       text,                       -- email / phone / whatever you used
  notes         text,
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. Licenses (one row per activation code sold)
-- ---------------------------------------------------------------------------
-- activation_code is the short human-typeable string the buyer pastes into
-- the app. Format is opaque to the DB (created by tools/create_customer.dart
-- as MERCA-XXXX-XXXX-XXXX-XX, but any unique non-empty string is valid).
create table if not exists public.licenses (
  activation_code  text primary key,
  customer_id      uuid not null references public.customers(id) on delete cascade,
  seat_limit       int  not null default 3 check (seat_limit >= 1),
  expires_at       timestamptz,             -- null = never expires
  revoked_at       timestamptz,             -- set by Umer to nuke a code
  created_at       timestamptz not null default now()
);
create index if not exists licenses_customer_idx on public.licenses (customer_id);

-- ---------------------------------------------------------------------------
-- 3. Device registrations (each active phone / PC occupying a seat)
-- ---------------------------------------------------------------------------
-- (activation_code, device_fingerprint) is unique. A device that reactivates
-- after OS reinstall finds its row and reuses it (no seat consumed twice).
-- A deactivation just stamps revoked_at, so the same fingerprint can be
-- reactivated later without losing audit history.
create table if not exists public.device_registrations (
  id                 uuid primary key default gen_random_uuid(),
  activation_code    text not null references public.licenses(activation_code)
                     on delete cascade,
  device_fingerprint text not null,
  device_name        text,                  -- "Pixel 8", "Shop PC", user-typed
  first_seen         timestamptz not null default now(),
  last_heartbeat     timestamptz,
  revoked_at         timestamptz
);
create unique index if not exists device_reg_active_unique
  on public.device_registrations (activation_code, device_fingerprint)
  where revoked_at is null;
create index if not exists device_reg_code_idx
  on public.device_registrations (activation_code)
  where revoked_at is null;

-- ---------------------------------------------------------------------------
-- 4. Seat vouchers (self-service seat expansion)
-- ---------------------------------------------------------------------------
-- create_seat_voucher.dart (Umer) inserts a row after money arrives. Buyer
-- types the voucher code into Settings -> Devices -> "Add seats", which
-- calls the redeem_voucher Edge Function. Redeemed vouchers are immutable
-- for audit; use revoke_voucher (TODO phase 17c) to void an unredeemed one.
create table if not exists public.seat_vouchers (
  voucher_code     text primary key,
  activation_code  text not null references public.licenses(activation_code)
                   on delete cascade,
  seats_added      int  not null check (seats_added >= 1),
  created_at       timestamptz not null default now(),
  redeemed_at      timestamptz
);
create index if not exists seat_voucher_code_idx
  on public.seat_vouchers (activation_code)
  where redeemed_at is null;

-- Redeeming a voucher bumps seat_limit on the parent license atomically.
-- SECURITY: the caller MUST present the same activation_code the voucher was
-- issued for (p_activation_code). Without that binding, any registered device
-- could burn another tenant's voucher the moment it guessed/leaked the code,
-- bumping the victim's seat_limit and consuming a seat the victim paid for.
-- A mismatched voucher is indistinguishable from "not found" so the endpoint
-- leaks no oracle about which voucher codes exist on OTHER licenses.
-- Drop the legacy single-argument overload first: `create or replace` with a
-- DIFFERENT signature would otherwise leave the old unbound (p_voucher_code
-- only) version live alongside the new one, and PostgREST would still let a
-- caller reach the unbound version via /rpc/apply_seat_voucher.
drop function if exists public.apply_seat_voucher(text);
create or replace function public.apply_seat_voucher(
  p_voucher_code text, p_activation_code text)
returns table (new_seat_limit int, seats_added int)
language plpgsql security definer
set search_path = public
as $$
declare
  v_row record;
  v_current_limit int;
begin
  select * into v_row from public.seat_vouchers
    where voucher_code = p_voucher_code
      and activation_code = p_activation_code   -- tenant binding
      and redeemed_at is null
    for update;
  if not found then
    raise exception 'Voucher not found or already redeemed.';
  end if;

  update public.licenses
    set seat_limit = seat_limit + v_row.seats_added
    where activation_code = v_row.activation_code
    returning seat_limit into v_current_limit;

  update public.seat_vouchers
    set redeemed_at = now()
    where voucher_code = p_voucher_code;

  return query select v_current_limit, v_row.seats_added;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3b. Atomic seat reservation (closes a TOCTOU in the activation path)
-- ---------------------------------------------------------------------------
-- The Edge Function used to SELECT the active-seat count and then INSERT in
-- two round-trips; two devices racing for the last seat could both pass the
-- count check before either insert landed. This RPC serialises on the license
-- row (SELECT ... FOR UPDATE) so the count and the insert happen under one
-- lock, and folds the revoked/expired/not-found checks in as well. It returns
-- a small JSON status the function maps to an HTTP response, plus the license
-- fields needed to mint the signed token (customer_id, expires_at).
create or replace function public.try_reserve_seat(
  p_activation_code text, p_device_fingerprint text, p_device_name text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_license public.licenses%rowtype;
  v_reg     public.device_registrations%rowtype;
  v_used    int;
begin
  -- Serialize all activations for THIS code behind the license row lock.
  select * into v_license from public.licenses
    where activation_code = p_activation_code
    for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_license.revoked_at is not null then
    return jsonb_build_object('status', 'revoked');
  end if;
  if v_license.expires_at is not null and v_license.expires_at < now() then
    return jsonb_build_object('status', 'expired');
  end if;

  -- Existing (code, fingerprint) slot? Reuse it; never consumes a new seat.
  select * into v_reg from public.device_registrations
    where activation_code = p_activation_code
      and device_fingerprint = p_device_fingerprint;
  if found then
    if v_reg.revoked_at is null then
      update public.device_registrations
        set last_heartbeat = now(), device_name = p_device_name
        where id = v_reg.id;
      select count(*) into v_used from public.device_registrations
        where activation_code = p_activation_code and revoked_at is null;
      return jsonb_build_object('status', 'refreshed', 'seats_used', v_used,
        'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
        'expires_at', v_license.expires_at);
    else
      update public.device_registrations
        set revoked_at = null, last_heartbeat = now(), device_name = p_device_name
        where id = v_reg.id;
      select count(*) into v_used from public.device_registrations
        where activation_code = p_activation_code and revoked_at is null;
      return jsonb_build_object('status', 'reactivated', 'seats_used', v_used,
        'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
        'expires_at', v_license.expires_at);
    end if;
  end if;

  -- Brand-new device: count under the held lock, then decide.
  select count(*) into v_used from public.device_registrations
    where activation_code = p_activation_code and revoked_at is null;
  if v_used >= v_license.seat_limit then
    return jsonb_build_object('status', 'seat_limit', 'seats_used', v_used,
      'seat_limit', v_license.seat_limit);
  end if;

  insert into public.device_registrations
    (activation_code, device_fingerprint, device_name, last_heartbeat)
    values (p_activation_code, p_device_fingerprint, p_device_name, now());
  return jsonb_build_object('status', 'activated', 'seats_used', v_used + 1,
    'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
    'expires_at', v_license.expires_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3c. Lock the licensing RPCs to service_role only
-- ---------------------------------------------------------------------------
-- Supabase's default privileges grant EXECUTE on every new public function to
-- the `public` role group, which anon + authenticated inherit. That would let
-- anyone POST /rest/v1/rpc/apply_seat_voucher or /rpc/try_reserve_seat with a
-- service-less anon key and mutate seat state directly, bypassing the Edge
-- Function's registered-device check and rate shaping. These SECURITY DEFINER
-- functions run as their owner (postgres) and skip RLS, so they must NOT be
-- publicly executable. Only the Edge Functions (service_role) call them.
revoke execute on function public.apply_seat_voucher(text, text) from public, anon, authenticated;
revoke execute on function public.try_reserve_seat(text, text, text) from public, anon, authenticated;
grant  execute on function public.apply_seat_voucher(text, text) to service_role;
grant  execute on function public.try_reserve_seat(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. Audit log (append-only; every state-changing licensing action writes here)
-- ---------------------------------------------------------------------------
create table if not exists public.license_audit (
  id                 bigint generated always as identity primary key,
  activation_code    text not null,
  device_fingerprint text,
  event              text not null,        -- activate|deactivate|voucher_redeem|revoked
  detail             jsonb,
  occurred_at        timestamptz not null default now()
);
create index if not exists license_audit_code_idx
  on public.license_audit (activation_code, occurred_at desc);

-- ---------------------------------------------------------------------------
-- 6. Row-Level Security
-- ---------------------------------------------------------------------------
-- All five licensing tables are reachable ONLY by the service-role key (used
-- by the Edge Functions). The anon key — the one a distributed client would
-- ever hold — cannot read or write them. This is what prevents a patched
-- client from enumerating customers, listing seats, or forging activations
-- via the REST API: the Edge Functions do the only allowed operations and
-- enforce seat logic in code we control.
alter table public.customers           enable row level security;
alter table public.licenses            enable row level security;
alter table public.device_registrations enable row level security;
alter table public.seat_vouchers       enable row level security;
alter table public.license_audit       enable row level security;

-- No policies on purpose: RLS denies all reads/writes to anon + authenticated
-- roles. Service role (used by the Edge Functions) always bypasses RLS.

-- Defense-in-depth: Supabase's default privileges GRANT every public table to
-- anon + authenticated. RLS already hides all rows from those roles (0 policy
-- hits, proven), but an explicit REVOKE means even a future "enable RLS off"
-- or an accidental permissive policy cannot instantly expose activation codes,
-- customer PII, or seat state. Only service_role (Edge Functions) keeps access.
revoke all on public.customers            from anon, authenticated;
revoke all on public.licenses             from anon, authenticated;
revoke all on public.device_registrations from anon, authenticated;
revoke all on public.seat_vouchers         from anon, authenticated;
revoke all on public.license_audit         from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Convenience view: current seat usage per license
-- ---------------------------------------------------------------------------
create or replace view public.license_seat_usage as
select
  l.activation_code,
  l.customer_id,
  c.name                                  as customer_name,
  l.seat_limit,
  count(d.id) filter (where d.revoked_at is null) as seats_used,
  l.expires_at,
  l.revoked_at,
  l.created_at
from public.licenses l
join public.customers c on c.id = l.customer_id
left join public.device_registrations d on d.activation_code = l.activation_code
group by l.activation_code, l.customer_id, c.name, l.seat_limit,
         l.expires_at, l.revoked_at, l.created_at;

-- Force the view to respect the caller's RLS policies rather than running
-- with the view owner's (postgres) privileges. Without this, any role that
-- is granted SELECT on the view would bypass RLS on the underlying tables.
alter view public.license_seat_usage set (security_invoker = true);

-- Belt-and-suspenders: explicitly deny anon/authenticated from querying the
-- view even if a future grant is added by mistake.
revoke all on public.license_seat_usage from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Service-role access note
-- ---------------------------------------------------------------------------
-- The Edge Function authenticates with the Supabase service_role key, which
-- automatically has full access to every table in the public schema via
-- Supabase's built-in default privileges (ALTER DEFAULT PRIVILEGES for role
-- postgres already grants ALL to service_role on new tables/sequences).
--
-- We intentionally do NOT include explicit GRANT or ALTER OWNER statements
-- here because on many Supabase projects the `postgres` SQL Editor session
-- lacks GRANT OPTION on schema public (the schema is owned by
-- pg_database_owner), causing 42501 "permission denied for schema public".
--
-- If you need to verify service_role can see the tables, run:
--   select has_table_privilege('service_role', 'public.customers', 'SELECT');
-- Expected: true. If it returns false (very rare), go to Supabase Dashboard
-- → Database → Roles → service_role → grant manually via the UI.
--
-- The apply_seat_voucher function is SECURITY DEFINER, so it runs as its
-- creator (postgres). No ownership transfer needed.

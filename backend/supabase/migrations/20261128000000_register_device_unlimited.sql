-- Request 2 / licensing hardening: one activation code = one business with
-- UNLIMITED devices.
--
-- Replaces the seat-cap machinery for new activations. `try_reserve_seat`
-- stays in place for backwards compatibility but the licensing Edge Function
-- no longer calls it: its 'seat_limit' status used to force a non-atomic
-- fallback INSERT outside the license-row transaction, which raced with
-- revocation, duplicate fingerprints, and concurrent activations.
--
-- `register_device` performs the WHOLE activation decision inside one
-- transaction serialized on the license row (SELECT ... FOR UPDATE):
--   1. lock the license row;
--   2. refuse unknown / revoked / expired codes;
--   3. refresh an existing ACTIVE (code, fingerprint) registration — checked
--      FIRST so a stale revoked row can never collide with it on the
--      device_reg_active_unique index;
--   4. otherwise reactivate ONE deterministic revoked registration for the
--      same fingerprint (latest revocation wins; ties broken by id);
--   5. insert a brand-new registration — no seat count is consulted;
--   6. return the tenant + expiry fields the Edge Function needs to mint
--      the signed license.
--
-- seat_limit / seats_used are still returned (seat_limit is the legacy
-- column value, seats_used the live active-device count) purely so the API
-- response shape stays compatible; neither gates admission anymore.

CREATE OR REPLACE FUNCTION public.register_device (
  p_activation_code    text,
  p_device_fingerprint text,
  p_device_name        text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_license public.licenses%rowtype;
  v_reg     public.device_registrations%rowtype;
  v_used    int;
begin
  -- Serialize ALL activations for this code behind the license row lock, so
  -- a concurrent revocation cannot interleave with a registration and two
  -- requests for the same fingerprint cannot both insert.
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

  -- Existing ACTIVE (code, fingerprint) row? Reuse it; never inserts a
  -- duplicate. This is checked BEFORE any revoked row: a fingerprint can
  -- accumulate several historical revoked registrations, and reactivating
  -- one of those while an active row already exists would violate
  -- device_reg_active_unique.
  select * into v_reg from public.device_registrations
    where activation_code = p_activation_code
      and device_fingerprint = p_device_fingerprint
      and revoked_at is null;
  if found then
    update public.device_registrations
      set last_heartbeat = now(), device_name = p_device_name
      where id = v_reg.id;
    select count(*) into v_used from public.device_registrations
      where activation_code = p_activation_code and revoked_at is null;
    return jsonb_build_object('status', 'refreshed', 'seats_used', v_used,
      'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
      'expires_at', v_license.expires_at);
  end if;

  -- No active row. Reactivate ONE revoked registration for the same
  -- fingerprint, chosen deterministically (most recently revoked, then id)
  -- so repeated activations always converge on the same row instead of
  -- bouncing between historical duplicates.
  select * into v_reg from public.device_registrations
    where activation_code = p_activation_code
      and device_fingerprint = p_device_fingerprint
      and revoked_at is not null
    order by revoked_at desc, id
    limit 1;
  if found then
    update public.device_registrations
      set revoked_at = null, last_heartbeat = now(), device_name = p_device_name
      where id = v_reg.id;
    select count(*) into v_used from public.device_registrations
      where activation_code = p_activation_code and revoked_at is null;
    return jsonb_build_object('status', 'reactivated', 'seats_used', v_used,
      'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
      'expires_at', v_license.expires_at);
  end if;

  -- Brand-new device. Unlimited policy: no seat count is consulted. The
  -- license-row lock above still serializes this insert against concurrent
  -- activations for the same code, and device_reg_active_unique backstops
  -- the (activation_code, device_fingerprint) pair.
  insert into public.device_registrations
    (activation_code, device_fingerprint, device_name, last_heartbeat)
    values (p_activation_code, p_device_fingerprint, p_device_name, now());
  select count(*) into v_used from public.device_registrations
    where activation_code = p_activation_code and revoked_at is null;
  return jsonb_build_object('status', 'activated', 'seats_used', v_used,
    'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
    'expires_at', v_license.expires_at);
end;
$function$;

REVOKE ALL ON FUNCTION "public"."register_device"(text, text, text) FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "public"."register_device"(text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."register_device"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."register_device"(text, text, text) TO "postgres";

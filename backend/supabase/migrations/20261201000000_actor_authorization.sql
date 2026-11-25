-- Request 3 — device licence vs user authorization, and ledger protection.
--
-- Background: a signed device licence is a bearer document. It proves that a
-- genuine licence was issued for (activation_code, device_fingerprint) and that
-- the pair still has an active registration. It does NOT prove which human is
-- operating the till, and it is not hardware-bound proof-of-possession.
--
-- Before this migration `pos_sync_apply` trusted actor ids inside the pushed
-- payload (`cashier_id`, `user_id`, `created_by`, `requested_by`, and even
-- `pw_hash`/`pw_salt` for an account row). Any licensed device could therefore
-- forge an owner-authorized sale, cash movement, finance completion, account
-- promotion, or credential replacement. This migration closes that boundary:
--
--   * `actor_grants` holds an opaque, server-issued, device-bound delegation
--     token. It is minted only after password + device-licence authentication
--     through `pos-api` (`issue_actor_grant`) and stored only as a SHA-256 hash.
--   * The sync gateway hashes the client-supplied grant before staging it in
--     `sync_mirror.actor_grant_hash`. `pos_sync_apply` resolves that hash to a
--     live user row and uses the resolved user for every actor column. Actor
--     ids in the payload are ignored.
--   * A missing/expired/revoked grant leaves the mirror row PENDING with an
--     `ACTOR_AUTH_REQUIRED` error and reports it as deferred. The client keeps
--     its outbox row; nothing is silently discarded or marked synced.
--   * Owner accounts are never mutable through device sync. New accounts can
--     only be CASHIER accounts, created by an owner grant; credential changes
--     for an existing account are ignored by sync and must go through the
--     live, owner-authenticated `pos-api` surface.
--   * Finance entries are always written as PENDING. A client may request
--     completion/deletion, but the actual transition goes through the existing
--     row-locked RPC with the resolved actor, never with client-supplied
--     `completed_by`/`completed_at`.
--   * The money/warehouse RPCs now assert the resolved actor's feature
--     permission as defence in depth, so even a service-role caller cannot
--     drive a sale/cash/finance/warehouse mutation as an unauthorized user.
--
-- Policy is unchanged: ONE activation code = ONE business with UNLIMITED
-- devices. No seat limits, vouchers, or device caps are introduced here.

-- ===========================================================================
-- 1. Server-issued actor grants
-- ===========================================================================

CREATE TABLE IF NOT EXISTS public.actor_grants (
  grant_hash          text                     NOT NULL,
  customer_id         uuid                     NOT NULL,
  user_id             text                     NOT NULL,
  device_fingerprint  text                     NOT NULL,
  -- Snapshot of the account's token_version at issuance. Any credential or
  -- status change bumps token_version, so every outstanding grant for that
  -- account stops resolving without a separate cleanup race.
  token_version       integer                  NOT NULL DEFAULT 0,
  issued_at           timestamp with time zone NOT NULL DEFAULT now(),
  expires_at          timestamp with time zone NOT NULL,
  revoked_at          timestamp with time zone,
  last_used_at        timestamp with time zone,
  CONSTRAINT actor_grants_pkey PRIMARY KEY (grant_hash),
  CONSTRAINT actor_grants_customer_fkey FOREIGN KEY (customer_id)
    REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT actor_grants_expiry_check CHECK (expires_at > issued_at)
);

ALTER TABLE public.actor_grants ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS actor_grants_customer_user
  ON public.actor_grants (customer_id, user_id);
CREATE INDEX IF NOT EXISTS actor_grants_customer_device
  ON public.actor_grants (customer_id, device_fingerprint);

REVOKE ALL ON TABLE public.actor_grants FROM PUBLIC, "anon", "authenticated";
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.actor_grants TO "service_role";
REVOKE ALL ON TABLE public.actor_grants FROM "postgres";
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.actor_grants TO "postgres";

-- The staging row carries only the digest of the grant the client presented.
-- The raw token never reaches Postgres or the mirror table.
ALTER TABLE public.sync_mirror
  ADD COLUMN IF NOT EXISTS actor_grant_hash text;

CREATE OR REPLACE FUNCTION public.pos_actor_grant_hash(p_token text)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT CASE
    WHEN p_token IS NULL OR btrim(p_token) = '' THEN NULL
    ELSE encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  END;
$function$;

REVOKE ALL ON FUNCTION public.pos_actor_grant_hash(text) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_actor_grant_hash(text) TO "service_role";
REVOKE ALL ON FUNCTION public.pos_actor_grant_hash(text) FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_actor_grant_hash(text) TO "postgres";

-- Mint a grant for an already-authenticated (password + device licence)
-- caller. Only pos-api calls this, with service_role. The raw token is
-- returned exactly once; only its SHA-256 digest is stored.
CREATE OR REPLACE FUNCTION public.pos_issue_actor_grant(
  p_customer            uuid,
  p_user                text,
  p_device_fingerprint  text,
  p_ttl_seconds         integer DEFAULT 2592000
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_token    text;
  v_hash     text;
  v_expires  timestamp with time zone;
  v_ttl      integer;
  v_tv       integer;
BEGIN
  IF p_customer IS NULL OR p_user IS NULL OR btrim(p_user) = ''
     OR p_device_fingerprint IS NULL OR btrim(p_device_fingerprint) = '' THEN
    RAISE EXCEPTION 'A user and device fingerprint are required.';
  END IF;

  -- The user must be a live account of this tenant. Role/permissions are
  -- re-read on every resolve, so a demotion takes effect immediately; the
  -- token_version snapshot invalidates the grant on any credential/status
  -- change.
  SELECT token_version INTO v_tv
  FROM public.pos_users
  WHERE customer_id = p_customer AND id = p_user
    AND active = true AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not active.';
  END IF;

  -- A grant is bound to a device that is actually registered for one of the
  -- tenant's licences. The Edge Function has already verified the signed
  -- licence; this is defence in depth against a direct service-role mistake.
  IF NOT EXISTS (
    SELECT 1
    FROM public.device_registrations d
    JOIN public.licenses l ON l.activation_code = d.activation_code
    WHERE l.customer_id = p_customer
      AND d.device_fingerprint = p_device_fingerprint
      AND d.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Device is not registered for this tenant.';
  END IF;

  v_ttl := greatest(300, least(coalesce(p_ttl_seconds, 2592000), 7776000));
  v_expires := now() + make_interval(secs => v_ttl);
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_hash := public.pos_actor_grant_hash(v_token);

  -- One live grant per (user, device): issuing a new one retires the old.
  UPDATE public.actor_grants
  SET revoked_at = now()
  WHERE customer_id = p_customer
    AND user_id = p_user
    AND device_fingerprint = p_device_fingerprint
    AND revoked_at IS NULL;

  INSERT INTO public.actor_grants
    (grant_hash, customer_id, user_id, device_fingerprint, token_version,
     expires_at)
  VALUES (v_hash, p_customer, p_user, p_device_fingerprint, v_tv, v_expires);

  RETURN jsonb_build_object(
    'grant', v_token,
    'expires_at', v_expires);
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_issue_actor_grant(uuid, text, text, integer)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_issue_actor_grant(uuid, text, text, integer)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_issue_actor_grant(uuid, text, text, integer)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_issue_actor_grant(uuid, text, text, integer)
  TO "postgres";

-- Revoke grants on credential/status changes or device deactivation.
-- At least one filter is required so a tenant-wide accident is impossible.
CREATE OR REPLACE FUNCTION public.pos_revoke_actor_grants(
  p_customer            uuid,
  p_user                text DEFAULT NULL,
  p_device_fingerprint  text DEFAULT NULL
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_count integer;
BEGIN
  IF p_customer IS NULL
     OR (p_user IS NULL AND p_device_fingerprint IS NULL) THEN
    RAISE EXCEPTION 'A user or device fingerprint filter is required.';
  END IF;

  UPDATE public.actor_grants
  SET revoked_at = now()
  WHERE customer_id = p_customer
    AND revoked_at IS NULL
    AND (p_user IS NULL OR user_id = p_user)
    AND (p_device_fingerprint IS NULL
         OR device_fingerprint = p_device_fingerprint);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_revoke_actor_grants(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_revoke_actor_grants(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_revoke_actor_grants(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_revoke_actor_grants(uuid, text, text)
  TO "postgres";

-- Resolve a presented grant to a live user of the tenant. The device
-- fingerprint is part of the match, so a token copied from another device is
-- useless even if the licence is replayed.
CREATE OR REPLACE FUNCTION public.pos_resolve_actor_grant(
  p_customer            uuid,
  p_grant_hash          text,
  p_device_fingerprint  text
)
  RETURNS TABLE (user_id text, role text, permissions jsonb)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_user text;
BEGIN
  IF p_customer IS NULL OR p_grant_hash IS NULL OR btrim(p_grant_hash) = ''
     OR p_device_fingerprint IS NULL OR btrim(p_device_fingerprint) = '' THEN
    RETURN;
  END IF;

  UPDATE public.actor_grants g
  SET last_used_at = now()
  FROM public.pos_users u
  WHERE g.grant_hash = p_grant_hash
    AND g.customer_id = p_customer
    AND g.device_fingerprint = p_device_fingerprint
    AND g.revoked_at IS NULL
    AND g.expires_at > now()
    AND u.customer_id = g.customer_id
    AND u.id = g.user_id
    AND u.active = true
    AND u.deleted_at IS NULL
    AND u.token_version = g.token_version
  RETURNING g.user_id INTO v_user;

  IF v_user IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT u.id, u.role, u.permissions
    FROM public.pos_users u
    WHERE u.customer_id = p_customer
      AND u.id = v_user
      AND u.active = true
      AND u.deleted_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_resolve_actor_grant(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_resolve_actor_grant(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_resolve_actor_grant(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_resolve_actor_grant(uuid, text, text)
  TO "postgres";

-- ===========================================================================
-- 2. Feature assertions (defence in depth for the money RPCs)
-- ===========================================================================
-- OWNER is all-access. A CASHIER needs the matching tick. These helpers read
-- the live row, so removing a permission takes effect on the next call.

CREATE OR REPLACE FUNCTION public.pos_user_has_feature(
  p_customer uuid,
  p_user     text,
  p_feature  text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.pos_users u
    WHERE u.customer_id = p_customer
      AND u.id = p_user
      AND u.active = true
      AND u.deleted_at IS NULL
      AND (u.role = 'OWNER' OR u.permissions ? p_feature)
  );
$function$;

CREATE OR REPLACE FUNCTION public.pos_user_has_any_feature(
  p_customer uuid,
  p_user     text,
  p_features text[]
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.pos_users u
    WHERE u.customer_id = p_customer
      AND u.id = p_user
      AND u.active = true
      AND u.deleted_at IS NULL
      AND (u.role = 'OWNER' OR u.permissions ?| p_features)
  );
$function$;

CREATE OR REPLACE FUNCTION public.pos_require_feature(
  p_customer uuid,
  p_user     text,
  p_feature  text
)
  RETURNS void
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  IF NOT public.pos_user_has_feature(p_customer, p_user, p_feature) THEN
    RAISE EXCEPTION 'Not authorized: % permission required.', p_feature
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_require_any_feature(
  p_customer uuid,
  p_user     text,
  p_features text[]
)
  RETURNS void
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  IF NOT public.pos_user_has_any_feature(p_customer, p_user, p_features) THEN
    RAISE EXCEPTION 'Not authorized: one of % is required.', p_features
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_user_has_feature(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_user_has_feature(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_user_has_feature(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_user_has_feature(uuid, text, text)
  TO "postgres";

REVOKE ALL ON FUNCTION public.pos_user_has_any_feature(uuid, text, text[])
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_user_has_any_feature(uuid, text, text[])
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_user_has_any_feature(uuid, text, text[])
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_user_has_any_feature(uuid, text, text[])
  TO "postgres";

REVOKE ALL ON FUNCTION public.pos_require_feature(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_require_feature(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_require_feature(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_require_feature(uuid, text, text)
  TO "postgres";

REVOKE ALL ON FUNCTION public.pos_require_any_feature(uuid, text, text[])
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_require_any_feature(uuid, text, text[])
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_require_any_feature(uuid, text, text[])
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_require_any_feature(uuid, text, text[])
  TO "postgres";

-- ===========================================================================
-- 3. Permission wrappers around the money/warehouse RPCs
-- ===========================================================================
-- Rename the baseline implementations, then expose a checked wrapper with the
-- original signature. Existing callers (pos-api and pos_sync_apply) keep the
-- same contract; a caller that skips the wrapper cannot reach the money path
-- because the unchecked function is service-role-only.

ALTER FUNCTION public.pos_create_sale(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  RENAME TO pos_create_sale_unchecked;

CREATE OR REPLACE FUNCTION public.pos_create_sale(
  p_customer      uuid,
  p_cashier       text,
  p_device        text,
  p_shift_id      text,
  p_receipt       text,
  p_items         jsonb,
  p_payment       text,
  p_discount      bigint,
  p_amount_paid   bigint,
  p_customer_name text   DEFAULT NULL::text,
  p_sale_id       text   DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_cashier, 'pos');
  RETURN public.pos_create_sale_unchecked(
    p_customer, p_cashier, p_device, p_shift_id, p_receipt, p_items,
    p_payment, p_discount, p_amount_paid, p_customer_name, p_sale_id);
END;
$function$;

ALTER FUNCTION public.pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text)
  RENAME TO pos_add_cash_movement_unchecked;

CREATE OR REPLACE FUNCTION public.pos_add_cash_movement(
  p_customer                uuid,
  p_user                    text,
  p_shift_id                text,
  p_type                    text,
  p_amount                  bigint,
  p_reason                  text,
  p_photo                   text,
  p_movement_id             text   DEFAULT NULL::text,
  p_source_finance_entry_id text   DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_user, 'register');
  RETURN public.pos_add_cash_movement_unchecked(
    p_customer, p_user, p_shift_id, p_type, p_amount, p_reason, p_photo,
    p_movement_id, p_source_finance_entry_id);
END;
$function$;

ALTER FUNCTION public.pos_complete_finance(uuid, text, text)
  RENAME TO pos_complete_finance_unchecked;

CREATE OR REPLACE FUNCTION public.pos_complete_finance(
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_user, 'finance');
  PERFORM public.pos_complete_finance_unchecked(
    p_customer, p_user, p_entry_id);
END;
$function$;

ALTER FUNCTION public.pos_delete_finance_entry(uuid, text, text)
  RENAME TO pos_delete_finance_entry_unchecked;

CREATE OR REPLACE FUNCTION public.pos_delete_finance_entry(
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_user, 'finance');
  PERFORM public.pos_delete_finance_entry_unchecked(
    p_customer, p_user, p_entry_id);
END;
$function$;

ALTER FUNCTION public.pos_delete_finance_category(uuid, text, text)
  RENAME TO pos_delete_finance_category_unchecked;

CREATE OR REPLACE FUNCTION public.pos_delete_finance_category(
  p_customer uuid,
  p_id       text,
  p_user     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_user, 'finance');
  PERFORM public.pos_delete_finance_category_unchecked(
    p_customer, p_id, p_user);
END;
$function$;

ALTER FUNCTION public.pos_open_shift(uuid, text, text, bigint)
  RENAME TO pos_open_shift_unchecked;

CREATE OR REPLACE FUNCTION public.pos_open_shift(
  p_customer uuid,
  p_user     text,
  p_device   text,
  p_opening  bigint
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_user, 'register');
  RETURN public.pos_open_shift_unchecked(
    p_customer, p_user, p_device, p_opening);
END;
$function$;

ALTER FUNCTION public.pos_close_shift(uuid, text, text, bigint)
  RENAME TO pos_close_shift_unchecked;

CREATE OR REPLACE FUNCTION public.pos_close_shift(
  p_customer uuid,
  p_user     text,
  p_shift_id text,
  p_closing  bigint
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.pos_require_feature(p_customer, p_user, 'register');
  RETURN public.pos_close_shift_unchecked(
    p_customer, p_user, p_shift_id, p_closing);
END;
$function$;

-- Unchecked implementations are not callable by clients. The wrappers run as
-- the owner, so they keep their access.
REVOKE ALL ON FUNCTION public.pos_create_sale_unchecked(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_add_cash_movement_unchecked(
  uuid, text, text, text, bigint, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_complete_finance_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_delete_finance_category_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_open_shift_unchecked(uuid, text, text, bigint)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_close_shift_unchecked(uuid, text, text, bigint)
  FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION public.pos_create_sale(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_create_sale(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_create_sale(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_create_sale(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_complete_finance(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_complete_finance(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_complete_finance(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_complete_finance(uuid, text, text)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_delete_finance_entry(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_delete_finance_entry(uuid, text, text)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_delete_finance_category(uuid, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_category(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_delete_finance_category(uuid, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_delete_finance_category(uuid, text, text)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_open_shift(uuid, text, text, bigint)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_open_shift(uuid, text, text, bigint)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_open_shift(uuid, text, text, bigint)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_open_shift(uuid, text, text, bigint)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_close_shift(uuid, text, text, bigint)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_close_shift(uuid, text, text, bigint)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_close_shift(uuid, text, text, bigint)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_close_shift(uuid, text, text, bigint)
  TO "postgres";

-- ===========================================================================
-- 4. pos_sync_apply — resolve an actor, ignore payload actor claims
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.pos_sync_apply (
  p_customer            uuid,
  p_limit               integer,
  p_device_fingerprint  text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  rec              record;
  applied          int := 0;
  rejected         int := 0;
  deferred         int := 0;
  left_over        int := 0;
  s                jsonb;
  items            jsonb;
  shift_id         text;
  device           text;
  mv               jsonb;
  vr               jsonb;
  us               jsonb;
  pr               jsonb;
  fc               jsonb;
  fe               jsonb;
  pk               jsonb;
  pi               jsonb;
  sale_row         record;
  cat_row          record;
  user_row         record;
  pl_row           text;
  perms            jsonb;
  skipped          int := 0;
  v_actor_id       text;
  v_actor_role     text;
  v_actor_perms    jsonb;
  v_existing_role  text;
  v_entry_status   text;
  v_new_active     bool;
  v_new_deleted    timestamptz;
  v_defer_reason   text;
BEGIN
  FOR rec IN
    SELECT entity_type, entity_id, operation, device_id, payload,
           actor_grant_hash
    FROM public.sync_mirror
    WHERE customer_id = p_customer AND apply_status = 'PENDING'
    -- Parents before children, whatever order they arrived in.
    ORDER BY CASE entity_type
        WHEN 'user'              THEN 0
        WHEN 'product'           THEN 1
        WHEN 'finance_category'  THEN 2
        WHEN 'shift'             THEN 3
        WHEN 'sale'              THEN 4
        WHEN 'cash_movement'     THEN 5
        WHEN 'void_request'      THEN 6
        WHEN 'finance_entry'     THEN 7
        WHEN 'picklist'          THEN 8
        WHEN 'picklist_item'     THEN 9
        ELSE 10
      END, received_at, entity_id
    LIMIT COALESCE(NULLIF(p_limit, 0), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      v_defer_reason := NULL;
      v_actor_id := NULL;
      v_actor_role := NULL;
      v_actor_perms := '[]'::jsonb;

      -- ---------------------------------------------------------------
      -- Resolve the human actor. A licence authenticates the DEVICE, not a
      -- person; only a server-issued grant names the user. The grant must
      -- belong to this tenant, this device, and be live.
      -- ---------------------------------------------------------------
      IF p_device_fingerprint IS NULL
         OR btrim(p_device_fingerprint) = ''
         OR rec.device_id IS DISTINCT FROM p_device_fingerprint THEN
        v_defer_reason :=
          'ACTOR_AUTH_REQUIRED: device identity is not the licensed device.';
      ELSIF rec.actor_grant_hash IS NULL
            OR btrim(rec.actor_grant_hash) = '' THEN
        v_defer_reason :=
          'ACTOR_AUTH_REQUIRED: no actor grant was presented for this entry.';
      ELSE
        SELECT g.user_id, g.role, g.permissions
          INTO v_actor_id, v_actor_role, v_actor_perms
        FROM public.pos_resolve_actor_grant(
          p_customer, rec.actor_grant_hash, p_device_fingerprint) g;
        IF v_actor_id IS NULL THEN
          v_defer_reason :=
            'ACTOR_AUTH_REQUIRED: actor grant is expired, revoked, or invalid.';
        END IF;
      END IF;

      IF v_defer_reason IS NOT NULL THEN
        -- Leave the row PENDING so the client keeps its outbox entry and can
        -- retry after acquiring a grant. Moving received_at to now() keeps a
        -- large deferred backlog from starving later rows.
        UPDATE public.sync_mirror
        SET apply_error = v_defer_reason,
            applied_at = NULL,
            received_at = now()
        WHERE customer_id = p_customer
          AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
        deferred := deferred + 1;
        CONTINUE;
      END IF;

      -- A device may only delete master data it owns the lifecycle of. Ledger
      -- rows are immutable money and are refused below as they always were.
      IF upper(rec.operation) = 'DELETE'
         AND rec.entity_type <> 'finance_category' THEN
        RAISE EXCEPTION 'A device cannot delete a cloud record.';
      END IF;

      -- A training account's money stays on the till that rang it up. The
      -- actor is now the resolved grant user, never a payload claim.
      IF rec.entity_type IN (
           'sale', 'shift', 'cash_movement', 'void_request', 'finance_entry') THEN
        IF public.pos_is_demo(p_customer, v_actor_id) THEN
          skipped := skipped + 1;
          UPDATE public.sync_mirror
          SET apply_status = 'APPLIED', applied_at = now(),
              apply_error = 'Training-account data stays on the till that made it.'
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          CONTINUE;
        END IF;
      END IF;

      IF rec.entity_type = 'sale' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'pos');
        s := rec.payload->'sale';
        items := rec.payload->'items';
        IF s IS NULL OR jsonb_typeof(s) <> 'object' THEN
          RAISE EXCEPTION 'Sale payload is missing its header.';
        END IF;
        IF items IS NULL OR jsonb_typeof(items) <> 'array'
           OR jsonb_array_length(items) = 0 THEN
          RAISE EXCEPTION 'Sale payload has no line items.';
        END IF;
        device  := COALESCE(NULLIF(s->>'device_id', ''),
                            NULLIF(rec.device_id, ''), 'sync');
        -- The till owns the drawer: land the device's sale on the tenant's
        -- current open shift. pos_create_sale recomputes every figure.
        shift_id := public.pos_ensure_shift(p_customer, v_actor_id, NULL);
        PERFORM public.pos_create_sale(
          p_customer,
          v_actor_id,
          device,
          shift_id,
          s->>'receipt_number',
          items,
          upper(COALESCE(s->>'payment_method', 'CASH')),
          COALESCE((s->>'discount_minor_units')::bigint, 0),
          COALESCE((s->>'amount_paid_minor_units')::bigint, 0),
          NULLIF(s->>'customer_name', ''),
          rec.entity_id);

      ELSIF rec.entity_type = 'cash_movement' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'register');
        mv := rec.payload->'cash_movement';
        IF mv IS NULL OR jsonb_typeof(mv) <> 'object' THEN
          RAISE EXCEPTION 'Cash movement payload is missing.';
        END IF;
        shift_id := public.pos_ensure_shift(
          p_customer, v_actor_id, NULL);
        PERFORM public.pos_add_cash_movement(
          p_customer,
          v_actor_id,
          shift_id,
          upper(COALESCE(mv->>'type', '')),
          abs(COALESCE((mv->>'amount_minor_units')::bigint, 0)),
          mv->>'reason',
          NULLIF(mv->>'photo', ''),
          rec.entity_id,
          NULLIF(mv->>'source_finance_entry_id', ''));

      ELSIF rec.entity_type = 'void_request' THEN
        PERFORM public.pos_require_any_feature(
          p_customer, v_actor_id,
          ARRAY['pos', 'history', 'register_history']);
        vr := rec.payload->'void_request';
        IF vr IS NULL OR jsonb_typeof(vr) <> 'object' THEN
          RAISE EXCEPTION 'Void request payload is missing.';
        END IF;
        SELECT id, status INTO sale_row FROM public.sales
        WHERE customer_id = p_customer AND id = vr->>'sale_id';
        IF NOT FOUND THEN
          RAISE EXCEPTION 'The sale this void request names is not in the cloud.';
        END IF;
        IF sale_row.status <> 'COMPLETED' THEN
          RAISE EXCEPTION 'Sale % is not voidable.', sale_row.id;
        END IF;
        INSERT INTO public.void_requests (id, customer_id, sale_id, requested_by,
          reason, status, created_at, received_at)
        VALUES (rec.entity_id, p_customer, sale_row.id, v_actor_id,
          COALESCE(vr->>'reason', ''), 'PENDING',
          COALESCE((vr->>'created_at')::timestamptz, now()), now())
        ON CONFLICT (customer_id, id) DO NOTHING;

      ELSIF rec.entity_type = 'shift' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'register');
        us := rec.payload->'shift';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'Shift payload is missing.';
        END IF;
        IF upper(COALESCE(us->>'status', 'OPEN')) = 'OPEN' THEN
          PERFORM public.pos_ensure_shift(
            p_customer, v_actor_id,
            COALESCE(NULLIF(us->>'device_id', ''),
                     NULLIF(rec.device_id, ''), 'sync'));
        END IF;

      -- =====================================================================
      -- Master data
      -- =====================================================================

      ELSIF rec.entity_type = 'user' THEN
        -- Account provisioning is an OWNER action. A device may create a
        -- CASHIER (offline provisioning) and edit non-credential fields of an
        -- existing CASHIER, but it may never create/promote an OWNER, touch an
        -- OWNER row, change the demo account, or replace an existing
        -- credential. Credential changes go through live pos-api only.
        IF v_actor_role IS DISTINCT FROM 'OWNER' THEN
          RAISE EXCEPTION 'Only an owner can provision or change accounts.';
        END IF;
        us := rec.payload->'user';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'User payload is missing.';
        END IF;
        IF NULLIF(us->>'username', '') IS NULL THEN
          RAISE EXCEPTION 'Account payload has no login name.';
        END IF;
        IF upper(COALESCE(us->>'role', 'CASHIER')) = 'OWNER' THEN
          RAISE EXCEPTION 'A device cannot create or promote an owner account.';
        END IF;
        SELECT role INTO v_existing_role FROM public.pos_users
        WHERE customer_id = p_customer AND id = rec.entity_id;
        IF FOUND AND v_existing_role = 'OWNER' THEN
          RAISE EXCEPTION 'Owner accounts cannot be changed by a device.';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.pos_users
          WHERE customer_id = p_customer AND id = rec.entity_id AND is_demo
        ) THEN
          RAISE EXCEPTION 'The demo account is managed by the server.';
        END IF;
        SELECT id INTO user_row FROM public.pos_users
        WHERE customer_id = p_customer
          AND lower(username) = lower(us->>'username')
          AND id <> rec.entity_id
        LIMIT 1;
        IF FOUND THEN
          RAISE EXCEPTION 'That login is already in use by another account.';
        END IF;
        perms := CASE
          WHEN btrim(COALESCE(us->>'permissions', '')) = '' THEN '[]'::jsonb
          WHEN left(btrim(us->>'permissions'), 1) IN ('[', '{')
            THEN btrim(us->>'permissions')::jsonb
          ELSE '[]'::jsonb
        END;
        v_new_active := COALESCE((us->>'is_active')::int, 1) = 1;
        v_new_deleted := NULLIF(us->>'deleted_at', '')::timestamptz;

        IF v_existing_role IS NOT NULL THEN
          -- Existing CASHIER: apply owner-editable state, never role,
          -- credentials, or is_demo.
          UPDATE public.pos_users
          SET username    = us->>'username',
              permissions = perms,
              active      = v_new_active,
              deleted_at  = v_new_deleted,
              updated_at  = COALESCE((us->>'updated_at')::timestamptz, now())
          WHERE customer_id = p_customer AND id = rec.entity_id
            AND role <> 'OWNER'
            AND (updated_at IS NULL
                 OR updated_at < COALESCE((us->>'updated_at')::timestamptz,
                                          updated_at + interval '1 second'));
        ELSE
          -- New CASHIER only. Credentials are provisioning material and are
          -- accepted here; the role is forced, never taken from the device.
          INSERT INTO public.pos_users (
            id, customer_id, username, role, pw_salt, pw_hash, active,
            permissions, is_demo, deleted_at, created_at, updated_at)
          VALUES (
            rec.entity_id, p_customer, us->>'username', 'CASHIER',
            COALESCE(NULLIF(us->>'pw_salt', ''), gen_random_uuid()::text),
            COALESCE(NULLIF(us->>'pw_hash', ''),
                     md5(random()::text || clock_timestamp()::text)),
            v_new_active,
            perms,
            false,
            NULL,
            COALESCE((us->>'created_at')::timestamptz, now()),
            COALESCE((us->>'updated_at')::timestamptz, now()));
        END IF;

      ELSIF rec.entity_type = 'product' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'pos');
        pr := rec.payload->'product';
        IF pr IS NULL OR jsonb_typeof(pr) <> 'object' THEN
          RAISE EXCEPTION 'Product payload is missing.';
        END IF;
        IF NULLIF(pr->>'name', '') IS NULL THEN
          RAISE EXCEPTION 'A saved name needs a name.';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.pos_products
          WHERE customer_id = p_customer AND is_active = 1
            AND lower(name) = lower(pr->>'name') AND id <> rec.entity_id) THEN
          RAISE EXCEPTION 'A saved name "%" already exists.', pr->>'name';
        END IF;
        INSERT INTO public.pos_products (
          id, customer_id, name, code, category, unit,
          selling_price_minor_units, is_active, created_at, updated_at)
        VALUES (
          rec.entity_id, p_customer, pr->>'name', pr->>'code', pr->>'category',
          pr->>'unit', COALESCE((pr->>'selling_price_minor_units')::bigint, 0),
          COALESCE((pr->>'is_active')::int, 1),
          COALESCE((pr->>'created_at')::timestamptz, now()),
          COALESCE((pr->>'updated_at')::timestamptz, now()))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          name                     = EXCLUDED.name,
          code                     = EXCLUDED.code,
          category                 = EXCLUDED.category,
          unit                     = EXCLUDED.unit,
          selling_price_minor_units = EXCLUDED.selling_price_minor_units,
          is_active                = EXCLUDED.is_active,
          updated_at               = EXCLUDED.updated_at
        WHERE public.pos_products.updated_at IS NULL
           OR public.pos_products.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'finance_category' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'finance');
        IF upper(rec.operation) = 'DELETE' THEN
          IF NOT EXISTS (SELECT 1 FROM public.pos_finance_categories
                         WHERE customer_id = p_customer AND id = rec.entity_id) THEN
            NULL;
          ELSE
            UPDATE public.pos_finance_categories
            SET deleted_at = COALESCE(deleted_at, now())
            WHERE customer_id = p_customer AND id = rec.entity_id;
            PERFORM public.pos_delete_finance_category(
              p_customer, rec.entity_id, v_actor_id);
          END IF;
        ELSE
          fc := rec.payload->'finance_category';
          IF fc IS NULL OR jsonb_typeof(fc) <> 'object' THEN
            RAISE EXCEPTION 'Finance category payload is missing.';
          END IF;
          IF NULLIF(fc->>'name', '') IS NULL THEN
            RAISE EXCEPTION 'A person needs a name.';
          END IF;
          INSERT INTO public.pos_finance_categories (
            id, customer_id, name, created_at, updated_at, deleted_at)
          VALUES (
            rec.entity_id, p_customer, fc->>'name',
            COALESCE((fc->>'created_at')::timestamptz, now()),
            COALESCE((fc->>'updated_at')::timestamptz, now()),
            (fc->>'deleted_at')::timestamptz)
          ON CONFLICT (customer_id, id) DO UPDATE SET
            name       = EXCLUDED.name,
            deleted_at = EXCLUDED.deleted_at,
            updated_at = EXCLUDED.updated_at
          WHERE public.pos_finance_categories.updated_at IS NULL
             OR public.pos_finance_categories.updated_at < EXCLUDED.updated_at;
        END IF;

      ELSIF rec.entity_type = 'finance_entry' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'finance');
        fe := rec.payload->'finance_entry';
        IF fe IS NULL OR jsonb_typeof(fe) <> 'object' THEN
          RAISE EXCEPTION 'Finance entry payload is missing.';
        END IF;
        SELECT id, deleted_at INTO cat_row FROM public.pos_finance_categories
        WHERE customer_id = p_customer AND id = COALESCE(fe->>'category_id', '');
        IF NOT FOUND THEN
          -- The person has not landed yet: leave it PENDING for the next pass.
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: finance category has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        IF cat_row.deleted_at IS NOT NULL THEN
          RAISE EXCEPTION 'The person this collection belongs to is in the recycle bin.';
        END IF;
        -- Client-supplied status/completed_at/completed_by are ignored. A new
        -- row is PENDING and created_by is the resolved actor.
        INSERT INTO public.pos_finance_entries (
          id, customer_id, category_id, source, amount_minor_units, description,
          status, entry_date, created_at, created_by, completed_at, completed_by,
          updated_at, payment_method)
        VALUES (
          rec.entity_id, p_customer, cat_row.id,
          COALESCE(fe->>'source', ''),
          COALESCE((fe->>'amount_minor_units')::bigint, 0),
          fe->>'description',
          'PENDING',
          COALESCE((fe->>'entry_date')::timestamptz, now()),
          COALESCE((fe->>'created_at')::timestamptz, now()),
          v_actor_id,
          NULL,
          NULL,
          COALESCE((fe->>'updated_at')::timestamptz, now()),
          NULLIF(fe->>'payment_method', ''))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          source             = EXCLUDED.source,
          amount_minor_units = EXCLUDED.amount_minor_units,
          description        = EXCLUDED.description,
          entry_date         = EXCLUDED.entry_date,
          payment_method     = EXCLUDED.payment_method,
          updated_at         = EXCLUDED.updated_at
        WHERE public.pos_finance_entries.status = 'PENDING'
          AND (public.pos_finance_entries.updated_at IS NULL
               OR public.pos_finance_entries.updated_at < EXCLUDED.updated_at);

        SELECT status INTO v_entry_status FROM public.pos_finance_entries
        WHERE customer_id = p_customer AND id = rec.entity_id;

        -- A client may REQUEST a transition, never author it. Both calls use
        -- the resolved actor and their own row locks.
        IF upper(COALESCE(fe->>'status', '')) = 'COMPLETED'
           AND v_entry_status = 'PENDING' THEN
          PERFORM public.pos_complete_finance(
            p_customer, v_actor_id, rec.entity_id);
        ELSIF upper(COALESCE(fe->>'status', '')) = 'DELETED'
              AND v_entry_status <> 'DELETED' THEN
          PERFORM public.pos_delete_finance_entry(
            p_customer, v_actor_id, rec.entity_id);
        END IF;

      -- =====================================================================
      -- Warehouse picklists
      -- =====================================================================

      ELSIF rec.entity_type = 'picklist' THEN
        PERFORM public.pos_require_any_feature(
          p_customer, v_actor_id, ARRAY['warehouse', 'warehouse_fill']);
        pk := rec.payload->'picklist';
        IF pk IS NULL OR jsonb_typeof(pk) <> 'object' THEN
          RAISE EXCEPTION 'Picklist payload is missing.';
        END IF;
        IF NULLIF(pk->>'customer_name', '') IS NULL THEN
          RAISE EXCEPTION 'A picklist needs a customer name.';
        END IF;
        INSERT INTO public.picklists (
          id, customer_id, customer_name, status, created_by,
          created_at, updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, pk->>'customer_name',
          upper(COALESCE(NULLIF(pk->>'status', ''), 'PENDING')),
          v_actor_id,
          COALESCE((pk->>'created_at')::timestamptz, now()),
          COALESCE((pk->>'updated_at')::timestamptz, now()),
          NULLIF(pk->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, id) DO UPDATE SET
          customer_name = EXCLUDED.customer_name,
          status        = EXCLUDED.status,
          updated_at    = EXCLUDED.updated_at,
          deleted_at    = COALESCE(EXCLUDED.deleted_at, public.picklists.deleted_at)
        WHERE public.picklists.updated_at IS NULL
           OR public.picklists.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'picklist_item' THEN
        PERFORM public.pos_require_any_feature(
          p_customer, v_actor_id, ARRAY['warehouse', 'warehouse_fill']);
        pi := rec.payload->'picklist_item';
        IF pi IS NULL OR jsonb_typeof(pi) <> 'object' THEN
          RAISE EXCEPTION 'Picklist item payload is missing.';
        END IF;
        SELECT id INTO pl_row FROM public.picklists
        WHERE customer_id = p_customer AND id = COALESCE(pi->>'picklist_id', '');
        IF pl_row IS NULL THEN
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: picklist header has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        INSERT INTO public.picklist_items (
          id, customer_id, picklist_id, product_name, requested_qty,
          taken_qty, unit, unit_price_minor_units, line_total_minor_units,
          updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, pl_row,
          COALESCE(pi->>'product_name', ''),
          COALESCE((pi->>'requested_qty')::int, 0),
          COALESCE((pi->>'taken_qty')::int, 0),
          COALESCE(pi->>'unit', ''),
          COALESCE((pi->>'unit_price_minor_units')::int, 0),
          COALESCE((pi->>'line_total_minor_units')::int, 0),
          COALESCE((pi->>'updated_at')::timestamptz, now()),
          NULLIF(pi->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, id) DO UPDATE SET
          product_name  = EXCLUDED.product_name,
          requested_qty = EXCLUDED.requested_qty,
          taken_qty     = EXCLUDED.taken_qty,
          unit = EXCLUDED.unit,
          unit_price_minor_units = EXCLUDED.unit_price_minor_units,
          line_total_minor_units = EXCLUDED.line_total_minor_units,
          updated_at    = EXCLUDED.updated_at,
          deleted_at    = COALESCE(EXCLUDED.deleted_at, public.picklist_items.deleted_at)
        WHERE public.picklist_items.updated_at IS NULL
           OR public.picklist_items.updated_at < EXCLUDED.updated_at;

      ELSE
        RAISE EXCEPTION 'Unknown entity type: %', rec.entity_type;
      END IF;

      UPDATE public.sync_mirror
      SET apply_status = 'APPLIED', applied_at = now(), apply_error = NULL
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      applied := applied + 1;

    EXCEPTION WHEN OTHERS THEN
      UPDATE public.sync_mirror
      SET apply_status = 'REJECTED', applied_at = now(), apply_error = SQLERRM
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      rejected := rejected + 1;
    END;
  END LOOP;

  SELECT count(*) INTO left_over FROM public.sync_mirror
  WHERE customer_id = p_customer AND apply_status = 'PENDING';

  RETURN jsonb_build_object(
    'applied', applied, 'rejected', rejected, 'pending', left_over,
    'deferred', deferred);
END;
$function$;

-- Compatibility wrapper for callers that have not been updated yet. With no
-- device fingerprint every row is deferred: it is never correct to apply
-- device-staged data without resolving an actor.
CREATE OR REPLACE FUNCTION public.pos_sync_apply (
  p_customer uuid,
  p_limit    integer DEFAULT 200
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  RETURN public.pos_sync_apply(p_customer, p_limit, NULL);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_sync_apply(uuid, integer, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_sync_apply(uuid, integer, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer, text)
  TO "postgres";

GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_sync_apply(uuid, integer)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_sync_apply(uuid, integer)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer)
  TO "postgres";

-- ===========================================================================
-- 5. Remove the historical public EXECUTE on finance-entry deletion
-- ===========================================================================

REVOKE ALL ON FUNCTION public.pos_delete_finance_entry(uuid, text, text)
  FROM "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry_unchecked(uuid, text, text)
  FROM "anon", "authenticated";

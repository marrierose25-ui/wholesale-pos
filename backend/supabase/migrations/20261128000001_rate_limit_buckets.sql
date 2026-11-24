-- Request 2 / licensing hardening: durable, atomic rate limiting for the
-- public security-sensitive endpoints (device activation, owner login,
-- owner bootstrap, activation-code probing).
--
-- The previous limiter was an in-memory JavaScript Map inside the Edge
-- Functions: it reset on every cold start and was not shared between
-- function instances, so a distributed or restarted attacker faced no
-- limit at all. This table + RPC pair moves the counter into Postgres,
-- where a single upsert serializes concurrent hits.
--
-- Design notes:
--   * bucket_key is an HMAC-SHA256 digest computed by the caller — raw
--     activation codes, usernames, and IPs are NEVER stored here.
--   * Fixed-window counter: window_started_at + hit_count. When the window
--     has elapsed the next hit resets both atomically in the same upsert.
--   * p_charge=false performs a read-only check (used for pre-flight 429s);
--     p_charge=true records the attempt (used for failures / every call on
--     the unauthenticated probes).
--   * rate_limit_reset clears a bucket after a successful login so a
--     legitimate user is not punished for earlier typos forever.
--   * Old buckets are deleted opportunistically inside rate_limit_hit
--     (~2% of calls) so the table cannot grow without bound; anything older
--     than a day is already outside every configured window.
--   * EXECUTE is granted to service_role only; the table itself is
--     RLS-enabled with no policies and no anon/authenticated grants, so
--     only service-role server code can reach it.

CREATE TABLE public.rate_limit_buckets (
  bucket_key        text                     NOT NULL,
  window_started_at timestamp with time zone NOT NULL,
  hit_count         integer                  NOT NULL DEFAULT 0,
  updated_at        timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "rate_limit_buckets_pkey" PRIMARY KEY (bucket_key),
  CONSTRAINT "rate_limit_buckets_hit_count_check" CHECK ((hit_count >= 0))
);

ALTER TABLE "public"."rate_limit_buckets"
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "public"."rate_limit_buckets" FROM "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."rate_limit_buckets" TO "service_role";

CREATE OR REPLACE FUNCTION public.rate_limit_hit (
  p_key             text,
  p_limit           integer,
  p_window_seconds  integer,
  p_charge          boolean DEFAULT true
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_window_start timestamptz;
  v_count        integer;
  v_allowed      boolean;
  v_retry        integer;
begin
  -- Opportunistic cleanup: ~2% of calls sweep buckets whose window ended
  -- more than a day ago. Keeps the table bounded without a scheduler.
  if random() < 0.02 then
    delete from public.rate_limit_buckets
      where window_started_at < now() - interval '1 day';
  end if;

  -- One atomic upsert decides AND records the hit. Two concurrent callers
  -- cannot both observe count <= limit: the row lock inside ON CONFLICT
  -- serializes them, and the second sees the first's committed hit_count.
  insert into public.rate_limit_buckets as b
    (bucket_key, window_started_at, hit_count, updated_at)
  values (p_key, now(), case when p_charge then 1 else 0 end, now())
  on conflict (bucket_key) do update set
    window_started_at = case
      when b.window_started_at + make_interval(secs => p_window_seconds) <= now()
      then now() else b.window_started_at end,
    hit_count = case
      when b.window_started_at + make_interval(secs => p_window_seconds) <= now()
      then case when p_charge then 1 else 0 end
      else b.hit_count + case when p_charge then 1 else 0 end end,
    updated_at = now()
  returning window_started_at, hit_count into v_window_start, v_count;

  v_allowed := v_count <= p_limit;
  v_retry := greatest(0, ceil(extract(epoch from
    (v_window_start + make_interval(secs => p_window_seconds) - now()))))::integer;
  return jsonb_build_object(
    'allowed', v_allowed,
    'count', v_count,
    'retry_after_seconds', v_retry);
end;
$function$;

CREATE OR REPLACE FUNCTION public.rate_limit_reset (
  p_key text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
begin
  delete from public.rate_limit_buckets where bucket_key = p_key;
end;
$function$;

REVOKE ALL ON FUNCTION "public"."rate_limit_hit"(text, integer, integer, boolean) FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "public"."rate_limit_hit"(text, integer, integer, boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."rate_limit_hit"(text, integer, integer, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."rate_limit_hit"(text, integer, integer, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "public"."rate_limit_reset"(text) FROM PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "public"."rate_limit_reset"(text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."rate_limit_reset"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."rate_limit_reset"(text) TO "postgres";

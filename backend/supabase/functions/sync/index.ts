// Wholesale POS — Sync Gateway Edge Function (Phase 18)
//
// The multi-tenant replacement for shipping a Supabase secret key inside a
// build. Clients present their SIGNED LICENSE (issued by the licensing
// function, Ed25519-verified here); the gateway checks it, then reads/writes
// the analytics mirror tables with the service role, stamping every row with
// the customer_id carved into the license. The client NEVER holds a key that
// can touch these tables directly (RLS + REVOKE lock them to service_role).
//
// Deployment (same pattern as the licensing function):
//   supabase functions deploy sync --no-verify-jwt
//   supabase secrets set SYNC_LICENSE_PUBLIC_KEY=<64-hex-char-public-key>
//
// Security model:
//   * Ed25519 signature over the canonical license payload — forged or
//     tampered licenses fail cryptographically. No shared secret to leak.
//   * expires_at must be in the future (license has a 1-year rolling life;
//     devices re-activate periodically, so an old license stops working).
//   * The license's (activation_code, device_fingerprint) pair must match an
//     ACTIVE seat registration — deactivating a device cuts its sync too.
//   * customer_id is taken ONLY from the verified license payload; a client
//     cannot write rows into another shop's partition, ever.
//   * A revocation check on the license row itself kills stolen licenses on
//     the next request, even before their embedded expiry.
//   * BEARER SEMANTICS: the license is a signed document, not a
//     hardware-bound credential — there is no device-held key or
//     challenge-response, so a copied license_code authenticates as its
//     embedded (activation_code, device_fingerprint) regardless of which
//     hardware presents it. Tenant isolation still holds because
//     customer_id comes from the verified payload.
//   * DEVICE != USER. The license authenticates the device; it never proves
//     which human is operating the till. Every staged entry therefore carries
//     an opaque, server-issued ACTOR GRANT (minted by pos-api only after the
//     user's password was verified for this device). The gateway hashes that
//     token with SHA-256 before staging it in `sync_mirror.actor_grant_hash`;
//     `pos_sync_apply` resolves the hash to a live user and uses THAT user for
//     every actor column. Actor ids in the payload are ignored.
//   * A missing/expired/revoked grant leaves the mirror row PENDING with an
//     `ACTOR_AUTH_REQUIRED...` error. The entry is reported as `deferred`, not
//     `applied`, so the client keeps it in its outbox and retries after the
//     user signs in again. Nothing is silently discarded or marked synced.
//   * ABUSE LIMITS: bounded request bodies (8 MB), per-entry payloads (6 MB),
//     and durable per-device/per-tenant/sharded-global rate limits keyed by a
//     SHA-256 digest of the VERIFIED license identity — never an unverified
//     X-Forwarded-For header.
//
// Actions (POST /functions/v1/sync):
//   { action: 'push', license: '<licenseCode>', entries: [outbox entries] }
//     -> { ok, stored: n, deferred: n,
//          results: [{entryId, entityId, status, error?}] }
//        status: applied | rejected | stored | deferred | failed
//   { action: 'pull', license: '<licenseCode>', since: '<iso>',
//     tables: ['<one table>'], cursor?: {received_at, id}, limit?: n }
//     -> { ok, changes: { <table>: [...] }, server_time, next_cursor,
//          has_more }
//     Exactly ONE table per request: a keyset cursor is ordered within one
//     table only, so paging several tables together would silently skip rows.
//   { action: 'ping', license: '<licenseCode>' }
//     -> { ok, customer_id, seats_active }  (cheap connectivity/auth probe)
//
// Staging, not writing (audit 2 #2): a push never writes an operational table.
//   * A LEDGER entry only APPENDS to `sync_mirror`, and pos_sync_apply promotes
//     it through the same RPCs the tills use (`pos_create_sale`,
//     `pos_add_cash_movement`), so a device can neither publish totals it chose
//     nor delete a cloud row.
//   * MASTER data (accounts, saved names, the money tracker) is mutable, so a
//     newer version of the same row re-stages over the stale one and pos_sync_apply
//     resolves the race on `updated_at` — see docs/supabase_sync_mirror.sql and
//     docs/supabase_sync_master_data.sql.

import { ed25519 } from "https://esm.sh/@noble/curves@1.4.0/ed25519";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// A missing secret used to surface as a key of "undefined": a license signed
// over a known string would then verify. Fail at start-up instead of quietly
// serving an insecure function.
function requireEnv(name: string, minLength = 16): string {
  const v = Deno.env.get(name);
  if (!v || v.length < minLength) {
    throw new Error(`Env var ${name} missing or too short (min ${minLength}).`);
  }
  return v;
}

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SERVICE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
// Hex, exactly as tools/print_public_key.dart prints it and as the Dart app
// bakes into WHOLESALE_POS_LICENSE_PUBLIC_KEY.
const PUBLIC_KEY_HEX = requireEnv("SYNC_LICENSE_PUBLIC_KEY", 64);

// Operational tables a pull may read, keyed by the name the client uses. A
// push cannot touch them: it only appends to `sync_mirror` and lets
// pos_sync_apply decide.
//
// `users` is `pos_users` behind an EXPLICIT column list. Sign-in is verified
// offline against the local PBKDF2 hash, so the salt/hash have to travel or a
// till that never created the account can never sign it in. The row is only
// released to a device holding a valid signed license for the same tenant —
// the same trust boundary the till's own SQLite file already sits behind — and
// `token_version` (nor any column added later) does not leak with it.
const PULL_TABLES: Record<string, { from: string; select: string }> = {
  users: {
    from: "pos_users",
    select:
      "id, username, role, active, pw_salt, pw_hash, permissions, is_demo, deleted_at, created_at, updated_at, received_at",
  },
  // Saved names are read off the till's own screen, so the browser's edits have
  // to reach it. `updated_at` is what the device compares to decide which of
  // its copy and the cloud's is stale.
  products: {
    from: "pos_products",
    select:
      "id, name, code, category, unit, selling_price_minor_units, is_active, created_at, updated_at, received_at",
  },
  shifts: { from: "shifts", select: "*" },
  sales: { from: "sales", select: "*" },
  sale_items: { from: "sale_items", select: "*" },
  cash_movements: { from: "cash_movements", select: "*" },
  void_requests: { from: "void_requests", select: "*" },
      'id, name, code, category, unit, selling_price_minor_units, bought_price_minor_units, is_active, created_at, updated_at, received_at',
  },
  // Inventory foundation: stores and per-store stock. Both are mutable
  // master data, read straight through like the picklist tables.
  stores: { from: 'stores', select: '*' },
  store_inventory: { from: 'store_inventory', select: '*' },
  shifts: { from: 'shifts', select: '*' },
  sales: { from: 'sales', select: '*' },
  sale_items: { from: 'sale_items', select: '*' },
  cash_movements: { from: 'cash_movements', select: '*' },
  void_requests: { from: 'void_requests', select: '*' },
  finance_categories: {
    from: "pos_finance_categories",
    select: "id, name, created_at, updated_at, deleted_at, received_at",
  },
  finance_entries: {
    from: "pos_finance_entries",
    select:
      "id, category_id, source, amount_minor_units, description, status, entry_date, " +
      "created_at, created_by, completed_at, completed_by, updated_at, payment_method, received_at",
  },
  // Warehouse Picklists (Digital Fulfillment): independent of the ledger, so
  // their own mirror tables read straight through with no column masking.
  picklists: { from: "picklists", select: "*" },
  picklist_items: { from: "picklist_items", select: "*" },
};
const TABLES = Object.keys(PULL_TABLES);

// Entity vocabulary the staging table accepts. Both the client's own names
// ('sale') and the table names older outboxes used ('sales') are folded here;
// anything else is refused per entry rather than stored.
const ENTITY_ALIAS: Record<string, string> = {
  sales: "sale",
  sale_items: "sale",
  shifts: "shift",
  cash_movements: "cash_movement",
  void_requests: "void_request",
  sale: "sale",
  shift: "shift",
  cash_movement: "cash_movement",
  void_request: "void_request",
  users: "user",
  user: "user",
  products: "product",
  product: "product",
  finance_categories: "finance_category",
  finance_category: "finance_category",
  finance_entries: "finance_entry",
  finance_entry: "finance_entry",
  picklists: "picklist",
  picklist: "picklist",
  picklist_items: "picklist_item",
  picklist_item: "picklist_item",
  sales: 'sale',
  sale_items: 'sale',
  shifts: 'shift',
  cash_movements: 'cash_movement',
  void_requests: 'void_request',
  sale: 'sale',
  shift: 'shift',
  cash_movement: 'cash_movement',
  void_request: 'void_request',
  users: 'user',
  user: 'user',
  products: 'product',
  product: 'product',
  finance_categories: 'finance_category',
  finance_category: 'finance_category',
  finance_entries: 'finance_entry',
  finance_entry: 'finance_entry',
  picklists: 'picklist',
  picklist: 'picklist',
  picklist_items: 'picklist_item',
  picklist_item: 'picklist_item',
  stores: 'store',
  store: 'store',
  store_inventory: 'store_inventory',
  storeInventory: 'store_inventory',
};

// Master data, i.e. everything a shop EDITS after creating. A ledger row is
// staged once and never restated (`ignoreDuplicates: true` keeps that true even
// if a device re-pushes a sale with a modified payload). A mutable row is the
// opposite: the second edit must REPLACE the first copy in the mirror and re-enter
// the apply pass, or the device's outbox would be acked while the cloud kept the
// older version forever. Two surfaces editing one account/saved name resolve in
// `pos_sync_apply` on `updated_at`, not on who staged last.
const MUTABLE_ENTITIES = new Set([
  "user",
  "product",
  "finance_category",
  "finance_entry",
  // A picklist's status and its items' taken quantities change as workers tick
  // stock, so a later edit must replace the earlier mirror copy, not freeze.
  "picklist",
  "picklist_item",
  'picklist',
  'picklist_item',
  // Stores and per-store stock are edited after creation, so a later change
  // must replace the earlier mirror copy rather than freeze at first push.
  'store',
  'store_inventory',
]);

// Max outbox entries accepted in one push batch (abuse guard).
const MAX_BATCH = 500;

// --- Abuse bounds -----------------------------------------------------------
// Bodies are read incrementally and refused once they cross the ceiling, so a
// huge Content-Length cannot make the function buffer an arbitrary amount.
const MAX_BODY_BYTES = 8 * 1024 * 1024; // 8 MB
const MAX_ENTRY_PAYLOAD_BYTES = 6 * 1024 * 1024; // 6 MB
const MAX_LICENSE_LENGTH = 4096;
const MAX_GRANT_LENGTH = 512;

// Durable rate limits (see `rate_limit_hit`). Per verified device, per tenant,
// and a sharded global backstop. The shard keeps one row from becoming a
// cross-tenant contention point; an attacker with a valid license can still
// spread load across shards, so the global bucket bounds a single shard, not
// the whole fleet (documented residual risk).
const RATE_WINDOW_SECONDS = 60;
const PUSH_DEVICE_LIMIT = 120;
const PUSH_TENANT_LIMIT = 600;
const PULL_DEVICE_LIMIT = 240;
const PULL_TENANT_LIMIT = 1200;
const GLOBAL_SHARDS = 8;
const PUSH_GLOBAL_LIMIT_PER_SHARD = 2500;
const PULL_GLOBAL_LIMIT_PER_SHARD = 5000;

// ---------------------------------------------------------------------------
// Privileged state transitions are NOT applied here (Stage 4.1 / audit H1).
// ---------------------------------------------------------------------------
// This function previously inspected pushed payloads for `status: 'VOIDED'`
// sales and APPROVED/REJECTED void requests and replayed them through
// `pos_void_sale` / `pos_approve_void` / `pos_reject_void`, passing the
// caller-supplied `voided_by` / `decided_by` as `p_user`. Those RPCs only
// check that `p_user` is an OWNER of the tenant — a string any licensed
// device can invent (owner ids are handed out by `pull`'s `users` table).
// A valid license proves tenant + device identity, never WHICH USER acted,
// so a cashier's till could forge owner-authorized voids at will.
//
// The fix is structural, not a filter: the gateway now stages and applies
// only DATA. `pos_create_sale` hardcodes status 'COMPLETED' and
// `pos_sync_apply` inserts void requests as 'PENDING', so a pushed
// VOIDED/APPROVED payload can never become an authoritative transition —
// it lands (or no-ops idempotently) as ordinary content. The authoritative
// transition must come through `pos-api`'s authenticated actions
// (`void_sale`, `approve_void`, `reject_void`), where `p_user` is carved
// from the verified JWT, never from a request body. Devices that recorded
// such a transition offline keep it locally and reconcile it through that
// authenticated path once they can prove owner credentials.
//

// Exported for tests; the Edge Runtime loads this file as the main module,
// so the server still starts in production (same pattern as pos-api).
export async function handleSyncRequest(
  req: Request,
  dbOverride?: any,
): Promise<Response> {
  if (req.method !== "POST") {
    return json({ ok: false, error: "POST required" }, 405);
  }
  const read = await readJsonBody(req, MAX_BODY_BYTES);
  if (!read.ok) return json({ ok: false, error: read.error }, read.status);
  const body: any = read.body;

  const db = dbOverride ?? createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  // Every action authenticates the same way: a valid signed license.
  const licenseCode = String(body.license ?? "");
  if (licenseCode.length > MAX_LICENSE_LENGTH) {
    return json({ ok: false, error: "License is too long." }, 400);
  }
  let auth:
    | { ok: true; customerId: string; code: string; fingerprint: string }
    | { ok: false; status: number; error: string };
  try {
    auth = await verifyLicense(db, licenseCode);
  } catch (err) {
    console.error("sync auth error:", err);
    auth = { ok: false, status: 500, error: "Internal error." };
  }
  if (!auth.ok) return json({ ok: false, error: auth.error }, auth.status);

  try {
    switch (body.action) {
      case "push":
        return await push(db, auth, body);
      case "pull":
        return await pull(db, auth, body);
      case "recover":
        return await recover(db, auth, body);
      case "ping":
        return await ping(db, auth);
      default:
        return json(
          { ok: false, error: `Unknown action: ${body.action}` },
          400,
        );
    }
  } catch (err) {
    console.error("sync function error:", err);
    return json({ ok: false, error: "Internal error." }, 500);
  }
}

if (import.meta.main) {
  Deno.serve((req) => handleSyncRequest(req));
}

// ---------------------------------------------------------------------------
// License verification — the entire security boundary of this function.
// Bearer semantics: a valid license_code asserts the device identity inside
// its signed payload; it does not prove the physical device holds a key
// (no challenge-response exists). See docs/LICENSING.md "Limitations".
// ---------------------------------------------------------------------------
async function verifyLicense(db: any, licenseCode: string) {
  if (!licenseCode) return fail(401, "Missing license.");
  const dot = licenseCode.indexOf(".");
  if (dot <= 0) return fail(401, "Malformed license.");
  let payload: any;
  try {
    const payloadBytes = base64UrlDecode(licenseCode.slice(0, dot));
    const signature = base64UrlDecode(licenseCode.slice(dot + 1));
    // Cryptographic check first: tampering with any field breaks this.
    if (!ed25519.verify(signature, payloadBytes, hexToBytes(PUBLIC_KEY_HEX))) {
      return fail(401, "License signature invalid.");
    }
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return fail(401, "License could not be parsed.");
  }

  if (payload.format !== "wholesale-pos-license" || payload.version !== 2) {
    return fail(401, "License format not supported by sync.");
  }
  const code = String(payload.activation_code ?? "");
  const fingerprint = String(payload.device_fingerprint ?? "");
  const customerId = String(payload.customer_id ?? "");
  if (!code || !fingerprint || !customerId) {
    return fail(401, "License fields missing.");
  }

  // Rolling expiry: an old, never-refreshed license must stop syncing.
  const expires = Date.parse(String(payload.expires_at ?? ""));
  if (!Number.isFinite(expires) || expires < Date.now()) {
    return fail(403, "License expired. Re-activate the device.");
  }

  // Server-side revocation beats the license's embedded expiry.
  const { data: licRow } = await db
    .from("licenses").select("revoked_at").eq("activation_code", code)
    .maybeSingle();
  if (!licRow) return fail(403, "License not found.");
  if (licRow.revoked_at) return fail(403, "License revoked.");

  // The presenting device must hold an ACTIVE seat — deactivation cuts sync.
  const { data: seat } = await db.from("device_registrations").select("id")
    .eq("activation_code", code).eq("device_fingerprint", fingerprint)
    .is("revoked_at", null).maybeSingle();
  if (!seat) return fail(403, "Device seat not registered (or deactivated).");

  return { ok: true as const, customerId, code, fingerprint };
}

function fail(status: number, error: string) {
  return { ok: false as const, status, error };
}

// ---------------------------------------------------------------------------
// Action: push — stage a client outbox, then let the server apply it.
// ---------------------------------------------------------------------------
// Entry shape (identical to the local SyncOutboxEntry jsonEncode):
//   { entryId, entityType, entityId, operation: 'upsert'|'delete', payload }
// The payload is stored verbatim; nothing from it is trusted until
// pos_sync_apply re-derives the money through the till RPCs.
async function push(
  db: any,
  auth: { customerId: string; fingerprint: string },
  body: any,
): Promise<Response> {
  const entries = Array.isArray(body.entries) ? body.entries : [];
  if (entries.length === 0) {
    return json({ ok: true, stored: 0, deferred: 0, results: [] });
  }
  if (entries.length > MAX_BATCH) {
    return json(
      { ok: false, error: `Batch too large (max ${MAX_BATCH}).` },
      413,
    );
  }

  // Charged once per request against the VERIFIED device identity. A missing
  // license never reaches here; an X-Forwarded-For header is never consulted.
  const limited = await syncRateLimit(
    db,
    "sync:push",
    auth.customerId,
    auth.fingerprint,
    PUSH_DEVICE_LIMIT,
    PUSH_TENANT_LIMIT,
    PUSH_GLOBAL_LIMIT_PER_SHARD,
  );
  if (!limited.allowed) return tooManyRequests(limited.retryAfter);

  let stored = 0;
  let deferred = 0;
  const results: {
    entryId: string;
    entityId: string;
    status: string;
    error?: string;
  }[] = [];
  const staged: { entryId: string; entityId: string; entityType: string }[] =
    [];

  for (const entry of entries) {
    const entryId = String(entry.entryId ?? "");
    const entityId = String(entry.entityId ?? "");
    const rawType = String(entry.entityType ?? "");
    const entityType = ENTITY_ALIAS[rawType] ?? "";
    // A type we do not recognise is a permanent rejection: report it per entry
    // so the client drops it instead of acking unprocessed data or retrying
    // forever (audit #20).
    if (!entityType || !entityId) {
      results.push({
        entryId,
        entityId,
        status: "rejected",
        error: !entityType
          ? `unknown entity type: ${rawType}`
          : "missing entity id",
      });
      continue;
    }

    // Per-entry size ceiling. The whole-body limit already bounds the batch;
    // this stops one oversized payload (a giant base64 photo) from consuming
    // the entire allowance and starving every other queued row.
    const payload = entry.payload ?? {};
    let payloadBytes = 0;
    try {
      payloadBytes =
        new TextEncoder().encode(JSON.stringify(payload)).byteLength;
    } catch {
      results.push({
        entryId,
        entityId,
        status: "rejected",
        error: "payload is not serialisable",
      });
      continue;
    }
    if (payloadBytes > MAX_ENTRY_PAYLOAD_BYTES) {
      results.push({
        entryId,
        entityId,
        status: "rejected",
        error: `payload too large (max ${MAX_ENTRY_PAYLOAD_BYTES} bytes)`,
      });
      continue;
    }

    // The raw grant never reaches Postgres. Only its SHA-256 digest is staged,
    // matching pos_actor_grant_hash() so pos_sync_apply can resolve it.
    const grant = String(entry.actorGrant ?? "").trim();
    if (grant.length > MAX_GRANT_LENGTH) {
      results.push({
        entryId,
        entityId,
        status: "rejected",
        error: "actor grant is malformed",
      });
      continue;
    }
    const actorGrantHash = grant ? await sha256Hex(grant) : null;

    // Per-actor grants (Request 3 acceptance): a finance entry can name a
    // creator AND a completer/deleter who are different people. The client
    // sends `actorGrants` as a map of claimed-actor-id -> raw grant token;
    // only SHA-256 digests are staged, keyed the same way, so
    // pos_sync_apply can resolve each actor independently. The key only
    // selects which digest to resolve — the resolved user id is what lands.
    const actorGrantHashes: Record<string, string> = {};
    const rawGrants = entry.actorGrants;
    if (
      rawGrants && typeof rawGrants === "object" && !Array.isArray(rawGrants)
    ) {
      const keys = Object.keys(rawGrants as Record<string, unknown>);
      if (keys.length > 16) {
        results.push({
          entryId,
          entityId,
          status: "rejected",
          error: "too many actor grants",
        });
        continue;
      }
      for (const k of keys) {
        const v = String((rawGrants as Record<string, unknown>)[k] ?? "")
          .trim();
        if (!v || v.length > MAX_GRANT_LENGTH) continue;
        actorGrantHashes[k.slice(0, 128)] = await sha256Hex(v);
      }
    }

    // Append-only for the ledger. An entity that is already staged (pending or
    // already applied) is left untouched, so a replay cannot overwrite an applied
    // row with a different payload.
    //
    // Mutable master data is the reverse: the new version replaces the old copy
    // and is pushed back through the apply pass (`apply_status = 'PENDING'`),
    // otherwise the device would be told 'stored' for a row the cloud had already
    // applied and its edit would be silently dropped.
    const mutable = MUTABLE_ENTITIES.has(entityType);
    const now = new Date().toISOString();
    const staging: Record<string, unknown> = {
      customer_id: auth.customerId,
      entity_type: entityType,
      entity_id: entityId,
      operation: String(entry.operation ?? "UPSERT").toUpperCase(),
      device_id: auth.fingerprint,
      payload,
      actor_grant_hash: actorGrantHash,
      actor_grant_hashes: Object.keys(actorGrantHashes).length > 0
        ? actorGrantHashes
        : null,
    };
    if (mutable) {
      staging.received_at = now;
      staging.apply_status = "PENDING";
      staging.apply_error = null;
      staging.applied_at = null;
    }
    const ins = await db.from("sync_mirror").upsert(staging, {
      onConflict: "customer_id,entity_type,entity_id",
      ignoreDuplicates: !mutable,
    });
    if (ins.error) {
      results.push({
        entryId,
        entityId,
        status: "failed",
        error: ins.error.message,
      });
      continue;
    }
    if (!mutable) {
      // A ledger row staged earlier may still be PENDING because its grant was
      // missing/expired. Refresh the grant and arrival stamp so a re-push after
      // re-login can resolve the actor. Applied rows are never touched.
      const up = await db.from("sync_mirror").update({
        actor_grant_hash: actorGrantHash,
        actor_grant_hashes: Object.keys(actorGrantHashes).length > 0
          ? actorGrantHashes
          : null,
        received_at: now,
      })
        .eq("customer_id", auth.customerId)
        .eq("entity_type", entityType)
        .eq("entity_id", entityId)
        .eq("apply_status", "PENDING");
      if (up.error) {
        results.push({
          entryId,
          entityId,
          status: "failed",
          error: up.error.message,
        });
        continue;
      }
    }
    stored++;
    staged.push({ entryId, entityId, entityType });
  }

  // Applying is server-owned and idempotent: every staged entry is replayed
  // through pos_create_sale / pos_add_cash_movement, which recompute the money
  // and enforce the shift and receipt invariants. The third argument is the
  // VERIFIED device fingerprint; pos_sync_apply refuses to resolve an actor
  // for any row whose staged device does not match it.
  if (staged.length > 0) {
    const { data, error } = await db.rpc("pos_sync_apply", {
      p_customer: auth.customerId,
      p_limit: Math.max(staged.length, 200),
      p_device_fingerprint: auth.fingerprint,
    });
    if (error) {
      // The entries are safely stored; report them retryable so the client
      // keeps its outbox until the apply path works again.
      for (const s of staged) {
        results.push({
          entryId: s.entryId,
          entityId: s.entityId,
          status: "failed",
          error: error.message,
        });
      }
    } else {
      // Read back the verdict per staged entity: APPLIED, REJECTED (permanent,
      // with the server's reason), DEFERRED (waiting for a valid actor grant —
      // the client MUST keep the outbox row) or still PENDING (stored, will be
      // applied on the next push).
      const { data: rows, error: readErr } = await db.from("sync_mirror")
        .select("entity_type, entity_id, apply_status, apply_error")
        .eq("customer_id", auth.customerId)
        .in("entity_id", staged.map((s) => s.entityId));
      if (readErr) throw new Error(readErr.message);
      const byKey: Record<string, any> = {};
      for (const r of rows ?? []) byKey[`${r.entity_type}:${r.entity_id}`] = r;
      for (const s of staged) {
        const r = byKey[`${s.entityType}:${s.entityId}`];
        const state = String(r?.apply_status ?? "PENDING");
        const reason = String(r?.apply_error ?? "");
        let status: string;
        if (state === "APPLIED") status = "applied";
        else if (state === "REJECTED") status = "rejected";
        else if (reason.startsWith("ACTOR_AUTH_REQUIRED")) status = "deferred";
        else if (reason.startsWith("RETRYABLE:")) status = "retryable";
        else if (reason.startsWith("DEFERRED:")) status = "deferred";
        else status = "stored";
        if (status === "deferred") deferred++;
        results.push({
          entryId: s.entryId,
          entityId: s.entityId,
          status,
          error: state === "REJECTED" || status === "deferred"
            ? reason
            : undefined,
        });
      }
      // `data` is unused beyond its error; kept for parity with the RPC call.
      void data;
    }
  }

  // No privileged transitions are applied from pushed payloads (see the
  // comment where terminalState used to live). A pushed VOIDED sale or a
  // decided void request is staged as data only: pos_sync_apply inserts the
  // sale as COMPLETED and the request as PENDING, and the authoritative
  // transition must arrive through pos-api's JWT-authenticated actions.
  const anyFailed = results.some((r) => r.status === "failed");
  return json({
    ok: !anyFailed,
    stored,
    deferred,
    results,
    error: anyFailed ? "Some entries failed to store." : undefined,
  });
}

// ---------------------------------------------------------------------------
// Action: recover — deliberate operator retry of quarantined records.
// ---------------------------------------------------------------------------
// A local outbox row the cloud permanently refused sits in quarantine. Re-
// queueing it locally changes nothing: the staged sync_mirror row is still
// REJECTED and every apply refuses it identically. This action asks
// pos_sync_recover to re-queue ONLY still-REJECTED rows and re-run them through
// pos_sync_apply — the same validation path as a fresh push — so grants,
// permissions and payloads are genuinely re-checked. APPLIED rows are never
// touched, the apply RPCs' idempotency prevents duplicate financial
// transactions, and every recovery is audit-logged server-side.
//
//   { action: 'recover', license: '<licenseCode>',
//     entries: [{ entryId, entityType, entityId }] }
//     -> { ok, results: [{entryId, entityId, status, error?}] }
//        status: applied | rejected | deferred | stored | missing
async function recover(
  db: any,
  auth: { customerId: string; fingerprint: string },
  body: any,
): Promise<Response> {
  const entries = Array.isArray(body.entries) ? body.entries : [];
  if (entries.length === 0) {
    return json({ ok: true, results: [] });
  }
  if (entries.length > 200) {
    return json({ ok: false, error: "Batch too large (max 200)." }, 413);
  }

  const limited = await syncRateLimit(
    db,
    "sync:recover",
    auth.customerId,
    auth.fingerprint,
    PUSH_DEVICE_LIMIT,
    PUSH_TENANT_LIMIT,
    PUSH_GLOBAL_LIMIT_PER_SHARD,
  );
  if (!limited.allowed) return tooManyRequests(limited.retryAfter);

  // Fold the client's local vocabulary onto staging entity names exactly like
  // push does; entries that cannot be named are refused per-entry.
  const requested: {
    entry_id: string;
    entity_type: string;
    entity_id: string;
  }[] = [];
  const results: {
    entryId: string;
    entityId: string;
    status: string;
    error?: string;
  }[] = [];
  for (const entry of entries) {
    const entryId = String(entry.entryId ?? "");
    const entityId = String(entry.entityId ?? "");
    const rawType = String(entry.entityType ?? "");
    const entityType = ENTITY_ALIAS[rawType] ?? "";
    if (!entityType || !entityId) {
      results.push({
        entryId,
        entityId,
        status: "rejected",
        error: !entityType
          ? `unknown entity type: ${rawType}`
          : "missing entity id",
      });
      continue;
    }
    requested.push({
      entry_id: entryId,
      entity_type: entityType,
      entity_id: entityId,
    });
  }

  if (requested.length > 0) {
    const { data, error } = await db.rpc("pos_sync_recover", {
      p_customer: auth.customerId,
      p_device_fingerprint: auth.fingerprint,
      p_entries: requested,
    });
    if (error) throw new Error(error.message);
    const verdicts = (data as Record<string, unknown>)?.results;
    if (Array.isArray(verdicts)) {
      // The RPC echoes entry_id/entity_id back; join on entity identity as a
      // fallback for a verdict that lost its echo.
      const byKey: Record<string, any> = {};
      for (const v of verdicts) {
        if (v && typeof v === "object") {
          byKey[`${v.entity_type}:${v.entity_id}`] = v;
        }
      }
      const wanted = new Map(
        requested.map((r) => [`${r.entity_type}:${r.entity_id}`, r]),
      );
      for (const v of verdicts) {
        if (!v || typeof v !== "object") continue;
        const key = `${v.entity_type}:${v.entity_id}`;
        const req = wanted.get(key);
        results.push({
          entryId: String(v.entry_id ?? req?.entry_id ?? ""),
          entityId: String(v.entity_id ?? req?.entity_id ?? ""),
          status: String(v.status ?? "stored"),
          error: v.error == null ? undefined : String(v.error),
        });
        byKey[key] = undefined as any;
      }
      // A requested entry with no verdict at all stays 'stored' — the client
      // keeps it queued rather than guessing.
      for (const [key, req] of wanted) {
        if (byKey[key] !== undefined) continue;
        results.push({
          entryId: req.entry_id,
          entityId: req.entity_id,
          status: "stored",
        });
      }
    }
  }

  return json({ ok: true, results });
}

// ---------------------------------------------------------------------------
// Action: pull — delta feed so every device of a shop sees the same ledger.
// Clients page ONE table at a time (a keyset cursor is only ordered within a
// single table), so `tables: ['sales']` is the normal call shape.
// ---------------------------------------------------------------------------
async function pull(
  db: any,
  auth: { customerId: string; fingerprint: string },
  body: any,
): Promise<Response> {
  const limited = await syncRateLimit(
    db,
    "sync:pull",
    auth.customerId,
    auth.fingerprint,
    PULL_DEVICE_LIMIT,
    PULL_TENANT_LIMIT,
    PULL_GLOBAL_LIMIT_PER_SHARD,
  );
  if (!limited.allowed) return tooManyRequests(limited.retryAfter);

  // Cursor is either a keyset {received_at, id} (preferred, exact pagination)
  // or a bare `since` ISO timestamp (legacy first page). received_at alone is
  // ambiguous because a push stamps every row it applied with one timestamp, so
  // the id tiebreaker makes the walk strictly ordered and gap-free.
  const cursor = body.cursor && typeof body.cursor === "object"
    ? body.cursor
    : null;
  // The cursor is interpolated into a PostgREST `.or(...)` expression, which
  // parses commas, parentheses and dots. Validate BOTH halves against their
  // real shapes before they touch the query string, so a crafted cursor cannot
  // inject extra filter terms (or escape the tenant filter).
  if (cursor) {
    const cAt = String(cursor.received_at ?? "");
    const cId = String(cursor.id ?? "");
    if (
      !/^[0-9T:.+\-]{10,40}Z?$/.test(cAt) || !/^[A-Za-z0-9_\-]{1,60}$/.test(cId)
    ) {
      return json({ ok: false, error: "Invalid cursor." }, 400);
    }
  }
  // A first sync has no cursor yet. Start from the beginning of the tenant's
  // history instead of rejecting the call — the request is already
  // authenticated by a signed license, and the tenant filter is applied below.
  const since = String(body.since ?? "") || "1970-01-01T00:00:00Z";
  if (!cursor && Number.isNaN(Date.parse(since))) {
    return json({
      ok: false,
      error: "since must be an ISO timestamp, or pass a cursor.",
    }, 400);
  }
  // Exactly ONE table per request. A keyset cursor is ordered within a single
  // table; paging several tables together advances one shared cursor past rows
  // a quieter table has not delivered yet, silently losing them. The client
  // already walks the tables in dependency order, one at a time.
  const requested: string[] = Array.isArray(body.tables)
    ? body.tables.map((t: unknown) => String(t))
    : [];
  if (requested.length !== 1) {
    return json({
      ok: false,
      error: `tables must name exactly one table: ${TABLES.join(", ")}`,
    }, 400);
  }
  const wanted = [requested[0]];
  if (!TABLES.includes(wanted[0])) {
    return json({
      ok: false,
      error: `tables must be one of: ${TABLES.join(", ")}`,
    }, 400);
  }
  // Rows per table per page. Callers loop on has_more/next_cursor so a busy
  // tenant's backlog is delivered in full rather than silently truncated at a
  // hard cap (audit #12: skipped rows / no pagination).
  const pageLimit = Math.min(Math.max(Number(body.limit) || 1000, 1), 1000);

  const changes: Record<string, unknown[]> = {};
  let maxReceived = "";
  let maxId = "";
  let hasMore = false;
  for (const t of wanted) {
    const spec = PULL_TABLES[t];
    let q = db.from(spec.from).select(spec.select).eq(
      "customer_id",
      auth.customerId,
    );
    if (cursor) {
      const cAt = String(cursor.received_at ?? "");
      const cId = String(cursor.id ?? "");
      q = q.or(`received_at.gt.${cAt},and(received_at.eq.${cAt},id.gt.${cId})`);
    } else {
      q = q.gt("received_at", since);
    }
    const { data, error } = await q
      .order("received_at", { ascending: true })
      .order("id", { ascending: true })
      .limit(pageLimit);
    if (error) throw new Error(`pull ${t}: ${error.message}`);
    const rows = data ?? [];
    changes[t] = rows;
    if (rows.length === pageLimit) hasMore = true;
    const last = rows[rows.length - 1];
    if (last && String(last.received_at) >= maxReceived) {
      maxReceived = String(last.received_at);
      maxId = String(last.id);
    }
  }
  const nextCursor = maxReceived
    ? { received_at: maxReceived, id: maxId }
    : null;
  return json({
    ok: true,
    changes,
    server_time: new Date().toISOString(),
    next_cursor: nextCursor,
    has_more: hasMore,
  });
}

// ---------------------------------------------------------------------------
// Action: ping — cheap "is my seat still valid / server reachable" probe.
// ---------------------------------------------------------------------------
async function ping(
  db: any,
  auth: { customerId: string; code: string },
): Promise<Response> {
  const { count } = await db.from("device_registrations")
    .select("*", { count: "exact", head: true })
    .eq("activation_code", auth.code).is("revoked_at", null);
  return json({
    ok: true,
    customer_id: auth.customerId,
    seats_active: count ?? 0,
  });
}

// ---------------------------------------------------------------------------
// Helpers (base64url + hex; verification canonicalization already happened
// inside the signed bytes — we parse the payload as-is, the SIGNATURE is over
// the exact bytes the licensing function canonicalized, so re-encoding is
// never needed here.)
// ---------------------------------------------------------------------------
function base64UrlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}
// ---------------------------------------------------------------------------
// Abuse-control helpers
// ---------------------------------------------------------------------------

/// Read the request body incrementally, refusing anything over [maxBytes].
/// `Content-Length` is checked first as a cheap rejection, but the streaming
/// count is the real bound (a chunked request may omit or lie about it).
async function readJsonBody(
  req: Request,
  maxBytes: number,
): Promise<
  { ok: true; body: any } | { ok: false; status: number; error: string }
> {
  const declared = Number(req.headers.get("content-length") ?? "");
  if (Number.isFinite(declared) && declared > maxBytes) {
    return { ok: false, status: 413, error: "Request body too large." };
  }
  if (!req.body) return { ok: false, status: 400, error: "Invalid JSON" };
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        return { ok: false, status: 413, error: "Request body too large." };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, status: 400, error: "Invalid JSON" };
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { ok: true, body: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, status: 400, error: "Invalid JSON" };
  }
}

/// Lowercase hex SHA-256, matching `pos_actor_grant_hash()` in SQL.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// Durable per-device + per-tenant + sharded-global throttle. Identity is the
/// VERIFIED (customer, device fingerprint) pair from the signed license, never
/// a client header. Each call charges one hit in every bucket; the first
/// refusal wins. A global bucket is sharded so a single row is not a
/// cross-tenant contention point, at the documented cost that a fleet-wide
/// flood is bounded per shard rather than in one counter.
async function syncRateLimit(
  db: any,
  scope: string,
  customerId: string,
  fingerprint: string,
  deviceLimit: number,
  tenantLimit: number,
  globalLimitPerShard: number,
): Promise<{ allowed: boolean; retryAfter: number }> {
  const deviceKey = `sync:${scope}:device:${await sha256Hex(
    `${customerId}|${fingerprint}`,
  )}`;
  const tenantKey = `sync:${scope}:tenant:${await sha256Hex(customerId)}`;
  const shardSeed = await sha256Hex(`${scope}|${customerId}|${fingerprint}`);
  const shard = parseInt(shardSeed.slice(0, 8), 16) % GLOBAL_SHARDS;
  const globalKey = `sync:${scope}:global:${shard}`;
  const buckets: [string, number][] = [
    [deviceKey, deviceLimit],
    [tenantKey, tenantLimit],
    [globalKey, globalLimitPerShard],
  ];
  for (const [key, limit] of buckets) {
    const { data, error } = await db.rpc("rate_limit_hit", {
      p_key: key,
      p_limit: limit,
      p_window_seconds: RATE_WINDOW_SECONDS,
      p_charge: true,
    });
    if (error) throw new Error(error.message);
    const r = (data ?? {}) as Record<string, unknown>;
    if (r.allowed === false) {
      return {
        allowed: false,
        retryAfter: Number(r.retry_after_seconds ?? RATE_WINDOW_SECONDS),
      };
    }
  }
  return { allowed: true, retryAfter: 0 };
}

function tooManyRequests(retryAfter: number): Response {
  return json({
    ok: false,
    error: `Too many sync requests. Retry in ${retryAfter}s.`,
    retry_after_seconds: retryAfter,
  }, 429);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

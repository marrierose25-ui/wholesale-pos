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
//
// Actions (POST /functions/v1/sync):
//   { action: 'push', license: '<licenseCode>', entries: [outbox entries] }
//     -> { ok, stored: n, apply: {applied, rejected, pending},
//          results: [{entryId, entityId, status, error?}] }
//   { action: 'pull', license: '<licenseCode>', since: '<iso>',
//     tables?: [], cursor?: {received_at, id}, limit?: n }
//     -> { ok, changes: { sales: [...], ... }, server_time, next_cursor,
//          has_more }
//   { action: 'ping', license: '<licenseCode>' }
//     -> { ok, customer_id, seats_active }  (cheap connectivity/auth probe)
//
// Staging, not writing (audit 2 #2): a push only ever APPENDS to
// `sync_mirror`. `pos_sync_apply` then promotes pending entries through the
// same RPCs the tills use (`pos_create_sale`, `pos_add_cash_movement`), so a
// device can neither publish totals it chose nor delete a cloud row — a
// DELETE entry is stored and rejected. See docs/supabase_sync_mirror.sql.

import { ed25519 } from 'https://esm.sh/@noble/curves@1.4.0/ed25519';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// Hex, exactly as tools/print_public_key.dart prints it and as the Dart app
// bakes into WHOLESALE_POS_LICENSE_PUBLIC_KEY.
const PUBLIC_KEY_HEX = Deno.env.get('SYNC_LICENSE_PUBLIC_KEY')!;

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
    from: 'pos_users',
    select:
      'id, username, role, active, pw_salt, pw_hash, permissions, is_demo, deleted_at, created_at, received_at',
  },
  shifts: { from: 'shifts', select: '*' },
  sales: { from: 'sales', select: '*' },
  sale_items: { from: 'sale_items', select: '*' },
  cash_movements: { from: 'cash_movements', select: '*' },
  void_requests: { from: 'void_requests', select: '*' },
};
const TABLES = Object.keys(PULL_TABLES);

// Entity vocabulary the staging table accepts. Both the client's own names
// ('sale') and the table names older outboxes used ('sales') are folded here;
// anything else is refused per entry rather than stored.
const ENTITY_ALIAS: Record<string, string> = {
  sales: 'sale',
  sale_items: 'sale',
  shifts: 'shift',
  cash_movements: 'cash_movement',
  void_requests: 'void_request',
  sale: 'sale',
  shift: 'shift',
  cash_movement: 'cash_movement',
  void_request: 'void_request',
};

// Max outbox entries accepted in one push batch (abuse guard).
const MAX_BATCH = 500;

// ---------------------------------------------------------------------------
// terminalState: the part of a payload that is a STATE TRANSITION, not content.
// ---------------------------------------------------------------------------
// A device resends an entity's whole current row, so "I voided this sale" is the
// same entity pushed again with status VOIDED, and "the owner approved this
// request" is the request pushed again as APPROVED. `sync_mirror` is keyed per
// entity and deliberately keeps the first payload (an applied entry is never
// overwritten), and `pos_sync_apply` can only INSERT the sale or the request —
// it can never transition one. So the transition is applied here, through the
// same RPCs the PWA calls, which is the only place allowed to make it.
//
// Returns null when the payload is plain content (create, cash movement, …).
function terminalState(
  entityType: string,
  entityId: string,
  payload: any,
  customerId: string,
): { rpc: string; args: Record<string, unknown>; benign: string[] } | null {
  const p = payload && typeof payload === 'object' ? payload : {};

  if (entityType === 'sale') {
    const sale = p.sale;
    if (!sale || String(sale.status ?? '').toUpperCase() !== 'VOIDED') return null;
    const reason = String(sale.void_reason ?? '').trim();
    return {
      rpc: 'pos_void_sale',
      args: {
        p_customer: customerId,
        p_user: String(sale.voided_by ?? '') || String(sale.cashier_id ?? '') || 'sync',
        p_sale_id: entityId,
        p_reason: reason || 'Voided on a register',
      },
      benign: ['already voided'],
    };
  }

  if (entityType === 'void_request') {
    const request = p.void_request;
    const status = String(request?.status ?? '').toUpperCase();
    if (status !== 'APPROVED' && status !== 'REJECTED') return null;
    return {
      rpc: status === 'APPROVED' ? 'pos_approve_void' : 'pos_reject_void',
      args: {
        p_customer: customerId,
        p_user: String(request?.decided_by ?? '') || 'sync',
        p_request_id: entityId,
      },
      benign: ['was decided', 'already decided', 'voidable', 'already voided'],
    };
  }

  return null;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST required' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid JSON' }, 400); }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  // Every action authenticates the same way: a valid signed license.
  let auth: { ok: true; customerId: string; code: string; fingerprint: string }
         | { ok: false; status: number; error: string };
  try {
    auth = await verifyLicense(db, String(body.license ?? ''));
  } catch (err) {
    console.error('sync auth error:', err);
    auth = { ok: false, status: 500, error: 'Internal error.' };
  }
  if (!auth.ok) return json({ ok: false, error: auth.error }, auth.status);

  try {
    switch (body.action) {
      case 'push': return await push(db, auth, body);
      case 'pull': return await pull(db, auth, body);
      case 'ping': return await ping(db, auth);
      default: return json({ ok: false, error: `Unknown action: ${body.action}` }, 400);
    }
  } catch (err) {
    console.error('sync function error:', err);
    return json({ ok: false, error: 'Internal error.' }, 500);
  }
});

// ---------------------------------------------------------------------------
// License verification — the entire security boundary of this function.
// ---------------------------------------------------------------------------
async function verifyLicense(db: any, licenseCode: string) {
  if (!licenseCode) return fail(401, 'Missing license.');
  const dot = licenseCode.indexOf('.');
  if (dot <= 0) return fail(401, 'Malformed license.');
  let payload: any;
  try {
    const payloadBytes = base64UrlDecode(licenseCode.slice(0, dot));
    const signature = base64UrlDecode(licenseCode.slice(dot + 1));
    // Cryptographic check first: tampering with any field breaks this.
    if (!ed25519.verify(signature, payloadBytes, hexToBytes(PUBLIC_KEY_HEX))) {
      return fail(401, 'License signature invalid.');
    }
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return fail(401, 'License could not be parsed.');
  }

  if (payload.format !== 'wholesale-pos-license' || payload.version !== 2) {
    return fail(401, 'License format not supported by sync.');
  }
  const code = String(payload.activation_code ?? '');
  const fingerprint = String(payload.device_fingerprint ?? '');
  const customerId = String(payload.customer_id ?? '');
  if (!code || !fingerprint || !customerId) return fail(401, 'License fields missing.');

  // Rolling expiry: an old, never-refreshed license must stop syncing.
  const expires = Date.parse(String(payload.expires_at ?? ''));
  if (!Number.isFinite(expires) || expires < Date.now()) {
    return fail(403, 'License expired. Re-activate the device.');
  }

  // Server-side revocation beats the license's embedded expiry.
  const { data: licRow } = await db
    .from('licenses').select('revoked_at').eq('activation_code', code).maybeSingle();
  if (!licRow) return fail(403, 'License not found.');
  if (licRow.revoked_at) return fail(403, 'License revoked.');

  // The presenting device must hold an ACTIVE seat — deactivation cuts sync.
  const { data: seat } = await db.from('device_registrations').select('id')
    .eq('activation_code', code).eq('device_fingerprint', fingerprint)
    .is('revoked_at', null).maybeSingle();
  if (!seat) return fail(403, 'Device seat not registered (or deactivated).');

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
async function push(db: any, auth: { customerId: string; fingerprint: string }, body: any): Promise<Response> {
  const entries = Array.isArray(body.entries) ? body.entries : [];
  if (entries.length === 0) return json({ ok: true, stored: 0, results: [] });
  if (entries.length > MAX_BATCH) {
    return json({ ok: false, error: `Batch too large (max ${MAX_BATCH}).` }, 413);
  }

  let stored = 0;
  const results: { entryId: string; entityId: string; status: string; error?: string }[] = [];
  const staged: { entryId: string; entityId: string; entityType: string }[] = [];
  // Entities that already exist in the cloud change STATE rather than content:
  // a voided sale, a decided void request. `pos_sync_apply` replays the sale
  // through `pos_create_sale`, which is idempotent by sale id — for an existing
  // sale that is a no-op, so the void never landed and every other device kept
  // counting the money. These are applied afterwards through the same RPCs the
  // PWA uses, which is where the state transition can actually happen.
  const stateChanges: {
    entryId: string;
    entityId: string;
    rpc: string;
    args: Record<string, unknown>;
    benign: string[];
  }[] = [];

  for (const entry of entries) {
    const entryId = String(entry.entryId ?? '');
    const entityId = String(entry.entityId ?? '');
    const rawType = String(entry.entityType ?? '');
    const entityType = ENTITY_ALIAS[rawType] ?? '';
    // A type we do not recognise is a permanent rejection: report it per entry
    // so the client drops it instead of acking unprocessed data or retrying
    // forever (audit #20).
    if (!entityType || !entityId) {
      results.push({
        entryId, entityId, status: 'rejected',
        error: !entityType ? `unknown entity type: ${rawType}` : 'missing entity id',
      });
      continue;
    }

    // Append-only. An entity that is already staged (pending or already
    // applied) is left untouched, so a replay cannot overwrite an applied row
    // with a different payload.
    const ins = await db.from('sync_mirror').upsert({
      customer_id: auth.customerId,
      entity_type: entityType,
      entity_id: entityId,
      operation: String(entry.operation ?? 'UPSERT').toUpperCase(),
      device_id: auth.fingerprint,
      payload: entry.payload ?? {},
    }, { onConflict: 'customer_id,entity_type,entity_id', ignoreDuplicates: true });
    if (ins.error) {
      results.push({ entryId, entityId, status: 'failed', error: ins.error.message });
      continue;
    }
    stored++;
    staged.push({ entryId, entityId, entityType });

    const change = terminalState(entityType, entityId, entry.payload, auth.customerId);
    if (change) stateChanges.push({ entryId, entityId, ...change });
  }

  // Applying is server-owned and idempotent: every staged entry is replayed
  // through pos_create_sale / pos_add_cash_movement, which recompute the money
  // and enforce the shift and receipt invariants.
  if (staged.length > 0) {
    const { data, error } = await db.rpc('pos_sync_apply', {
      p_customer: auth.customerId, p_limit: Math.max(staged.length, 200),
    });
    if (error) {
      // The entries are safely stored; report them retryable so the client
      // keeps its outbox until the apply path works again.
      for (const s of staged) {
        results.push({ entryId: s.entryId, entityId: s.entityId, status: 'failed', error: error.message });
      }
    } else {
      // Read back the verdict per staged entity: APPLIED, REJECTED (permanent,
      // with the server's reason) or still PENDING (stored, will be applied on
      // the next push).
      const { data: rows, error: readErr } = await db.from('sync_mirror')
        .select('entity_type, entity_id, apply_status, apply_error')
        .eq('customer_id', auth.customerId)
        .in('entity_id', staged.map((s) => s.entityId));
      if (readErr) throw new Error(readErr.message);
      const byKey: Record<string, any> = {};
      for (const r of rows ?? []) byKey[`${r.entity_type}:${r.entity_id}`] = r;
      for (const s of staged) {
        const r = byKey[`${s.entityType}:${s.entityId}`];
        const state = String(r?.apply_status ?? 'PENDING');
        results.push({
          entryId: s.entryId, entityId: s.entityId,
          status: state === 'APPLIED' ? 'applied' : state === 'REJECTED' ? 'rejected' : 'stored',
          error: state === 'REJECTED' ? String(r?.apply_error ?? '') : undefined,
        });
      }
    }
  }

  // State changes go last, in order: the sale has to exist before it can be
  // voided. Both RPCs refuse a repeat, and a repeat is exactly what a retried
  // entry looks like — that refusal is a success, not a failure.
  for (const change of stateChanges) {
    const result = results.find((r) => r.entryId === change.entryId);
    // The row the transition targets has to have landed first. 'stored' means
    // it is still queued behind a backlog — the void is early, not refused, so
    // leave it unacked and let the next push carry the same payload again.
    // 'rejected' means there is nothing to void at all, and re-pushing the
    // whole batch for an entry the cloud will never accept only wedges the
    // queue (ack'd entries are pruned; a stuck 'failed' one is not).
    if (result && result.status === 'stored') {
      result.status = 'failed';
      result.error = 'Waiting for the entity to be applied first.';
      continue;
    }
    if (result && result.status === 'rejected') continue;

    const { error } = await db.rpc(change.rpc, change.args);
    if (!error) {
      if (result) result.status = 'applied';
      continue;
    }
    const message = String(error.message ?? '');
    const replay = change.benign.some((s) => message.includes(s));
    if (result) {
      result.status = replay ? 'applied' : 'rejected';
      if (!replay) result.error = message;
    }
  }

  const anyFailed = results.some((r) => r.status === 'failed');
  return json({
    ok: !anyFailed,
    stored,
    results,
    error: anyFailed ? 'Some entries failed to store.' : undefined,
  });
}

// ---------------------------------------------------------------------------
// Action: pull — delta feed so every device of a shop sees the same ledger.
// Clients page ONE table at a time (a keyset cursor is only ordered within a
// single table), so `tables: ['sales']` is the normal call shape.
// ---------------------------------------------------------------------------
async function pull(db: any, auth: { customerId: string }, body: any): Promise<Response> {
  // Cursor is either a keyset {received_at, id} (preferred, exact pagination)
  // or a bare `since` ISO timestamp (legacy first page). received_at alone is
  // ambiguous because a push stamps every row it applied with one timestamp, so
  // the id tiebreaker makes the walk strictly ordered and gap-free.
  const cursor = body.cursor && typeof body.cursor === 'object' ? body.cursor : null;
  // A first sync has no cursor yet. Start from the beginning of the tenant's
  // history instead of rejecting the call — the request is already
  // authenticated by a signed license, and the tenant filter is applied below.
  const since = String(body.since ?? '') || '1970-01-01T00:00:00Z';
  if (!cursor && Number.isNaN(Date.parse(since))) {
    return json({ ok: false, error: 'since must be an ISO timestamp, or pass a cursor.' }, 400);
  }
  const requested: string[] = Array.isArray(body.tables) && body.tables.length > 0
    ? body.tables.map((t: unknown) => String(t))
    : TABLES;
  const wanted = requested.filter((t) => TABLES.includes(t));
  if (wanted.length === 0) {
    return json({ ok: false, error: `tables must be a subset of: ${TABLES.join(', ')}` }, 400);
  }
  // Rows per table per page. Callers loop on has_more/next_cursor so a busy
  // tenant's backlog is delivered in full rather than silently truncated at a
  // hard cap (audit #12: skipped rows / no pagination).
  const pageLimit = Math.min(Math.max(Number(body.limit) || 1000, 1), 1000);

  const changes: Record<string, unknown[]> = {};
  let maxReceived = '';
  let maxId = '';
  let hasMore = false;
  for (const t of wanted) {
    const spec = PULL_TABLES[t];
    let q = db.from(spec.from).select(spec.select).eq('customer_id', auth.customerId);
    if (cursor) {
      const cAt = String(cursor.received_at ?? '');
      const cId = String(cursor.id ?? '');
      q = q.or(`received_at.gt.${cAt},and(received_at.eq.${cAt},id.gt.${cId})`);
    } else {
      q = q.gt('received_at', since);
    }
    const { data, error } = await q
      .order('received_at', { ascending: true })
      .order('id', { ascending: true })
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
    ok: true, changes, server_time: new Date().toISOString(),
    next_cursor: nextCursor, has_more: hasMore,
  });
}

// ---------------------------------------------------------------------------
// Action: ping — cheap "is my seat still valid / server reachable" probe.
// ---------------------------------------------------------------------------
async function ping(db: any, auth: { customerId: string; code: string }): Promise<Response> {
  const { count } = await db.from('device_registrations')
    .select('*', { count: 'exact', head: true })
    .eq('activation_code', auth.code).is('revoked_at', null);
  return json({ ok: true, customer_id: auth.customerId, seats_active: count ?? 0 });
}

// ---------------------------------------------------------------------------
// Helpers (base64url + hex; verification canonicalization already happened
// inside the signed bytes — we parse the payload as-is, the SIGNATURE is over
// the exact bytes the licensing function canonicalized, so re-encoding is
// never needed here.)
// ---------------------------------------------------------------------------
function base64UrlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
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
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}

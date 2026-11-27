// Stage 4.1 / audit H1 regression tests for the sync gateway.
//
// Proves that a valid licensed device can NO LONGER turn a pushed payload
// into an owner-authorized transition: pos_void_sale / pos_approve_void /
// pos_reject_void must never be reachable from `push`, no matter what
// `voided_by` / `decided_by` the payload claims.

// Env before module import (requireEnv runs at load time).
const { ed25519 } = await import(
  "https://esm.sh/@noble/curves@1.4.0/ed25519"
);
const secretKey = ed25519.utils.randomPrivateKey();
const pubHex = Array.from(ed25519.getPublicKey(secretKey))
  .map((b) => b.toString(16).padStart(2, "0")).join("");
Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");
Deno.env.set(
  "SUPABASE_SERVICE_ROLE_KEY",
  "test-service-role-key-0123456789abcdef",
);
Deno.env.set("SYNC_LICENSE_PUBLIC_KEY", pubHex);

const { handleSyncRequest } = await import("../index.ts");

// --- Minimal PostgREST-style mock -----------------------------------------
type Row = Record<string, unknown>;
class MockDb {
  rpcCalls: { fn: string; params: Record<string, unknown> }[] = [];
  upserts: Row[] = [];
  mirrorRows: Row[] = [];
  licenses: Row[] = [];
  seats: Row[] = [];
  applyResult: unknown = { applied: 1, rejected: 0, pending: 0 };
  applyError: string | null = null;

  rpc(fn: string, params: Record<string, unknown>) {
    this.rpcCalls.push({ fn, params });
    if (fn === "pos_sync_apply") {
      if (this.applyError) {
        return Promise.resolve({
          data: null,
          error: { message: this.applyError },
        });
      }
      // Mark staged rows APPLIED so results read back 'applied'.
      for (const r of this.mirrorRows) {
        r.apply_status = "APPLIED";
        r.apply_error = null;
      }
      return Promise.resolve({ data: this.applyResult, error: null });
    }
    if (fn === "rate_limit_hit") {
      // The durable limiter is covered by its own suite; here it must simply
      // allow so the push path under test is reached.
      return Promise.resolve({
        data: { allowed: true, retry_after_seconds: 0 },
        error: null,
      });
    }
    return Promise.resolve({
      data: null,
      error: { message: `unexpected rpc ${fn}` },
    });
  }

  from(table: string) {
    const self = this;
    const filters: ((r: Row) => boolean)[] = [];
    let op: "select" | "upsert" | "update" | "insert" | null = null;
    let payload: Row | Row[] | null = null;
    let head = false;
    const api: any = {
      select(_cols?: string, opts?: { count?: string; head?: boolean }) {
        op = "select";
        head = opts?.head === true;
        return api;
      },
      update(row: Row) {
        op = "update";
        payload = row;
        return api;
      },
      upsert(row: Row, _opts?: unknown) {
        op = "upsert";
        payload = row;
        // Mirror upsert semantics: insert or merge on (customer_id,entity_type,entity_id).
        const existing = self.mirrorRows.find((r) =>
          r.customer_id === row.customer_id &&
          r.entity_type === row.entity_type &&
          r.entity_id === row.entity_id
        );
        if (existing && row.apply_status === undefined) {
          // ignoreDuplicates for ledger entities: keep first payload.
        } else if (existing) {
          Object.assign(existing, row);
        } else {
          const stored = {
            ...row,
            apply_status: row.apply_status ?? "PENDING",
            apply_error: null,
          };
          self.mirrorRows.push(stored);
        }
        return Promise.resolve({ data: null, error: null });
      },
      eq(col: string, val: unknown) {
        filters.push((r) => r[col] === val);
        return api;
      },
      is(col: string, val: unknown) {
        filters.push((r) => (val === null ? r[col] == null : r[col] === val));
        return api;
      },
      in(col: string, vals: unknown[]) {
        filters.push((r) => vals.includes(r[col]));
        return api;
      },
      maybeSingle() {
        return api._exec(true);
      },
      single() {
        return api._exec(true);
      },
      then(resolve: any, reject?: any) {
        return api._exec(false).then(resolve, reject);
      },
      _exec(single: boolean) {
        if (op === "upsert" || op === "update") {
          if (op === "update" && payload && !Array.isArray(payload)) {
            const matched = self.mirrorRows.filter((r) =>
              filters.every((f) => f(r))
            );
            for (const r of matched) Object.assign(r, payload);
          }
          return Promise.resolve({ data: null, error: null });
        }
        let rows: Row[] = [];
        if (table === "licenses") rows = self.licenses;
        else if (table === "device_registrations") rows = self.seats;
        else if (table === "sync_mirror") rows = self.mirrorRows;
        const matched = rows.filter((r) => filters.every((f) => f(r)));
        if (head) {
          return Promise.resolve({
            data: null,
            error: null,
            count: matched.length,
          });
        }
        const data = single ? (matched[0] ?? null) : matched;
        return Promise.resolve({ data, error: null });
      },
    };
    return api;
  }
}

function b64u(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function canonicalJson(v: any): string {
  if (Array.isArray(v)) return "[" + v.map(canonicalJson).join(",") + "]";
  if (v && typeof v === "object") {
    return "{" + Object.keys(v).sort()
      .map((k) => JSON.stringify(k) + ":" + canonicalJson(v[k])).join(",") +
      "}";
  }
  return JSON.stringify(v);
}

async function makeLicense(overrides: Record<string, unknown> = {}) {
  const payload = {
    format: "wholesale-pos-license",
    version: 2,
    product: "wholesale_pos",
    entitlements: ["pos"],
    activation_code: "ACT-1234",
    customer_id: "cust-1",
    device_fingerprint: "fp-1",
    issued_at: new Date(Date.now() - 86400000).toISOString().replace(
      /\.\d{3}Z$/,
      "Z",
    ),
    expires_at: new Date(Date.now() + 86400000 * 300).toISOString().replace(
      /\.\d{3}Z$/,
      "Z",
    ),
    ...overrides,
  };
  const bytes = new TextEncoder().encode(canonicalJson(payload));
  const sig = ed25519.sign(bytes, secretKey);
  return `${b64u(bytes)}.${b64u(sig)}`;
}

function post(body: unknown) {
  return new Request("http://localhost/sync", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function seededDb() {
  const db = new MockDb();
  db.licenses = [{
    customer_id: "cust-1",
    activation_code: "ACT-1234",
    revoked_at: null,
    expires_at: null,
  }];
  db.seats = [{
    id: "seat-1",
    activation_code: "ACT-1234",
    device_fingerprint: "fp-1",
    revoked_at: null,
  }];
  return db;
}

Deno.test("push: forged VOIDED sale never reaches pos_void_sale", async () => {
  const db = seededDb();
  const license = await makeLicense();
  const res = await handleSyncRequest(
    post({
      action: "push",
      license,
      entries: [{
        entryId: "e1",
        entityType: "sale",
        entityId: "sale-1",
        operation: "upsert",
        payload: {
          sale: {
            id: "sale-1",
            status: "VOIDED",
            voided_by: "owner-user-id",
            cashier_id: "cashier-1",
            receipt_number: "REC-1",
            payment_method: "CASH",
            device_id: "dev-1",
            shift_id: "sh-1",
            subtotal_minor_units: 1000,
            discount_minor_units: 0,
            total_minor_units: 1000,
            amount_paid_minor_units: 1000,
            change_minor_units: 0,
            created_at: "2026-01-01T00:00:00Z",
          },
          items: [{ id: "i1", line_total_minor_units: 1000 }],
        },
      }],
    }),
    db,
  );
  const body = await res.json();
  if (!body.ok) throw new Error(`push failed: ${JSON.stringify(body)}`);
  const privileged = db.rpcCalls.filter((c) =>
    ["pos_void_sale", "pos_approve_void", "pos_reject_void"].includes(c.fn)
  );
  if (privileged.length !== 0) {
    throw new Error(`privileged RPC called: ${JSON.stringify(privileged)}`);
  }
  // The entry is still staged/applied as DATA — nothing is silently lost.
  if (db.mirrorRows.length !== 1) {
    throw new Error("sale was not staged");
  }
});

Deno.test("push: forged APPROVED/REJECTED void_request never reaches decide RPCs", async () => {
  const db = seededDb();
  const license = await makeLicense();
  for (const [i, status] of ["APPROVED", "REJECTED"].entries()) {
    const res = await handleSyncRequest(
      post({
        action: "push",
        license,
        entries: [{
          entryId: `e${i}`,
          entityType: "void_request",
          entityId: `vr-${i}`,
          operation: "upsert",
          payload: {
            void_request: {
              id: `vr-${i}`,
              sale_id: "sale-1",
              status,
              decided_by: "owner-user-id",
              requested_by: "cashier-1",
              reason: "forged",
              created_at: "2026-01-01T00:00:00Z",
            },
          },
        }],
      }),
      db,
    );
    const body = await res.json();
    if (!body.ok) throw new Error(`push failed: ${JSON.stringify(body)}`);
  }
  const privileged = db.rpcCalls.filter((c) =>
    ["pos_void_sale", "pos_approve_void", "pos_reject_void"].includes(c.fn)
  );
  if (privileged.length !== 0) {
    throw new Error(`privileged RPC called: ${JSON.stringify(privileged)}`);
  }
  // Only pos_sync_apply may write — the data path. rate_limit_hit is the
  // abuse bound that guards every push and is expected to run first.
  const other = db.rpcCalls.filter((c) =>
    c.fn !== "pos_sync_apply" && c.fn !== "rate_limit_hit"
  );
  if (other.length !== 0) {
    throw new Error(`unexpected rpc: ${JSON.stringify(other)}`);
  }
});

Deno.test("push: ordinary sale creation still flows through pos_sync_apply", async () => {
  const db = seededDb();
  const license = await makeLicense();
  const res = await handleSyncRequest(
    post({
      action: "push",
      license,
      entries: [{
        entryId: "e1",
        entityType: "sale",
        entityId: "sale-9",
        operation: "upsert",
        payload: {
          sale: {
            id: "sale-9",
            status: "COMPLETED",
            cashier_id: "cashier-1",
            receipt_number: "REC-9",
            payment_method: "CASH",
            device_id: "dev-1",
            shift_id: "sh-1",
            subtotal_minor_units: 500,
            discount_minor_units: 0,
            total_minor_units: 500,
            amount_paid_minor_units: 500,
            change_minor_units: 0,
            created_at: "2026-01-01T00:00:00Z",
          },
          items: [{ id: "i1", line_total_minor_units: 500 }],
        },
      }],
    }),
    db,
  );
  const body = await res.json();
  if (!body.ok) throw new Error(`push failed: ${JSON.stringify(body)}`);
  if (!db.rpcCalls.some((c) => c.fn === "pos_sync_apply")) {
    throw new Error("pos_sync_apply was not invoked");
  }
});

Deno.test("push: invalid license is rejected before any staging", async () => {
  const db = seededDb();
  const res = await handleSyncRequest(
    post({
      action: "push",
      license: "forged.license",
      entries: [{
        entryId: "e",
        entityType: "sale",
        entityId: "s",
        operation: "upsert",
        payload: {},
      }],
    }),
    db,
  );
  if (res.status !== 401) throw new Error(`expected 401, got ${res.status}`);
  if (db.mirrorRows.length !== 0) throw new Error("rows staged without auth");
});

// Router-level regression tests for the modular pos-api entry point.
// Exercises the real handleRequest() path: CORS/JSON guards, JWT verification,
// actor load + token_version revocation, OWNER_ONLY and feature gates, tenant
// scoping, dispatch, response shapes, pagination, and audit writes — all
// against the in-memory MockDb (no network, no production credentials).

import "./test_env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  createMockDb,
  type MockDb,
  resetMockRateLimits,
  type Row,
} from "./mock_db.ts";
import { signJwt } from "../shared/auth.ts";
import { ACTION_FEATURES, OWNER_ONLY } from "../shared/authorization.ts";

const { handleRequest, ACTIONS } = await import("../index.ts");

const CID = "cust-1";
const OTHER = "cust-2";
const OWNER_ID = "user-owner-1";
const CASHIER_ID = "user-cashier-1";

function userRow(over: Row = {}): Row {
  return {
    id: OWNER_ID,
    customer_id: CID,
    username: "0911111111",
    role: "OWNER",
    active: true,
    permissions: [],
    token_version: 0,
    pw_salt: "",
    pw_hash: "",
    is_demo: false,
    deleted_at: null,
    created_at: "2026-01-01T00:00:00Z",
    ...over,
  };
}

function baseSeed(): Record<string, Row[]> {
  return {
    pos_users: [userRow()],
    licenses: [{
      activation_code: "ACT-CODE",
      customer_id: CID,
      revoked_at: null,
      expires_at: null,
    }],
  };
}

async function tokenFor(
  sub: string,
  cid: string,
  role: string,
  tv = 0,
): Promise<string> {
  return await signJwt({ sub, cid, role, tv });
}

async function call(
  db: MockDb,
  action: string,
  body: Record<string, unknown> = {},
  opts: {
    token?: string | null;
    raw?: string;
    headers?: Record<string, string>;
  } = {},
): Promise<
  { status: number; json: Record<string, unknown>; headers: Headers }
> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    ...opts.headers,
  };
  if (opts.token) headers["authorization"] = `Bearer ${opts.token}`;
  const payload = opts.raw ?? JSON.stringify({ action, ...body });
  const req = new Request("http://localhost/pos-api", {
    method: "POST",
    headers,
    body: payload,
  });
  const res = await handleRequest(req, db);
  let json: Record<string, unknown> = {};
  try {
    json = await res.json();
  } catch { /* empty body */ }
  return { status: res.status, json, headers: res.headers };
}

async function ownerCall(
  db: MockDb,
  action: string,
  body: Record<string, unknown> = {},
): Promise<{ status: number; json: Record<string, unknown> }> {
  const token = await tokenFor(OWNER_ID, CID, "OWNER", 0);
  const r = await call(db, action, body, { token });
  return { status: r.status, json: r.json };
}

// ---------------------------------------------------------------------------
// Transport guards
// ---------------------------------------------------------------------------

Deno.test("OPTIONS preflight returns 204 with CORS headers", async () => {
  const db = createMockDb();
  const req = new Request("http://localhost/pos-api", { method: "OPTIONS" });
  const res = await handleRequest(req, db);
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("access-control-allow-origin"), "*");
});

Deno.test("non-POST returns 405", async () => {
  const db = createMockDb();
  const req = new Request("http://localhost/pos-api", { method: "GET" });
  const res = await handleRequest(req, db);
  assertEquals(res.status, 405);
  const j = await res.json();
  assertEquals(j, { ok: false, error: "POST required" });
});

Deno.test("invalid JSON returns 400", async () => {
  const db = createMockDb();
  const r = await call(db, "list_products", {}, { raw: "{not json" });
  assertEquals(r.status, 400);
  assertEquals(r.json, { ok: false, error: "Invalid JSON" });
});

// ---------------------------------------------------------------------------
// Unauthenticated actions
// ---------------------------------------------------------------------------

Deno.test("login rejects missing fields", async () => {
  const db = createMockDb(baseSeed());
  const r = await call(db, "login", {});
  assertEquals(r.status, 400);
  assertEquals(r.json.error, "Missing fields");
});

Deno.test("login rejects unknown activation code", async () => {
  const db = createMockDb(baseSeed());
  const r = await call(db, "login", {
    activation_code: "NOPE",
    username: "0911111111",
    password: "whatever-password",
  });
  assertEquals(r.status, 403);
  assertEquals(r.json.error, "Invalid activation code.");
});

Deno.test("has_users reports tenant user presence", async () => {
  const db = createMockDb(baseSeed());
  const r = await call(db, "has_users", { activation_code: "ACT-CODE" });
  assertEquals(r.status, 200);
  assertEquals(r.json, { ok: true, has_users: true });

  const empty = createMockDb({
    licenses: baseSeed().licenses,
    pos_users: [],
  });
  const r2 = await call(empty, "has_users", { activation_code: "ACT-CODE" });
  assertEquals(r2.json.has_users, false);
});

// The public source bucket is keyed on a best-effort XFF hint — the hosted
// ingress contract is unverified, so these tests pin PARSING behaviour and
// the fail-safe fallback, not a trusted client identity. The security
// guarantee is the durable global + per-code limits.
Deno.test("public source hint: rotating rightmost XFF evades the bucket", async () => {
  resetMockRateLimits();
  const db = createMockDb(baseSeed());
  // PUBLIC_SOURCE_LIMIT is 240/min. A client controlling the whole header
  // mints a fresh bucket per request: 245 requests with distinct rightmost
  // entries and distinct codes are ALL served (403 = past the throttles,
  // rejected only by the unknown-code check). If the source bucket were a
  // real boundary this would 429 — it is not, by design.
  for (let i = 0; i < 245; i++) {
    const r = await call(db, "has_users", {
      activation_code: `PROBE-${i}-XXXX-XXXX-XXXX`,
    }, {
      headers: {
        "x-forwarded-for": `198.51.${Math.floor(i / 256)}.${i % 256}`,
      },
    });
    assertEquals(r.status, 403, `request ${i} must pass the throttles`);
  }
});

Deno.test("public source hint: missing XFF shares 'unknown' and is bounded", async () => {
  resetMockRateLimits();
  const db = createMockDb(baseSeed());
  // No header -> every request shares the "unknown" source bucket, still
  // capped at PUBLIC_SOURCE_LIMIT (240). Request 241+ must 429 even though
  // each uses a distinct activation code.
  let saw429 = false;
  for (let i = 0; i < 245 && !saw429; i++) {
    const r = await call(db, "has_users", {
      activation_code: `NOHDR-${i}-XXXX-XXXX-XXXX`,
    });
    if (r.status === 429) saw429 = true;
  }
  assert(saw429, "expected the shared 'unknown' bucket to throttle");
  // Leave no exhausted shared bucket behind for later tests in this process.
  resetMockRateLimits();
});

// ---------------------------------------------------------------------------
// Authentication + session revocation
// ---------------------------------------------------------------------------

Deno.test("authenticated action without token returns 401", async () => {
  const db = createMockDb(baseSeed());
  const r = await call(db, "list_products");
  assertEquals(r.status, 401);
  assertEquals(r.json.error, "Not signed in.");
});

Deno.test("forged/garbage token returns 401", async () => {
  const db = createMockDb(baseSeed());
  const r = await call(db, "list_products", {}, { token: "aaa.bbb.ccc" });
  assertEquals(r.status, 401);
});

Deno.test("valid JWT for deactivated/missing user returns 403", async () => {
  const db = createMockDb(baseSeed()); // no pos_users row for CASHIER_ID
  const token = await tokenFor(CASHIER_ID, CID, "CASHIER", 0);
  const r = await call(db, "list_products", {}, { token });
  assertEquals(r.status, 403);
  assertEquals(r.json.error, "Session no longer valid.");
});

Deno.test("token_version mismatch revokes session", async () => {
  const db = createMockDb(baseSeed()); // owner has token_version 0
  const token = await tokenFor(OWNER_ID, CID, "OWNER", 7);
  const r = await call(db, "list_products", {}, { token });
  assertEquals(r.status, 403);
  assertEquals(r.json.error, "Session no longer valid.");
});

Deno.test("expired JWT returns 401", async () => {
  const db = createMockDb(baseSeed());
  // Hand-craft an expired token signed with the test secret.
  const enc = new TextEncoder();
  const b64u = (s: string) =>
    btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const head = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64u(
    JSON.stringify({
      sub: OWNER_ID,
      cid: CID,
      role: "OWNER",
      tv: 0,
      iat: 1000,
      exp: 1001, // 1970
    }),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode("test-jwt-secret-0123456789abcdef0123"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuf = await crypto.subtle.sign(
    "HMAC",
    key,
    enc.encode(`${head}.${body}`),
  );
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const r = await call(db, "list_products", {}, {
    token: `${head}.${body}.${sig}`,
  });
  assertEquals(r.status, 401);
});

// ---------------------------------------------------------------------------
// Authorization gates
// ---------------------------------------------------------------------------

function cashierDb(perms: string[]): MockDb {
  return createMockDb({
    ...baseSeed(),
    pos_users: [
      userRow(),
      userRow({
        id: CASHIER_ID,
        username: "0922222222",
        role: "CASHIER",
        permissions: perms,
      }),
    ],
  });
}

async function cashierCall(
  db: MockDb,
  action: string,
  body: Record<string, unknown> = {},
) {
  const token = await tokenFor(CASHIER_ID, CID, "CASHIER", 0);
  return await call(db, action, body, { token });
}

Deno.test("OWNER_ONLY action rejects cashier with 403", async () => {
  const db = await cashierDb(["users", "pos", "register", "reports"]);
  const r = await cashierCall(db, "create_user", {
    username: "0933333333",
    role: "CASHIER",
    password: "password123",
  });
  assertEquals(r.status, 403);
  assertEquals(r.json.error, "Owner access required.");
});

Deno.test("feature gate rejects cashier missing the tick", async () => {
  const db = await cashierDb(["pos"]);
  const r = await cashierCall(db, "finance_categories");
  assertEquals(r.status, 403);
  assertEquals(r.json.error, "Not permitted for this account.");
});

Deno.test("feature gate allows cashier holding the tick", async () => {
  const db = await cashierDb(["finance"]);
  const r = await cashierCall(db, "finance_categories");
  assertEquals(r.status, 200);
  assertEquals(r.json.ok, true);
});

Deno.test("OWNER bypasses feature gates", async () => {
  const db = createMockDb(baseSeed());
  const r = await ownerCall(db, "finance_categories");
  assertEquals(r.status, 200);
  assertEquals(r.json.ok, true);
});

// ---------------------------------------------------------------------------
// Tenant isolation + catalog behaviour
// ---------------------------------------------------------------------------

Deno.test("list_products returns only the caller's tenant rows", async () => {
  const db = createMockDb({
    ...baseSeed(),
    pos_products: [
      {
        id: "p1",
        customer_id: CID,
        name: "Own Product",
        is_active: 1,
        selling_price_minor_units: 100,
      },
      {
        id: "p2",
        customer_id: OTHER,
        name: "Other Tenant Product",
        is_active: 1,
        selling_price_minor_units: 200,
      },
    ],
  });
  const r = await ownerCall(db, "list_products");
  assertEquals(r.status, 200);
  assertEquals((r.json.products as unknown[]).length, 1);
  assertEquals(
    (r.json.products as Record<string, unknown>[])[0].name,
    "Own Product",
  );
  // strip() removes customer_id/received_at from the wire shape.
  assertEquals(
    "customer_id" in (r.json.products as Record<string, unknown>[])[0],
    false,
  );
});

Deno.test("save_product validates and rejects duplicate names", async () => {
  const db = createMockDb({
    ...baseSeed(),
    pos_products: [{
      id: "p1",
      customer_id: CID,
      name: "Flour 50kg",
      is_active: 1,
      selling_price_minor_units: 1000,
    }],
  });
  const bad = await ownerCall(db, "save_product", {
    product: { name: "", selling_price_minor_units: 5 },
  });
  assertEquals(bad.status, 400);
  assertEquals(bad.json.error, "Product name is required.");

  const dup = await ownerCall(db, "save_product", {
    product: { name: "flour 50KG", selling_price_minor_units: 5 },
  });
  assertEquals(dup.status, 409);
  assertEquals(dup.json.error, "A saved name already exists.");

  const ok = await ownerCall(db, "save_product", {
    product: { name: "Sugar 25kg", selling_price_minor_units: 700 },
  });
  assertEquals(ok.status, 200);
  assertEquals(ok.json.ok, true);
  assert(typeof ok.json.id === "string");
});

// ---------------------------------------------------------------------------
// Sales
// ---------------------------------------------------------------------------

Deno.test("insert_sale validates items and payment method", async () => {
  const db = createMockDb(baseSeed());
  const noItems = await ownerCall(db, "insert_sale", {
    sale: { receipt_number: "R-1", payment_method: "CASH" },
    items: [],
  });
  assertEquals(noItems.status, 400);
  assertEquals(noItems.json.error, "Incomplete sale.");

  const badPay = await ownerCall(db, "insert_sale", {
    sale: { receipt_number: "R-1", payment_method: "CRYPTO" },
    items: [{ product_name: "X" }],
  });
  assertEquals(badPay.status, 400);
  assertEquals(badPay.json.error, "Invalid payment method.");

  const ok = await ownerCall(db, "insert_sale", {
    sale: {
      id: "sale-1",
      receipt_number: "R-1",
      payment_method: "cash",
      shift_id: "shift-1",
    },
    items: [{ product_name: "Flour", quantity: 2 }],
    device_id: "dev-9",
  });
  assertEquals(ok.status, 200);
  assertEquals(ok.json.receipt_number, "R-1");
  const rpc = db.rpcCalls.find((c) => c.name === "pos_create_sale");
  assert(rpc);
  assertEquals(rpc!.params.p_customer, CID);
  assertEquals(rpc!.params.p_cashier, OWNER_ID);
  assertEquals(rpc!.params.p_device, "dev-9");
  assertEquals(rpc!.params.p_payment, "CASH");
});

Deno.test("next_receipt_number returns string receipt", async () => {
  const db = createMockDb(baseSeed());
  const r = await ownerCall(db, "next_receipt_number");
  assertEquals(r.status, 200);
  assertEquals(r.json, { ok: true, receipt_number: "0001" });
});

// ---------------------------------------------------------------------------
// Pagination + audit
// ---------------------------------------------------------------------------

Deno.test("shift_history paginates and reports truncated", async () => {
  const db = createMockDb({
    ...baseSeed(),
    shifts: [1, 2, 3].map((i) => ({
      id: `s${i}`,
      customer_id: CID,
      cashier_id: OWNER_ID,
      status: "CLOSED",
      opened_at: `2026-01-0${i}T00:00:00Z`,
    })),
  });
  const r = await ownerCall(db, "shift_history", { limit: 2 });
  assertEquals(r.status, 200);
  assertEquals((r.json.shifts as unknown[]).length, 2);
  assertEquals(r.json.truncated, true);
});

Deno.test("create_picklist writes an audit record", async () => {
  const db = createMockDb(baseSeed());
  const r = await ownerCall(db, "create_picklist", {
    picklist: { id: "pl-1", customer_name: "Kebede" },
    items: [{
      product_name: "Flour",
      requested_qty: 5,
      unit_price_minor_units: 100,
    }],
  });
  assertEquals(r.status, 200);
  const audits = db.table("pos_audit_logs");
  const hit = audits.find((a) => a.action === "PICKLIST_CREATED");
  assert(hit, "expected PICKLIST_CREATED audit row");
  assertEquals(hit!.customer_id, CID);
  assertEquals(hit!.user_id, OWNER_ID);
});

// ---------------------------------------------------------------------------
// Action registration parity
// ---------------------------------------------------------------------------

const EXPECTED_AUTHENTICATED_ACTIONS = [
  "change_password",
  "list_products",
  "save_product",
  "update_product",
  "deactivate_product",
  "reactivate_product",
  "next_receipt_number",
  "insert_sale",
  "search_sales",
  "void_sale",
  "request_void",
  "list_void_requests",
  "approve_void",
  "reject_void",
  "get_shift",
  "ensure_shift",
  "register_snapshot",
  "shift_history",
  "shift_summary",
  "open_shift",
  "close_shift",
  "add_cash_movement",
  "list_cash_movements",
  "list_users",
  "create_user",
  "set_user_permissions",
  "set_user_phone",
  "reset_password",
  "set_user_active",
  "delete_user",
  "finance_categories",
  "finance_deleted_categories",
  "finance_summaries",
  "finance_create_category",
  "finance_rename_category",
  "finance_delete_category",
  "finance_restore_category",
  "finance_permanently_delete_category",
  "finance_add_entry",
  "finance_update_entry",
  "finance_mark_completed",
  "finance_delete_entry",
  "finance_search_entries",
  "finance_person_totals",
  "list_picklists",
  "get_picklist_items",
  "create_picklist",
  "update_picklist_items",
  "get_customers",
  "add_customer",
  "toggle_picklist_item",
  "update_picklist_item",
  "delete_picklist_item",
  "delete_picklist",
  "list_stores",
  "create_store",
  "delete_store",
  "list_inventory",
  "create_inventory_product",
  "save_product_image",
  "dashboard_summary",
  "revenue_trend",
  "report_summary",
  "list_audit",
  "list_devices",
  "deactivate_device",
];

Deno.test(
  "every authenticated action has an explicit owner or feature policy",
  () => {
    // Password change is intentionally the sole self-service exception: any
    // authenticated active user may change their own credentials.
    const selfService = new Set(["change_password"]);
    const unclassified = Object.keys(ACTIONS).filter((action) =>
      !OWNER_ONLY.has(action) &&
      !Object.hasOwn(ACTION_FEATURES, action) &&
      !selfService.has(action)
    );
    assertEquals(unclassified, []);
  },
);

Deno.test("every monolith action is registered in the dispatch table", () => {
  assertEquals(
    Object.keys(ACTIONS).sort(),
    EXPECTED_AUTHENTICATED_ACTIONS.sort(),
  );
});

Deno.test("every registered action is reachable (never 'Unknown action')", async () => {
  const db = createMockDb(baseSeed());
  const token = await tokenFor(OWNER_ID, CID, "OWNER", 0);
  for (const action of EXPECTED_AUTHENTICATED_ACTIONS) {
    const r = await call(db, action, {}, { token });
    const isUnknown = r.status === 400 &&
      typeof r.json?.error === "string" &&
      (r.json.error as string).startsWith("Unknown action");
    assert(!isUnknown, `action ${action} fell through to Unknown action`);
  }
});

// Device-management authorization tests (Request 2).
//
// Proves the pos-api list_devices / deactivate_device actions are
// owner-only, tenant-scoped, fingerprint-masked, and self-deactivation
// protected — the properties the removed licensing-endpoint path lacked.

import "./test_env.ts";
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createMockDb, resetMockRateLimits, type Row } from "./mock_db.ts";
import { handleRequest } from "../index.ts";
import { signJwt } from "../shared/auth.ts";

const CUST = "11111111-1111-1111-1111-111111111111";
const OTHER_CUST = "22222222-2222-2222-2222-222222222222";
const OWNER_ID = "owner-1";
const CASHIER_ID = "cash-1";
const CODE = "MERCA-7Q2F-9K3X-4D8M-BN";
const FP_SELF = "fp-self-64chars-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const FP_OTHER = "fp-other-64chars-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

function seedDb() {
  return createMockDb({
    pos_users: [
      {
        id: OWNER_ID,
        customer_id: CUST,
        username: "owner",
        role: "OWNER",
        active: true,
        deleted_at: null,
        token_version: 0,
        permissions: [],
      },
      {
        id: CASHIER_ID,
        customer_id: CUST,
        username: "cash",
        role: "CASHIER",
        active: true,
        deleted_at: null,
        token_version: 0,
        permissions: ["pos"],
      },
      {
        id: "owner-2",
        customer_id: OTHER_CUST,
        username: "other",
        role: "OWNER",
        active: true,
        deleted_at: null,
        token_version: 0,
        permissions: [],
      },
    ] as unknown as Row[],
    licenses: [
      {
        activation_code: CODE,
        customer_id: CUST,
        seat_limit: 3,
        expires_at: null,
        revoked_at: null,
      },
      {
        activation_code: "OTHER-CODE-XXXX-XXXX-XXXX-XXXX",
        customer_id: OTHER_CUST,
        seat_limit: 3,
        expires_at: null,
        revoked_at: null,
      },
    ] as unknown as Row[],
    device_registrations: [
      {
        id: "reg-self",
        activation_code: CODE,
        device_fingerprint: FP_SELF,
        device_name: "This PC",
        first_seen: "2026-01-01T00:00:00Z",
        last_heartbeat: "2026-01-02T00:00:00Z",
        revoked_at: null,
      },
      {
        id: "reg-other",
        activation_code: CODE,
        device_fingerprint: FP_OTHER,
        device_name: "Lost phone",
        first_seen: "2026-01-01T00:00:00Z",
        last_heartbeat: "2026-01-02T00:00:00Z",
        revoked_at: null,
      },
      {
        id: "reg-foreign",
        activation_code: "OTHER-CODE-XXXX-XXXX-XXXX-XXXX",
        device_fingerprint: "fp-foreign",
        device_name: "Foreign device",
        first_seen: "2026-01-01T00:00:00Z",
        last_heartbeat: null,
        revoked_at: null,
      },
    ] as unknown as Row[],
    license_audit: [] as unknown as Row[],
    pos_audit_logs: [] as unknown as Row[],
  });
}

async function authed(
  db: any,
  action: string,
  body: Record<string, unknown>,
  opts: { userId?: string; customerId?: string; role?: string; tv?: number } =
    {},
) {
  const token = await signJwt({
    sub: opts.userId ?? OWNER_ID,
    cid: opts.customerId ?? CUST,
    role: opts.role ?? "OWNER",
    tv: opts.tv ?? 0,
  });
  return handleRequest(
    new Request("http://localhost/pos-api", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ action, ...body }),
    }),
    db,
  );
}

Deno.test("list_devices: missing JWT rejected", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await handleRequest(
    new Request("http://localhost/pos-api", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "list_devices" }),
    }),
    db,
  );
  assertEquals(res.status, 401);
});

Deno.test("list_devices: cashier JWT rejected (owner-only)", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "list_devices", {}, {
    userId: CASHIER_ID,
    role: "CASHIER",
  });
  assertEquals(res.status, 403);
});

Deno.test("list_devices: owner gets masked fingerprints + registration ids", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "list_devices", {
    device_fingerprint: FP_SELF,
  });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.active_devices, 2);
  const self = body.devices.find((d: any) => d.id === "reg-self");
  const other = body.devices.find((d: any) => d.id === "reg-other");
  assert(self && other);
  assertEquals(self.is_self, true);
  assertEquals(other.is_self, false);
  // No full fingerprint anywhere in the payload.
  const raw = JSON.stringify(body);
  assert(!raw.includes(FP_SELF), "full self fingerprint leaked");
  assert(!raw.includes(FP_OTHER), "full other fingerprint leaked");
  assert(other.fingerprint_masked.length < FP_OTHER.length);
});

Deno.test("list_devices: wrong-tenant owner sees no foreign devices", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "list_devices", {}, {
    userId: "owner-2",
    customerId: OTHER_CUST,
  });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.active_devices, 1);
  assertEquals(body.devices[0].id, "reg-foreign");
});

Deno.test("deactivate_device: owner deactivates another device, audited", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
    device_fingerprint: FP_SELF,
  });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  const reg = db.table("device_registrations").find((r) =>
    r.id === "reg-other"
  );
  assert(reg && reg.revoked_at != null);
  const auditRows = db.table("license_audit");
  assert(auditRows.some((r) => r.event === "deactivate"));
});

Deno.test("deactivate_device: self-deactivation refused server-side", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-self",
    device_fingerprint: FP_SELF,
  });
  assertEquals(res.status, 409);
  const reg = db.table("device_registrations").find((r) => r.id === "reg-self");
  assert(reg && reg.revoked_at == null, "self row must stay active");
});

Deno.test("deactivate_device: wrong-tenant registration id is 404", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-foreign",
    device_fingerprint: FP_SELF,
  });
  assertEquals(res.status, 404);
  const reg = db.table("device_registrations").find((r) =>
    r.id === "reg-foreign"
  );
  assert(reg && reg.revoked_at == null);
});

Deno.test("deactivate_device: cashier rejected before any lookup", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
  }, { userId: CASHIER_ID, role: "CASHIER" });
  assertEquals(res.status, 403);
});

Deno.test("durable rate limit: login failures throttle across instances", async () => {
  resetMockRateLimits();
  const db = seedDb();
  // No such user -> each attempt records a failure under the identity key.
  let saw429 = false;
  for (let i = 0; i < 15 && !saw429; i++) {
    const res = await handleRequest(
      new Request("http://localhost/pos-api", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "login",
          activation_code: CODE,
          username: "ghost",
          password: "wrong-password-1",
        }),
      }),
      db,
    );
    if (res.status === 429) saw429 = true;
  }
  assert(saw429, "expected login throttle 429");
  // And it persists for a "new instance" (fresh MockDb).
  const db2 = seedDb();
  const res2 = await handleRequest(
    new Request("http://localhost/pos-api", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "login",
        activation_code: CODE,
        username: "ghost",
        password: "wrong-password-1",
      }),
    }),
    db2,
  );
  assertEquals(res2.status, 429);
});

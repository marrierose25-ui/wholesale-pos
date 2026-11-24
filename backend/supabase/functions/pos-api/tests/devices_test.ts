// Device-management authorization tests (Request 2).
//
// Proves the pos-api list_devices / deactivate_device actions are
// owner-only, tenant-scoped, fingerprint-masked, and self-deactivation
// protected by a SERVER-VERIFIED signed device license — not by any
// client-supplied fingerprint field. The license is a bearer document
// (no device-held key / challenge-response): a copied license_code from
// another active device verifies identically — see the dedicated test
// below and docs/LICENSING.md "Limitations".

import { LICENSE_SECRET_KEY } from "./test_env.ts";
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ed25519 } from "https://esm.sh/@noble/curves@1.4.0/ed25519";
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

// --- Signed device-license proofs -----------------------------------------
// deactivate_device requires the caller's Ed25519-signed license so the
// server — not a request field — knows which hardware is calling.
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
async function makeLicense(
  overrides: Record<string, unknown> = {},
  secretKey: Uint8Array = LICENSE_SECRET_KEY,
): Promise<string> {
  const payload = {
    format: "wholesale-pos-license",
    version: 2,
    product: "wholesale_pos",
    entitlements: ["pos"],
    activation_code: CODE,
    customer_id: CUST,
    device_fingerprint: FP_SELF,
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

Deno.test("list_devices: verified license overrides a forged fingerprint hint", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "list_devices", {
    device_fingerprint: FP_OTHER, // forged hint
    license: await makeLicense(), // proves FP_SELF
  });
  assertEquals(res.status, 200);
  const body = await res.json();
  const self = body.devices.find((d: any) => d.id === "reg-self");
  const other = body.devices.find((d: any) => d.id === "reg-other");
  assertEquals(self.is_self, true);
  assertEquals(other.is_self, false);
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
    license: await makeLicense(), // device-bound to FP_SELF
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

Deno.test("deactivate_device: self-deactivation refused via verified proof", async () => {
  resetMockRateLimits();
  const db = seedDb();
  // License proves the caller IS reg-self's device; deactivating it must 409
  // even though no fingerprint field is sent at all.
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-self",
    license: await makeLicense(),
  });
  assertEquals(res.status, 409);
  const reg = db.table("device_registrations").find((r) => r.id === "reg-self");
  assert(reg && reg.revoked_at == null, "self row must stay active");
});

Deno.test("deactivate_device: forged body fingerprint cannot spoof self", async () => {
  resetMockRateLimits();
  const db = seedDb();
  // Attacker-controlled field claims to be FP_OTHER while the verified
  // license proves FP_SELF: the request field is ignored entirely, so
  // deactivating reg-other still succeeds and reg-self is untouched.
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
    device_fingerprint: FP_OTHER, // forged hint — must not be trusted
    license: await makeLicense(),
  });
  assertEquals(res.status, 200);
});

Deno.test("deactivate_device: missing license proof fails closed", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
    device_fingerprint: FP_SELF,
  });
  assertEquals(res.status, 403);
  const reg = db.table("device_registrations").find((r) =>
    r.id === "reg-other"
  );
  assert(reg && reg.revoked_at == null, "unproven request must not revoke");
});

Deno.test("deactivate_device: forged license signature rejected", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const wrongKey = ed25519.utils.randomPrivateKey();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
    license: await makeLicense({}, wrongKey),
  });
  assertEquals(res.status, 403);
});

Deno.test("deactivate_device: license for another tenant rejected", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
    license: await makeLicense({ customer_id: OTHER_CUST }),
  });
  assertEquals(res.status, 403);
});

Deno.test("deactivate_device: unbound web session (no device proof) fails closed", async () => {
  resetMockRateLimits();
  const db = seedDb();
  // A web/PWA owner JWT is a valid session but carries no per-device
  // license — the endpoint refuses rather than pretend self-protection.
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
  });
  assertEquals(res.status, 403);
});

Deno.test("deactivate_device: license whose device was revoked is not proof", async () => {
  resetMockRateLimits();
  const db = seedDb();
  // Revoke the caller's own registration, then try to manage devices with
  // its still-unexpired license: the active-seat check must refuse.
  const self = db.table("device_registrations").find((r) =>
    r.id === "reg-self"
  );
  assert(self);
  self.revoked_at = new Date().toISOString();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-other",
    license: await makeLicense(),
  });
  assertEquals(res.status, 403);
});

Deno.test("deactivate_device: copied license is bearer proof, not hardware-bound", async () => {
  resetMockRateLimits();
  const db = seedDb();
  // The signed license is a bearer DOCUMENT: there is no device-held
  // private key and no challenge-response, so a license_code copied from
  // another still-active device (FP_OTHER's, minted below exactly as
  // activation would have issued it) verifies identically. Self-protection
  // therefore follows the LICENSE's fingerprint, not proven hardware:
  // presenting FP_OTHER's license while targeting reg-self (FP_SELF)
  // deactivates the caller's own device — the check sees "device FP_OTHER
  // is acting", which is not the target. This pins the documented
  // limitation for the Request 3 threat-model review; it is NOT a claim
  // that hardware-bound proof-of-possession exists.
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-self",
    license: await makeLicense({ device_fingerprint: FP_OTHER }),
  });
  assertEquals(res.status, 200);
  const reg = db.table("device_registrations").find((r) => r.id === "reg-self");
  assert(reg && reg.revoked_at != null);
});

Deno.test("deactivate_device: wrong-tenant registration id is 404", async () => {
  resetMockRateLimits();
  const db = seedDb();
  const res = await authed(db, "deactivate_device", {
    registration_id: "reg-foreign",
    license: await makeLicense(),
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

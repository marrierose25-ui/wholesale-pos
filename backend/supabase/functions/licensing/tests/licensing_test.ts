// Licensing Edge Function handler tests (Request 2).
//
// Covers: unlimited activation via the register_device RPC, deprecated
// management/voucher endpoints, durable rate-limit 429s, and input
// validation. The SQL semantics of register_device itself are proven by the
// PostgreSQL integration tests; here the RPC is mocked to isolate handler
// behaviour.

import "./test_env.ts";
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createMockDb,
  resetMockRateLimits,
  type Row,
} from "../../pos-api/tests/mock_db.ts";

const { handleRequest } = await import("../index.ts");

const CODE = "MERCA-7Q2F-9K3X-4D8M-BN";
const FP = "fp-device-1";

function post(body: unknown, xff?: string): Request {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (xff !== undefined) headers["x-forwarded-for"] = xff;
  return new Request("http://localhost/licensing", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

interface RegRow extends Row {
  activation_code: string;
  device_fingerprint: string;
  revoked_at: string | null;
}

// Minimal in-memory register_device mirroring the SQL contract: license-row
// serialized semantics are collapsed here, but status mapping, idempotent
// fingerprint reuse, reactivation, revoked/expired refusals, and the
// unlimited insert are all exercised.
function makeDb(opts: {
  license?: Row | null;
  regs?: RegRow[];
}) {
  const regs = opts.regs ?? [];
  const license = opts.license === undefined
    ? {
      activation_code: CODE,
      customer_id: "cust-1",
      seat_limit: 1, // legacy cap of 1 — unlimited policy must ignore it
      expires_at: null,
      revoked_at: null,
    }
    : opts.license;
  const audit: Row[] = [];
  const db = createMockDb(
    { device_registrations: regs as unknown as Row[], license_audit: audit },
    {
      register_device: (p, d) => {
        if (!license) return { status: "not_found" };
        if (license.revoked_at) return { status: "revoked" };
        if (
          license.expires_at &&
          Date.parse(String(license.expires_at)) < Date.now()
        ) {
          return { status: "expired" };
        }
        const existing = d.table("device_registrations").find((r) =>
          r.activation_code === p.p_activation_code &&
          r.device_fingerprint === p.p_device_fingerprint
        );
        const used = () =>
          d.table("device_registrations").filter((r) =>
            r.activation_code === p.p_activation_code && r.revoked_at == null
          ).length;
        const base = {
          seat_limit: license.seat_limit,
          customer_id: license.customer_id,
          expires_at: license.expires_at,
        };
        if (existing) {
          if (existing.revoked_at == null) {
            existing.last_heartbeat = new Date().toISOString();
            return { status: "refreshed", seats_used: used(), ...base };
          }
          existing.revoked_at = null;
          return { status: "reactivated", seats_used: used(), ...base };
        }
        d.table("device_registrations").push({
          id: crypto.randomUUID(),
          activation_code: p.p_activation_code,
          device_fingerprint: p.p_device_fingerprint,
          device_name: p.p_device_name,
          revoked_at: null,
          last_heartbeat: new Date().toISOString(),
        });
        return { status: "activated", seats_used: used(), ...base };
      },
    },
  );
  return { db, regs, audit };
}

async function activate(db: any, code = CODE, fp = FP, xff?: string) {
  const res = await handleRequest(
    post({
      action: "activate_device",
      activation_code: code,
      device_fingerprint: fp,
      device_name: "Test device",
    }, xff),
    db,
  );
  return { res, body: await res.json() };
}

Deno.test("unlimited activation: seat_limit=1 license activates many devices", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  for (let i = 0; i < 5; i++) {
    const { res, body } = await activate(db, CODE, `fp-${i}`);
    assertEquals(res.status, 200);
    assertEquals(body.ok, true);
    assert(
      typeof body.license_code === "string" && body.license_code.includes("."),
    );
  }
  assertEquals(db.table("device_registrations").length, 5);
});

Deno.test("same fingerprint activation is idempotent (no duplicate rows)", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  const a = await activate(db);
  const b = await activate(db);
  assertEquals(a.body.ok, true);
  assertEquals(b.body.ok, true);
  assertEquals(db.table("device_registrations").length, 1);
});

Deno.test("reactivates a revoked registration for the same fingerprint", async () => {
  resetMockRateLimits();
  const { db } = makeDb({
    regs: [{
      id: "r1",
      activation_code: CODE,
      device_fingerprint: FP,
      device_name: "Old",
      revoked_at: new Date().toISOString(),
    }],
  });
  const { body } = await activate(db);
  assertEquals(body.ok, true);
  const rows = db.table("device_registrations");
  assertEquals(rows.length, 1);
  assertEquals(rows[0].revoked_at, null);
});

Deno.test("revoked license cannot register a device", async () => {
  resetMockRateLimits();
  const { db } = makeDb({
    license: {
      activation_code: CODE,
      customer_id: "c",
      seat_limit: 3,
      expires_at: null,
      revoked_at: new Date().toISOString(),
    },
  });
  const { res, body } = await activate(db);
  assertEquals(res.status, 403);
  assertEquals(body.error, "License revoked.");
});

Deno.test("expired license cannot register a device", async () => {
  resetMockRateLimits();
  const { db } = makeDb({
    license: {
      activation_code: CODE,
      customer_id: "c",
      seat_limit: 3,
      expires_at: new Date(Date.now() - 86400000).toISOString(),
      revoked_at: null,
    },
  });
  const { res, body } = await activate(db);
  assertEquals(res.status, 403);
  assertEquals(body.error, "License expired.");
});

Deno.test("unknown code returns 404", async () => {
  resetMockRateLimits();
  const { db } = makeDb({ license: null });
  const { res, body } = await activate(db, "NOPE-XXXX-XXXX-XXXX-XXXX-XX");
  assertEquals(res.status, 404);
});

Deno.test("durable rate limit: repeated activation attempts get 429", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  // ACTIVATE_LIMIT is 30 per 600s; fire 35 attempts on one code.
  let saw429 = false;
  for (let i = 0; i < 35; i++) {
    const { res, body } = await activate(db, CODE, `fp-r-${i}`);
    if (res.status === 429) {
      saw429 = true;
      assert(typeof body.retry_after_seconds === "number");
      break;
    }
  }
  assert(saw429, "expected a 429 within 35 attempts");
});

Deno.test("source limit: many different codes from one source get 429", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  // ACTIVATE_SOURCE_LIMIT is 120 per 600s. Rotate through DISTINCT codes so
  // the per-code bucket never trips — only the source bucket can stop this.
  let saw429 = false;
  for (let i = 0; i < 130 && !saw429; i++) {
    const { res } = await activate(
      db,
      `PROBE-${i.toString().padStart(4, "0")}-XXXX-XXXX-XXXX`,
      `fp-probe-${i}`,
      "203.0.113.10, 10.0.0.1", // rightmost = platform-appended peer
    );
    if (res.status === 429) saw429 = true;
  }
  assert(saw429, "expected source-level 429 while rotating codes");
});

Deno.test("source limit: different sources do not share a bucket", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  // Exhaust source A's bucket.
  let blocked = false;
  for (let i = 0; i < 130 && !blocked; i++) {
    const { res } = await activate(
      db,
      `PROBE-A${i}-XXXX-XXXX-XXXX-XXXX`,
      `fp-a-${i}`,
      "198.51.100.7",
    );
    if (res.status === 429) blocked = true;
  }
  assert(blocked, "source A should have been throttled");
  // Source B must still be served — buckets are per-source, not global.
  // (The mock register_device accepts any code while a license exists, so
  // a served request returns 200; the assertion is "not 429".)
  const { res } = await activate(
    db,
    "OTHER-CODE-XXXX-XXXX-XXXX-XXXX",
    "fp-b-1",
    "192.0.2.55",
  );
  assert(res.status !== 429, `source B must not share source A's bucket`);
});

Deno.test("source limit: client-forged leftmost XFF entries are ignored", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  // Two requests claiming different forged leftmost addresses but the same
  // platform-appended rightmost peer must share ONE source bucket.
  for (let i = 0; i < 125; i++) {
    const { res } = await activate(
      db,
      `FORGE-${i}-XXXX-XXXX-XXXX-XXXX`,
      `fp-f-${i}`,
      `${10 + i}.1.1.1, 203.0.113.99`,
    );
    if (i === 124) {
      // Requests 121+ on the same rightmost source exceed the 120 cap.
      assertEquals(res.status, 429);
    }
  }
});

Deno.test("rate limit survives a new function instance (fresh db object)", async () => {
  resetMockRateLimits();
  const { db: db1 } = makeDb({});
  // Prime the limiter close to the cap on db1.
  for (let i = 0; i < 30; i++) {
    await activate(db1, CODE, `fp-p-${i}`);
  }
  // A "new instance" = a different MockDb; the module-level bucket store
  // (standing in for the rate_limit_buckets table) must still refuse.
  const { db: db2 } = makeDb({});
  const { res } = await activate(db2, CODE, "fp-new-instance");
  assertEquals(res.status, 429);
});

Deno.test("list_devices / deactivate_device / redeem_voucher are deprecated", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  for (
    const action of ["list_devices", "deactivate_device", "redeem_voucher"]
  ) {
    const res = await handleRequest(
      post({
        action,
        activation_code: CODE,
        device_fingerprint: FP,
        voucher_code: "V-ABCDEFGH",
      }),
      db,
    );
    assertEquals(res.status, 410, action);
    const body = await res.json();
    assertEquals(body.deprecated, true);
    assertEquals(body.ok, false);
  }
});

Deno.test("missing fields and oversized input are rejected", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  let res = await handleRequest(post({ action: "activate_device" }), db);
  assertEquals(res.status, 400);
  res = await handleRequest(
    post({
      action: "activate_device",
      activation_code: "X".repeat(200),
      device_fingerprint: FP,
    }),
    db,
  );
  assertEquals(res.status, 400);
});

Deno.test("unknown action and non-POST are rejected", async () => {
  resetMockRateLimits();
  const { db } = makeDb({});
  let res = await handleRequest(post({ action: "nope" }), db);
  assertEquals(res.status, 400);
  res = await handleRequest(
    new Request("http://x/", { method: "GET" }),
    db,
  );
  assertEquals(res.status, 405);
});

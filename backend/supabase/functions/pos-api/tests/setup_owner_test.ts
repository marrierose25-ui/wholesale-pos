// Request 3 P0 regression tests for the setup_owner bootstrap path.
//
// Covers the two acceptance defects:
//   A. A native bootstrap sends user_id + pw_salt/pw_hash and NO plaintext
//      password — it must reach pos_setup_owner instead of dying on the
//      "Missing fields" check.
//   B. A same-id retry must VERIFY the submitted credential before any OWNER
//      JWT is issued: same credentials converge, anything else conflicts.

import "./test_env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createMockDb, type MockDb, resetMockRateLimits } from "./mock_db.ts";

const { handleRequest } = await import("../index.ts");

const CID = "cust-boot";
const CODE = "BOOT-CODE";
const OWNER_ID = "11111111-2222-3333-4444-555555555555";
// Valid cloud credential shape: 16-byte base64 salt + "210000$<b64 hash>".
const SALT = "AAAAAAAAAAAAAAAAAAAAAA==";
const HASH = `210000$${"A".repeat(43)}=`;

function seed(): MockDb {
  resetMockRateLimits();
  return createMockDb({
    pos_users: [],
    pos_settings: [],
    licenses: [{
      activation_code: CODE,
      customer_id: CID,
      revoked_at: null,
      expires_at: null,
    }],
  });
}

async function call(
  db: MockDb,
  body: Record<string, unknown>,
): Promise<{ status: number; json: Record<string, unknown> }> {
  const req = new Request("http://localhost/pos-api", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "setup_owner", ...body }),
  });
  const res = await handleRequest(req, db);
  return { status: res.status, json: await res.json() };
}

function preHashed(over: Record<string, unknown> = {}) {
  return {
    activation_code: CODE,
    username: "0912345678",
    user_id: OWNER_ID,
    pw_salt: SALT,
    pw_hash: HASH,
    ...over,
  };
}

Deno.test("setup_owner accepts pre-hashed credentials without a password", async () => {
  const db = seed();
  const r = await call(db, preHashed());
  assertEquals(r.status, 200);
  assertEquals(r.json.ok, true);
  assertEquals(r.json.user_id, OWNER_ID);
  assertEquals(r.json.role, "OWNER");
  assert(typeof r.json.token === "string" && r.json.token.length > 20);
  const owner = db.table("pos_users").find((u) => u.id === OWNER_ID);
  assert(owner, "owner row must be created with the supplied id");
  assertEquals(owner.pw_salt, SALT);
  assertEquals(owner.pw_hash, HASH);
});

Deno.test("setup_owner still requires a credential of some kind", async () => {
  const db = seed();
  const r = await call(db, {
    activation_code: CODE,
    username: "0912345678",
    user_id: OWNER_ID,
  });
  assertEquals(r.status, 400);
  assertEquals(r.json.error, "Missing fields");
});

Deno.test("same-id retry with identical credentials returns a session", async () => {
  const db = seed();
  const first = await call(db, preHashed());
  assertEquals(first.json.ok, true);
  const retry = await call(db, preHashed());
  assertEquals(retry.status, 200);
  assertEquals(retry.json.ok, true);
  assertEquals(retry.json.user_id, OWNER_ID);
  assertEquals(
    db.table("pos_users").filter((u) => u.role === "OWNER").length,
    1,
    "idempotent retry must not create a second owner",
  );
});

Deno.test("same-id retry with a different hash is refused, no JWT", async () => {
  const db = seed();
  await call(db, preHashed());
  const r = await call(db, preHashed({ pw_hash: `210000$${"B".repeat(43)}=` }));
  assertEquals(r.status, 409);
  assertEquals(r.json.ok, false);
  assertEquals(r.json.error, "Owner already exists.");
  assertEquals(r.json.token, undefined, "no session may be minted");
});

Deno.test("same-id retry with a different username is refused", async () => {
  const db = seed();
  await call(db, preHashed());
  const r = await call(db, preHashed({ username: "0919999999" }));
  assertEquals(r.status, 409);
  assertEquals(r.json.ok, false);
  assertEquals(r.json.token, undefined);
});

Deno.test("a different existing owner produces a visible conflict", async () => {
  const db = seed();
  db.table("pos_users").push({
    id: "existing-owner",
    customer_id: CID,
    username: "0911111111",
    role: "OWNER",
    active: true,
    deleted_at: null,
    permissions: [],
    token_version: 0,
    pw_salt: SALT,
    pw_hash: HASH,
    is_demo: false,
  });
  const r = await call(db, preHashed());
  assertEquals(r.status, 409);
  assertEquals(r.json.ok, false);
  assertEquals(r.json.owner_id, "existing-owner");
  assertEquals(r.json.token, undefined);
});

Deno.test("plaintext bootstrap still works and verifies on retry", async () => {
  const db = seed();
  const password = "correct-horse-battery";
  const first = await call(db, {
    activation_code: CODE,
    username: "0912345678",
    user_id: OWNER_ID,
    password,
  });
  assertEquals(first.json.ok, true);
  // Same id + same password converges (the stored hash is verified, not
  // compared — the salt is re-randomized every call).
  const retry = await call(db, {
    activation_code: CODE,
    username: "0912345678",
    user_id: OWNER_ID,
    password,
  });
  assertEquals(retry.status, 200);
  assertEquals(retry.json.ok, true);
  // Same id + WRONG password must never mint a session.
  const wrong = await call(db, {
    activation_code: CODE,
    username: "0912345678",
    user_id: OWNER_ID,
    password: "wrong-password-123",
  });
  assertEquals(wrong.status, 409);
  assertEquals(wrong.json.token, undefined);
});

// Inventory API action tests: deleteStore routes through the atomic
// pos_delete_store RPC and maps its refusals to the right HTTP status.

import "./test_env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { createMockDb, type MockDb, type Row } from "./mock_db.ts";
import { signJwt } from "../shared/auth.ts";

const { handleRequest } = await import("../index.ts");

const CID = "cust-1";
const OWNER_ID = "user-owner-1";

function baseSeed(): Record<string, Row[]> {
  return {
    pos_users: [{
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
    }],
    licenses: [{
      activation_code: "ACT-CODE",
      customer_id: CID,
      revoked_at: null,
      expires_at: null,
    }],
  };
}

async function call(
  db: MockDb,
  action: string,
  body: Record<string, unknown> = {},
): Promise<{ status: number; json: Record<string, unknown> }> {
  const token = await signJwt({
    sub: OWNER_ID,
    cid: CID,
    role: "OWNER",
    tv: 0,
  });
  const req = new Request("http://localhost/pos-api", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ action, ...body }),
  });
  const res = await handleRequest(req, db);
  return { status: res.status, json: await res.json() };
}

Deno.test("delete_store maps inventory-blocked RPC error to 409", async () => {
  const db = createMockDb(baseSeed(), {
    pos_delete_store: () => ({ __error: "Store still has inventory records." }),
  });
  const r = await call(db, "delete_store", { id: "st-1" });
  assertEquals(r.status, 409);
  assertEquals(r.json.ok, false);
});

Deno.test("delete_store missing store maps to 404", async () => {
  const db = createMockDb(baseSeed(), {
    pos_delete_store: () => ({ __error: "Store not found." }),
  });
  const r = await call(db, "delete_store", { id: "st-x" });
  assertEquals(r.status, 404);
});

Deno.test("delete_store success returns ok and calls the RPC", async () => {
  const db = createMockDb(baseSeed(), {
    pos_delete_store: () => ({ ok: true }),
  });
  const r = await call(db, "delete_store", { id: "st-1" });
  assertEquals(r.status, 200);
  assertEquals(r.json.ok, true);
  const call0 = db.rpcCalls.find((c) => c.name === "pos_delete_store");
  assertEquals(call0?.params.p_customer, CID);
  assertEquals(call0?.params.p_store_id, "st-1");
});

// Architecture guard: the production entry point must stay the modular
// router. If index.ts regresses to an inline monolithic handler (its own
// Deno.serve(async ...) switch over private functions), this test fails.

import "./test_env.ts";
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const indexSource = await Deno.readTextFile(
  new URL("../index.ts", import.meta.url),
);

Deno.test("pos-api entry point dispatches through domain modules", () => {
  for (
    const domain of [
      "catalog",
      "finance",
      "register",
      "reporting",
      "sales",
      "users",
      "warehouse",
    ]
  ) {
    assertStringIncludes(
      indexSource,
      `./modules/${domain}/index.ts`,
      `index.ts must import modules/${domain}`,
    );
  }
  assertStringIncludes(indexSource, "./shared/auth.ts");
  assertStringIncludes(indexSource, "./shared/authorization.ts");
  assertStringIncludes(indexSource, "./shared/helpers.ts");
});

Deno.test("pos-api entry point has no inline monolithic handler", () => {
  // The old monolith defined every action as a private function inside
  // index.ts and served an anonymous async handler. Neither pattern may
  // return.
  assert(
    !indexSource.includes("Deno.serve(async"),
    "index.ts must not serve an inline anonymous handler",
  );
  for (
    const fn of [
      "async function insertSale(",
      "async function createPicklist(",
      "async function financeAddEntry(",
      "async function deletePicklistItem(",
      "async function listProducts(",
      "async function createUser(",
      "async function dashboardSummary(",
      "switch (action)",
    ]
  ) {
    assert(
      !indexSource.includes(fn),
      `index.ts still contains monolith implementation marker: ${fn}`,
    );
  }
});

Deno.test("pos-api entry point exports the dispatch table for parity tests", async () => {
  const mod = await import("../index.ts");
  assertEquals(typeof mod.handleRequest, "function");
  assertEquals(typeof mod.ACTIONS, "object");
  assert(Object.keys(mod.ACTIONS).length > 50);
});

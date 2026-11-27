// Test-only environment. index.ts validates env at module load, so this
// MUST be imported before ../index.ts.
Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");
Deno.env.set(
  "SUPABASE_SERVICE_ROLE_KEY",
  "test-service-role-key-0123456789abcdef",
);
// 32 zero bytes -> 43-char base64url; satisfies the seed-length check.
Deno.env.set(
  "LICENSE_SIGNING_SEED_B64URL",
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
);

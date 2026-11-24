// Test-only environment. shared/env.ts validates these at module load, so
// this file MUST be imported before any pos-api module in a test file.
Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");
Deno.env.set(
  "SUPABASE_SERVICE_ROLE_KEY",
  "test-service-role-key-0123456789abcdef",
);
Deno.env.set("POS_API_JWT_SECRET", "test-jwt-secret-0123456789abcdef0123");

// Test-only environment. shared/env.ts validates these at module load, so
// this file MUST be imported before any pos-api module in a test file.
//
// A FIXED test-only Ed25519 keypair (never a production key): tests mint
// signed device licenses with LICENSE_SECRET_KEY and the functions verify
// them against POS_API_LICENSE_PUBLIC_KEY, exactly like production. The
// key is a constant so this module stays synchronous — a top-level await
// here made env setup race module evaluation.
function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}
const LICENSE_SEED_HEX =
  "a5b2df3c165ebe1f02df94901109baab185b3097deff0a660b2df89e8c05b6d4";
export const LICENSE_SECRET_KEY = hexToBytes(LICENSE_SEED_HEX);
export const LICENSE_PUBLIC_KEY_HEX =
  "e791d96756cfa13dfae5762f5544b5635e5f1406af9f35715f5df94b10620d2d";

Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");
Deno.env.set(
  "SUPABASE_SERVICE_ROLE_KEY",
  "test-service-role-key-0123456789abcdef",
);
Deno.env.set("POS_API_JWT_SECRET", "test-jwt-secret-0123456789abcdef0123");
Deno.env.set("POS_API_LICENSE_PUBLIC_KEY", LICENSE_PUBLIC_KEY_HEX);

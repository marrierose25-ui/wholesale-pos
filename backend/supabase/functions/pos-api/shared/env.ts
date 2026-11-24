function requireEnv(name: string, minLength = 16): string {
  const v = Deno.env.get(name);
  if (!v || v.length < minLength) {
    throw new Error(`Env var ${name} missing or too short (min ${minLength}).`);
  }
  return v;
}

export const SUPABASE_URL = requireEnv("SUPABASE_URL");
export const SERVICE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
export const JWT_SECRET = requireEnv("POS_API_JWT_SECRET", 32);
// Ed25519 public key (64 hex chars) matching the licensing function's
// LICENSE_SIGNING_SEED_B64URL private key — the same key the `sync` gateway
// verifies licenses against (SYNC_LICENSE_PUBLIC_KEY). Device-management
// actions use it to verify the signed license a device presents as proof of
// which hardware is calling; without it no request can prove a device
// identity and self-deactivation protection fails closed.
export const LICENSE_PUBLIC_KEY_HEX = requireEnv(
  "POS_API_LICENSE_PUBLIC_KEY",
  64,
);

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

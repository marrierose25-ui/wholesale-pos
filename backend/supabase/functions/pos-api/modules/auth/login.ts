// Imports for createClient, Ctx, json, str, strip
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import type { Ctx } from "../../shared/types.ts";
import { json, str } from "../../shared/helpers.ts";
import { SERVICE_KEY, SUPABASE_URL } from "../../shared/env.ts";
// Re-export the auth functions from shared/auth.ts so callers import through the barrel
export {
  changePassword,
  hasUsers,
  login,
  setupOwner,
} from "../../shared/auth.ts";
export type { Ctx } from "../../shared/types.ts";

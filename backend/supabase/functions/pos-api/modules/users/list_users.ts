import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import type { Ctx } from "../../shared/types.ts";
import { json, pageLimit, str, strip } from "../../shared/helpers.ts";

export async function listUsers(db: any, ctx: Ctx, _body: any) {
  const limit = pageLimit(_body, 1000);
  const { data, error } = await db.from("pos_users")
    .select("id, username, role, active, created_at, permissions, is_demo").eq(
      "customer_id",
      ctx.customerId,
    )
    .is("deleted_at", null)
    .order("username")
    .limit(limit);
  if (error) throw new Error(error.message);
  return json({ ok: true, users: strip(data) });
}

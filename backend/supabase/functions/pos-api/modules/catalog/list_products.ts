import type { Ctx } from "../../shared/types.ts";
import { json, strip } from "../../shared/helpers.ts";

export async function listProducts(db: any, ctx: Ctx, body: any) {
  const inactive = body.inactive === true;
  const { data, error } = await db.from("pos_products").select("*")
    .eq("customer_id", ctx.customerId).eq("is_active", inactive ? 0 : 1)
    .order("name", { ascending: true });
  if (error) throw new Error(error.message);
  return json({ ok: true, products: strip(data) });
}

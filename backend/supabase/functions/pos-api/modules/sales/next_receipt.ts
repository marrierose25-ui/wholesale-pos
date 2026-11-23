import type { Ctx } from "../../shared/types.ts";
import { json, str, strip } from "../../shared/helpers.ts";
import { shopDay } from "../../shared/helpers.ts";

export async function nextReceiptNumber(db: any, ctx: Ctx) {
  const day = shopDay();
  const { data, error } = await db.rpc("pos_next_receipt", {
    p_customer: ctx.customerId,
    p_day: day,
  });
  if (error) throw new Error(error.message);
  return json({ ok: true, receipt_number: String(data) });
}

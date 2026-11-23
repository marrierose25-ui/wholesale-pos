import type { Ctx } from "../../shared/types.ts";
import { json, strip } from "../../shared/helpers.ts";

import { cashierPerformance } from "./revenue.ts";

export async function dashboardSummary(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const start = body.period_start ?? null;
  const end = body.period_end ?? null;
  // All headline totals come from the pos_sales_totals SQL aggregate so the
  // numbers stay exact past PostgREST's 1000-row fetch cap (audit #9).
  const { data: tot, error: totErr } = await db.rpc("pos_sales_totals", {
    p_customer: ctx.customerId,
    p_start: start,
    p_end: end,
  });
  if (totErr) throw new Error(totErr.message);
  const t = typeof tot === "string" ? JSON.parse(tot) : (tot ?? {});
  const revenue = Number(t.revenue ?? 0);
  const count = Number(t.sales_count ?? 0);

  // Expected cash uses the currently open shift (mirrors the native dashboard).
  let expectedCash = 0;
  let shiftOpen = 0;
  const { data: openShift } = await db.from("shifts").select("*")
    .eq("customer_id", ctx.customerId).eq("status", "OPEN").limit(1)
    .maybeSingle();
  if (openShift) {
    shiftOpen = 1;
    expectedCash = await computeExpectedCash(db, ctx.customerId, openShift);
  }

  return json({
    ok: true,
    stats: {
      revenue,
      sales_count: count,
      cash_revenue: Number(t.cash_revenue ?? 0),
      bank_revenue: Number(t.bank_revenue ?? 0),
      average_sale: count === 0 ? 0 : Math.floor(revenue / count),
      expected_cash: expectedCash,
      is_shift_open: shiftOpen,
      void_count: Number(t.void_count ?? 0),
      pending_void_requests: Number(t.pending_void_requests ?? 0),
    },
  });
}

async function computeExpectedCash(
  db: any,
  customerId: string,
  shift: any,
): Promise<number> {
  const { data, error } = await db.rpc("pos_expected_cash", {
    p_customer: customerId,
    p_shift_id: shift.id,
  });
  if (error) throw new Error(error.message);
  return Promise.resolve(Number(data ?? 0));
}

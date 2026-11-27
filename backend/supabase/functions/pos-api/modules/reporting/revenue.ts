import type { Ctx } from "../../shared/types.ts";
import { json, usernamesById } from "../../shared/helpers.ts";

export async function revenueTrend(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const { data, error } = await db.rpc("pos_revenue_trend", {
    p_customer: ctx.customerId,
    p_start: body.period_start ?? null,
    p_end: body.period_end ?? null,
  });
  if (error) throw new Error(error.message);
  const trend = typeof data === "string" ? JSON.parse(data) : (data ?? []);
  return json({ ok: true, trend });
}

export async function reportSummary(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const rangeStart = body.period_start ?? null;
  const rangeEnd = body.period_end ?? null;
  // Product mix aggregated in SQL (audit #9): exact across every matching line
  // item rather than the first 1000 sales PostgREST would return.
  const { data, error } = await db.rpc("pos_product_summary", {
    p_customer: ctx.customerId,
    p_start: rangeStart,
    p_end: rangeEnd,
  });
  if (error) throw new Error(error.message);
  const productSummary = typeof data === "string"
    ? JSON.parse(data)
    : (data ?? []);
  return json({
    ok: true,
    product_summary: productSummary,
    cashier_performance: await cashierPerformance(
      db,
      ctx,
      rangeStart,
      rangeEnd,
    ),
  });
}

// Sales count + revenue per cashier, aggregated in SQL and hydrated with the
// operator username (cashier_id is the pos_users key) for the reports screen.
export async function cashierPerformance(
  db: any,
  ctx: Ctx,
  start: any,
  end: any,
): Promise<any[]> {
  const { data, error } = await db.rpc("pos_cashier_performance", {
    p_customer: ctx.customerId,
    p_start: start ?? null,
    p_end: end ?? null,
  });
  if (error) throw new Error(error.message);
  const rows =
    (typeof data === "string" ? JSON.parse(data) : (data ?? [])) as any[];
  const names = await usernamesById(
    db,
    ctx,
    rows.map((r: any) => r.cashier_id),
  );
  return rows.map((r: any) => ({
    username: names[r.cashier_id] ?? null,
    total_sales: Number(r.total_sales ?? 0),
    total_revenue: Number(r.total_revenue ?? 0),
  }));
}

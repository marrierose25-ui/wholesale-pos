import type { Ctx } from "../../shared/types.ts";
import { json, strip } from "../../shared/helpers.ts";

export async function financeCategories(db: any, ctx: Ctx) {
  const { data, error } = await db.from("pos_finance_categories").select("*")
    .eq("customer_id", ctx.customerId).is("deleted_at", null).order("name");
  if (error) throw new Error(error.message);
  const cats = strip(data).map((c: any) => ({
    ...c,
    updated_at: c.updated_at ?? c.created_at,
  }));
  return json({ ok: true, categories: cats });
}

export async function financeDeletedCategories(db: any, ctx: Ctx) {
  const { data, error } = await db.from("pos_finance_categories").select("*")
    .eq("customer_id", ctx.customerId).not("deleted_at", "is", null)
    .order("deleted_at", { ascending: false });
  if (error) throw new Error(error.message);
  const cats = strip(data).map((c: any) => ({
    ...c,
    updated_at: c.updated_at ?? c.created_at,
  }));
  return json({ ok: true, categories: cats });
}

export async function financeSummaries(db: any, ctx: Ctx) {
  const { data: cats, error: catErr } = await db.from("pos_finance_categories")
    .select("id, name")
    .eq("customer_id", ctx.customerId).is("deleted_at", null).order("name")
    .limit(500);
  if (catErr) throw new Error(catErr.message);
  const { data: entries, error: entErr } = await db.from("pos_finance_entries")
    .select("category_id, amount_minor_units")
    .eq("customer_id", ctx.customerId).eq("status", "PENDING")
    .limit(5000);
  if (entErr) throw new Error(entErr.message);
  const totals: Record<string, { count: number; total: number }> = {};
  for (const e of entries ?? []) {
    const t = (totals[e.category_id] ??= { count: 0, total: 0 });
    t.count++;
    t.total += Number(e.amount_minor_units);
  }
  return json({
    ok: true,
    summaries: (cats ?? []).map((c: any) => ({
      id: c.id,
      name: c.name,
      pending_count: totals[c.id]?.count ?? 0,
      pending_total: totals[c.id]?.total ?? 0,
    })),
  });
}

export async function financePersonTotals(db: any, ctx: Ctx, body: any) {
  const { data, error } = await db.rpc("pos_finance_person_totals", {
    p_customer: ctx.customerId,
    p_category_id: String(body.category_id ?? ""),
  });
  if (error) throw new Error(error.message);
  const totals = data ?? {};
  return json({
    ok: true,
    totals: {
      pending_total: Number(totals.pending_total ?? 0),
      completed_total: Number(totals.completed_total ?? 0),
    },
  });
}

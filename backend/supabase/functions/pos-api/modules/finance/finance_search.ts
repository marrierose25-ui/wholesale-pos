import type { Ctx } from "../../shared/types.ts";
import { json, pageLimit, str, strip } from "../../shared/helpers.ts";

import { categoryNames } from "./finance_mutations.ts";

export async function financeSearchEntries(db: any, ctx: Ctx, body: any) {
  let q = db.from("pos_finance_entries").select("*").eq(
    "customer_id",
    ctx.customerId,
  )
    .neq("status", "DELETED")
    .order("entry_date", { ascending: false }).limit(pageLimit(body));
  if (body.category_id) q = q.eq("category_id", body.category_id);
  if (body.status && body.status !== "ALL") q = q.eq("status", body.status);
  if (body.date_range_start) q = q.gte("entry_date", body.date_range_start);
  if (body.date_range_end) q = q.lt("entry_date", body.date_range_end);
  const query = str(body.search_query);
  if (query) {
    const esc = query.replace(/[%_,()]/g, " ");
    q = q.or(`source.ilike.%${esc}%,description.ilike.%${esc}%`);
  }
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  const { data: activeRows } = await db.from("pos_finance_categories").select(
    "id",
  )
    .eq("customer_id", ctx.customerId).is("deleted_at", null);
  const activeSet = new Set<string>((activeRows ?? []).map((c: any) => c.id));
  const entries = strip(data).filter((e: any) => activeSet.has(e.category_id));
  const cats = await categoryNames(db, ctx);
  for (const e of entries) {
    e.category_name = cats[e.category_id] ?? null;
    e.updated_at = e.updated_at ?? e.created_at;
    e.created_by = e.created_by ?? "";
  }
  if (query) {
    const needle = query.toLowerCase();
    return json({
      ok: true,
      entries: entries.filter((e: any) =>
        String(e.source ?? "").toLowerCase().includes(needle) ||
        String(e.description ?? "").toLowerCase().includes(needle) ||
        String(e.category_name ?? "").toLowerCase().includes(needle)
      ),
    });
  }
  return json({ ok: true, entries });
}

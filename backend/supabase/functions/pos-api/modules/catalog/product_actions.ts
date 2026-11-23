import type { Ctx } from "../../shared/types.ts";
import { json, str, tenantRow } from "../../shared/helpers.ts";

export async function saveProduct(db: any, ctx: Ctx, body: any) {
  const p = body.product ?? {};
  const invalid = validateProduct(p);
  if (invalid) return json({ ok: false, error: invalid }, 400);
  if (await duplicateName(db, ctx, String(p.name ?? ""), null)) {
    return json({ ok: false, error: "A saved name already exists." }, 409);
  }
  const row = tenantRow(ctx, p, {
    id: p.id ?? crypto.randomUUID(),
    is_active: 1,
    created_at: p.created_at ?? new Date().toISOString(),
  });
  const ins = await db.from("pos_products").insert(row);
  if (ins.error) {
    if (/duplicate key|unique/i.test(ins.error.message)) {
      return json({ ok: false, error: "A saved name already exists." }, 409);
    }
    throw new Error(ins.error.message);
  }
  return json({ ok: true, id: row.id });
}

export async function updateProduct(db: any, ctx: Ctx, body: any) {
  const p = body.product ?? {};
  if (!p.id) return json({ ok: false, error: "Missing product id." }, 400);
  const invalid = validateProduct(p);
  if (invalid) return json({ ok: false, error: invalid }, 400);
  if (await duplicateName(db, ctx, String(p.name ?? ""), String(p.id))) {
    return json({ ok: false, error: "A saved name already exists." }, 409);
  }
  const up = await db.from("pos_products").update({
    name: p.name,
    code: p.code ?? null,
    category: p.category ?? null,
    unit: p.unit ?? null,
    selling_price_minor_units: p.selling_price_minor_units ?? 0,
    is_active: p.is_active ?? 1,
    updated_at: new Date().toISOString(),
  }).eq("customer_id", ctx.customerId).eq("id", p.id);
  if (up.error) {
    if (/duplicate key|unique/i.test(up.error.message)) {
      return json({ ok: false, error: "A saved name already exists." }, 409);
    }
    throw new Error(up.error.message);
  }
  return json({ ok: true });
}

export async function setProductActive(
  db: any,
  ctx: Ctx,
  body: any,
  active: number,
) {
  const up = await db.from("pos_products").update({
    is_active: active,
    updated_at: new Date().toISOString(),
  }).eq("customer_id", ctx.customerId).eq("id", String(body.id ?? ""));
  if (up.error) throw new Error(up.error.message);
  return json({ ok: true });
}

function validateProduct(p: any): string | null {
  const name = String(p.name ?? "").trim();
  if (!name) return "Product name is required.";
  if (name.length > 200) return "Product name is too long.";
  const price = p.selling_price_minor_units;
  if (price != null) {
    const n = Number(price);
    if (!Number.isFinite(n) || !Number.isInteger(n) || n < 0) {
      return "Selling price must be a non-negative whole number.";
    }
  }
  return null;
}

async function duplicateName(
  db: any,
  ctx: Ctx,
  name: string,
  excludeId: string | null,
): Promise<boolean> {
  const trimmed = name.trim().toLowerCase().replace(/[%_]/g, "");
  if (!trimmed) return false;
  let q = db.from("pos_products").select("id")
    .eq("customer_id", ctx.customerId).eq("is_active", 1).ilike(
      "name",
      trimmed,
    );
  if (excludeId) q = q.neq("id", excludeId);
  const { data, error } = await q.maybeSingle();
  if (error) throw new Error(`duplicate name check: ${error.message}`);
  return !!data;
}

import type { Ctx } from "../../shared/types.ts";
import { json, str, strip, audit } from "../../shared/helpers.ts";

// Inventory foundation: stores and per-store product stock. Mirrors the
// native InventoryRepository contract — same validation, same rules, and
// the product+opening-stock write goes through one RPC so it is atomic.

export async function listStores(db: any, ctx: Ctx, _body: any) {
  const { data, error } = await db.from("stores").select("*")
    .eq("customer_id", ctx.customerId).is("deleted_at", null)
    .order("name", { ascending: true });
  if (error) throw new Error(error.message);
  return json({ ok: true, stores: strip(data) });
}

export async function createStore(db: any, ctx: Ctx, body: any) {
  const name = str(body.name);
  if (!name) return json({ ok: false, error: "A store name is required." }, 400);
  const dup = await db.from("stores").select("id")
    .eq("customer_id", ctx.customerId).is("deleted_at", null)
    .ilike("name", name).limit(1).maybeSingle();
  if (dup.error) throw new Error(dup.error.message);
  if (dup.data) {
    return json({ ok: false, error: `A store named "${name}" already exists.` }, 409);
  }
  const row = {
    id: crypto.randomUUID(),
    customer_id: ctx.customerId,
    name,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  const ins = await db.from("stores").insert(row);
  if (ins.error) {
    if (/duplicate key|unique/i.test(ins.error.message)) {
      return json({ ok: false, error: `A store named "${name}" already exists.` }, 409);
    }
    throw new Error(ins.error.message);
  }
  await audit(db, ctx.customerId, ctx.userId, "STORE_CREATED", `Store "${name}" created.`);
  return json({ ok: true, id: row.id });
}

export async function deleteStore(db: any, ctx: Ctx, body: any) {
  const id = str(body.id);
  if (!id) return json({ ok: false, error: "Missing store id." }, 400);
  const stocked = await db.from("store_inventory").select("id", { count: "exact", head: true })
    .eq("customer_id", ctx.customerId).eq("store_id", id).is("deleted_at", null);
  if (stocked.error) throw new Error(stocked.error.message);
  if ((stocked.count ?? 0) > 0) {
    return json({
      ok: false,
      error: `This store still has ${stocked.count} product(s) in stock. Remove its inventory before deleting it.`,
    }, 409);
  }
  const now = new Date().toISOString();
  const up = await db.from("stores")
    .update({ deleted_at: now, updated_at: now })
    .eq("customer_id", ctx.customerId).eq("id", id).is("deleted_at", null);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, "STORE_DELETED", `Store ${id} deleted.`);
  return json({ ok: true });
}

export async function listInventory(db: any, ctx: Ctx, body: any) {
  const storeId = str(body.store_id) || null;
  // Stock rows + store names + catalogue products, assembled here so the web
  // client renders exactly what the native join produces.
  let sq = db.from("store_inventory").select("*")
    .eq("customer_id", ctx.customerId).is("deleted_at", null);
  if (storeId) sq = sq.eq("store_id", storeId);
  const { data: stock, error: sErr } = await sq;
  if (sErr) throw new Error(sErr.message);
  const rows = strip(stock ?? []);
  if (!rows.length) return json({ ok: true, items: [] });

  const storeIds = [...new Set(rows.map((r: any) => r.store_id))];
  const productIds = [...new Set(rows.map((r: any) => r.product_id))];
  const [{ data: stores, error: stErr }, { data: products, error: pErr }] =
    await Promise.all([
      db.from("stores").select("id, name").eq("customer_id", ctx.customerId)
        .is("deleted_at", null).in("id", storeIds),
      db.from("pos_products").select("*").eq("customer_id", ctx.customerId)
        .eq("is_active", 1).in("id", productIds),
    ]);
  if (stErr) throw new Error(stErr.message);
  if (pErr) throw new Error(pErr.message);

  const storeName = new Map((stores ?? []).map((s: any) => [s.id, s.name]));
  const productById = new Map((products ?? []).map((p: any) => [p.id, p]));
  const stocksByProduct = new Map<string, any[]>();
  for (const r of rows) {
    if (!productById.has(r.product_id)) continue;
    const list = stocksByProduct.get(r.product_id) ?? [];
    list.push({
      store_id: r.store_id,
      store_name: storeName.get(r.store_id) ?? "",
      on_hand_milliunits: r.on_hand_milliunits,
      reorder_milliunits: r.reorder_milliunits,
    });
    stocksByProduct.set(r.product_id, list);
  }
  const items = [...stocksByProduct.entries()].map(([pid, stocks]) => ({
    product: productById.get(pid),
    stocks,
  })).sort((a, b) =>
    String(a.product.name).toLowerCase().localeCompare(
      String(b.product.name).toLowerCase()));
  return json({ ok: true, items });
}

export async function createInventoryProduct(db: any, ctx: Ctx, body: any) {
  const p = body.product ?? {};
  const name = str(p.name);
  if (!name) return json({ ok: false, error: "A product name is required." }, 400);
  if (!str(p.unit)) return json({ ok: false, error: "A unit is required." }, 400);
  const sell = Number(p.selling_price_minor_units);
  const buy = Number(p.bought_price_minor_units ?? 0);
  if (!Number.isInteger(sell) || sell < 0 || !Number.isInteger(buy) || buy < 0) {
    return json({ ok: false, error: "Prices must be non-negative whole numbers." }, 400);
  }
  const onHand = Number(body.on_hand_milliunits);
  const reorder = Number(body.reorder_milliunits);
  if (!Number.isInteger(onHand) || onHand < 0 ||
      !Number.isInteger(reorder) || reorder < 0) {
    return json({ ok: false, error: "Quantities must be non-negative whole numbers." }, 400);
  }
  const storeId = str(body.store_id);
  if (!storeId) return json({ ok: false, error: "A store is required." }, 400);

  const { data, error } = await db.rpc("pos_create_inventory_product", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_product: {
      id: str(p.id) || undefined,
      name,
      code: str(p.code) || undefined,
      category: str(p.category) || undefined,
      unit: str(p.unit),
      selling_price_minor_units: sell,
      bought_price_minor_units: buy,
      image_data: str(p.image_data) || undefined,
    },
    p_store_id: storeId,
    p_on_hand: onHand,
    p_reorder: reorder,
  });
  if (error) {
    const msg = String(error.message ?? "");
    if (/already exists|required|negative|does not exist/i.test(msg)) {
      return json({ ok: false, error: msg }, 409);
    }
    throw new Error(msg || "Could not create the product.");
  }
  await audit(db, ctx.customerId, ctx.userId, "PRODUCT_CREATED",
    `Product "${name}" created with opening stock.`);
  return json({ ok: true, ...(data ?? {}) });
}

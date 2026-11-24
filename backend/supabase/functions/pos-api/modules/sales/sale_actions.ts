import type { Ctx } from "../../shared/types.ts";
import {
  audit,
  demoUserIds,
  excludeDemoRows,
  hydrateItems,
  json,
  MAX_PAGE,
  pageLimit,
  pendingSaleIds,
  rpcFailure,
  str,
  strip,
  usernamesById,
} from "../../shared/helpers.ts";

export { shopDay } from "../../shared/helpers.ts";

export async function insertSale(db: any, ctx: Ctx, body: any) {
  const sale = body.sale ?? {};
  const items = Array.isArray(body.items) ? body.items : [];
  if (items.length === 0) {
    return json({ ok: false, error: "Incomplete sale." }, 400);
  }
  const receipt = str(sale.receipt_number);
  if (!receipt) {
    return json({ ok: false, error: "Sale requires a receipt number." }, 400);
  }
  const payment = str(sale.payment_method).toUpperCase();
  if (!["CASH", "BANK", "LOAN"].includes(payment)) {
    return json({ ok: false, error: "Invalid payment method." }, 400);
  }
  const { data, error } = await db.rpc("pos_create_sale", {
    p_customer: ctx.customerId,
    p_cashier: ctx.userId,
    p_device: str(sale.device_id) || ctx.deviceId || "",
    p_shift_id: str(sale.shift_id),
    p_receipt: receipt,
    p_items: items,
    p_payment: payment,
    p_discount: Number(sale.discount_minor_units ?? 0),
    p_amount_paid: Number(sale.amount_paid_minor_units ?? 0),
    p_customer_name: sale.customer_name == null
      ? null
      : str(sale.customer_name) || null,
    p_sale_id: str(sale.id) || null,
  });
  if (error) return rpcFailure(error.message);
  const res = typeof data === "string" ? JSON.parse(data) : (data ?? {});
  return json({
    ok: true,
    id: res.id,
    receipt_number: res.receipt_number,
    subtotal_minor_units: res.subtotal_minor_units,
    total_minor_units: res.total_minor_units,
    duplicate: res.duplicate === true,
  });
}

export async function searchSales(db: any, ctx: Ctx, body: any) {
  let q = db.from("sales").select("*")
    .eq("customer_id", ctx.customerId).order("created_at", {
      ascending: false,
    });
  if (body.status && body.status !== "ALL") q = q.eq("status", body.status);
  if (body.period_start) q = q.gte("created_at", body.period_start);
  if (body.period_end) q = q.lt("created_at", body.period_end);
  const query = str(body.search_query);
  let matchedIdsHitCap = false;
  if (query) {
    const esc = query.replace(/[%_,()]/g, " ");
    const { data: itemRows, error: itemErr } = await db.from("sale_items")
      .select("sale_id")
      .eq("customer_id", ctx.customerId)
      .or(
        `product_name_snapshot.ilike.%${esc}%,quantity_text.ilike.%${esc}%,notes.ilike.%${esc}%`,
      )
      .limit(1000);
    if (itemErr) throw new Error(itemErr.message);
    const { data: userRows, error: userErr } = await db.from("pos_users")
      .select("id")
      .eq("customer_id", ctx.customerId).ilike("username", `%${esc}%`)
      .limit(1000);
    if (userErr) throw new Error(userErr.message);
    const userIds = strip(userRows).map((r: any) => r.id);
    let cashierSaleIds: string[] = [];
    if (userIds.length) {
      const { data: cs, error: csErr } = await db.from("sales").select("id")
        .eq("customer_id", ctx.customerId).in("cashier_id", userIds);
      if (csErr) throw new Error(csErr.message);
      cashierSaleIds = strip(cs).map((r: any) => r.id);
    }
    const matchedIds = Array.from(
      new Set<string>([
        ...strip(itemRows).map((r: any) => r.sale_id),
        ...cashierSaleIds,
      ]),
    );
    const orParts = [
      `customer_name.ilike.%${esc}%`,
      `void_reason.ilike.%${esc}%`,
    ];
    if (matchedIds.length) {
      const CAPPED = matchedIds.slice(0, 200);
      orParts.push(`id.in.(${CAPPED.map((id) => `"${id}"`).join(",")})`);
    }
    q = q.or(orParts.join(","));
    matchedIdsHitCap = (itemRows?.length ?? 0) >= 1000 ||
      (userRows?.length ?? 0) >= 1000;
  }
  q = excludeDemoRows(q, await demoUserIds(db, ctx), "cashier_id");
  const limit = pageLimit(body);
  q = q.limit(limit);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  const sales = strip(data);
  await hydrateItems(db, ctx, sales);
  const names = await usernamesById(
    db,
    ctx,
    sales.map((s: any) => s.cashier_id),
  );
  const pending = await pendingSaleIds(db, ctx, sales.map((s: any) => s.id));
  for (const s of sales) {
    s.cashier_name = names[s.cashier_id] ?? null;
    s.has_pending_void_request = pending.has(s.id);
  }
  return json({
    ok: true,
    sales,
    truncated: sales.length >= limit || matchedIdsHitCap,
  });
}

export async function voidSale(db: any, ctx: Ctx, body: any) {
  const reason = str(body.reason);
  if (!reason || reason.length > 240) {
    return json({ ok: false, error: "Void reason required." }, 400);
  }
  const saleId = String(body.sale_id ?? "");
  if (!saleId) return json({ ok: false, error: "Sale not found." }, 404);
  const { error } = await db.rpc("pos_void_sale", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_sale_id: saleId,
    p_reason: reason,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

export async function requestVoid(db: any, ctx: Ctx, body: any) {
  const reason = str(body.reason);
  if (!reason || reason.length > 240) {
    return json({ ok: false, error: "Void reason required." }, 400);
  }
  const { data: sale, error: saleErr } = await db.from("sales").select("status")
    .eq("customer_id", ctx.customerId).eq("id", String(body.sale_id ?? ""))
    .maybeSingle();
  if (saleErr) throw new Error(saleErr.message);
  if (!sale || sale.status !== "COMPLETED") {
    return json({ ok: false, error: "Sale not voidable." }, 400);
  }
  const { data: existingReq } = await db.from("void_requests").select("id")
    .eq("customer_id", ctx.customerId).eq("sale_id", String(body.sale_id ?? ""))
    .eq("status", "PENDING").maybeSingle();
  if (existingReq) {
    return json({
      ok: false,
      error: "A void request is already pending for this sale.",
    }, 409);
  }
  const id = crypto.randomUUID();
  const ins = await db.from("void_requests").insert({
    id,
    customer_id: ctx.customerId,
    sale_id: body.sale_id,
    requested_by: ctx.userId,
    reason,
    status: "PENDING",
    created_at: new Date().toISOString(),
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "VOID_REQUESTED",
    `Void requested for ${body.sale_id}.`,
  );
  return json({ ok: true, id });
}

export async function listVoidRequests(db: any, ctx: Ctx, body: any) {
  const limit = pageLimit(body, MAX_PAGE);
  let q = db.from("void_requests").select("*")
    .eq("customer_id", ctx.customerId).eq("status", "PENDING")
    .order("created_at", { ascending: false });
  q = excludeDemoRows(q, await demoUserIds(db, ctx), "requested_by");
  const { data, error } = await q.limit(limit);
  if (error) throw new Error(error.message);
  const reqs = strip(data);
  const names = await usernamesById(
    db,
    ctx,
    reqs.map((r: any) => r.requested_by),
  );
  for (const r of reqs) r.requester_name = names[r.requested_by] ?? null;
  const saleIds = [...new Set(reqs.map((r: any) => r.sale_id))];
  if (saleIds.length) {
    const { data: sales } = await db.from("sales").select("*")
      .eq("customer_id", ctx.customerId).in("id", saleIds);
    const hydrated = strip(sales);
    await hydrateItems(db, ctx, hydrated);
    const cashierNames = await usernamesById(
      db,
      ctx,
      hydrated.map((s: any) => s.cashier_id),
    );
    for (const s of hydrated) {
      s.cashier_name = cashierNames[s.cashier_id] ?? null;
    }
    const byId: Record<string, any> = {};
    for (const s of hydrated) byId[s.id] = s;
    for (const r of reqs) r.sale = byId[r.sale_id] ?? null;
  }
  return json({ ok: true, void_requests: reqs });
}

export async function decideVoid(
  db: any,
  ctx: Ctx,
  body: any,
  decision: string,
) {
  const requestId = String(body.request_id ?? "");
  if (!requestId) return json({ ok: false, error: "Request not found." }, 404);
  const fn = decision === "APPROVED" ? "pos_approve_void" : "pos_reject_void";
  const { error } = await db.rpc(fn, {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_request_id: requestId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

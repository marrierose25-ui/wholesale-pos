import type { Ctx } from "../../shared/types.ts";
import { audit, json, rpcFailure, str, strip } from "../../shared/helpers.ts";

export async function financeCreateCategory(db: any, ctx: Ctx, body: any) {
  const name = str(body.name);
  if (!name) return json({ ok: false, error: "A name is required." }, 400);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const { data, error } = await db.from("pos_finance_categories").insert({
    id,
    customer_id: ctx.customerId,
    name,
    created_at: now,
    updated_at: now,
  }).select().single();
  if (error) throw new Error(error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "FINANCE_CATEGORY_CREATED",
    `Person "${name}".`,
  );
  return json({ ok: true, category: strip([data])[0] });
}

export async function financeRenameCategory(db: any, ctx: Ctx, body: any) {
  const newName = str(body.new_name);
  if (!newName) return json({ ok: false, error: "A name is required." }, 400);
  const id = String(body.category_id ?? "");
  const up = await db.from("pos_finance_categories").update({
    name: newName,
    updated_at: new Date().toISOString(),
  })
    .eq("customer_id", ctx.customerId).eq("id", id).is("deleted_at", null)
    .select("id, name");
  if (up.error) throw new Error(up.error.message);
  if (!Array.isArray(up.data) || up.data.length !== 1) {
    return json({ ok: false, error: "Person not found." }, 404);
  }
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "FINANCE_CATEGORY_RENAMED",
    `Person "${up.data[0].name}" renamed.`,
  );
  return json({ ok: true });
}

export async function financeDeleteCategory(db: any, ctx: Ctx, body: any) {
  const id = String(body.category_id ?? "");
  const { data: existing } = await db.from("pos_finance_categories").select(
    "id, name, deleted_at",
  )
    .eq("customer_id", ctx.customerId).eq("id", id).maybeSingle();
  if (!existing) return json({ ok: false, error: "Person not found." }, 404);
  if (existing.deleted_at) {
    return json(
      { ok: false, error: "Person is already in the recycle bin." },
      409,
    );
  }
  const now = new Date().toISOString();
  const up = await db.from("pos_finance_categories").update({
    deleted_at: now,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("id", id);
  if (up.error) throw new Error(up.error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "FINANCE_CATEGORY_DELETED",
    `Person "${existing.name}" to recycle bin.`,
  );
  return json({ ok: true });
}

export async function financeRestoreCategory(db: any, ctx: Ctx, body: any) {
  const id = String(body.category_id ?? "");
  const { data: existing } = await db.from("pos_finance_categories").select(
    "id, name, deleted_at",
  )
    .eq("customer_id", ctx.customerId).eq("id", id).maybeSingle();
  if (!existing) return json({ ok: false, error: "Person not found." }, 404);
  if (!existing.deleted_at) {
    return json({ ok: false, error: "Person is not in the recycle bin." }, 409);
  }
  const now = new Date().toISOString();
  const up = await db.from("pos_finance_categories").update({
    deleted_at: null,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("id", id);
  if (up.error) throw new Error(up.error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "FINANCE_CATEGORY_RESTORED",
    `Person "${existing.name}" restored.`,
  );
  return json({ ok: true });
}

export async function financePermanentlyDeleteCategory(
  db: any,
  ctx: Ctx,
  body: any,
) {
  const id = String(body.category_id ?? "");
  if (!id) return json({ ok: false, error: "Person not found." }, 404);
  const { error } = await db.rpc("pos_delete_finance_category", {
    p_customer: ctx.customerId,
    p_id: id,
    p_user: ctx.userId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

export async function financeAddEntry(db: any, ctx: Ctx, body: any) {
  const amount = Number(body.amount_minor_units ?? 0);
  if (amount <= 0) {
    return json({ ok: false, error: "Amount must be positive." }, 400);
  }
  const source = str(body.source);
  if (!source) return json({ ok: false, error: "A source is required." }, 400);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const description = body.description == null
    ? null
    : str(body.description) || null;
  const paymentMethod = body.payment_method == null
    ? null
    : str(body.payment_method).toUpperCase() || null;
  const categoryId = String(body.category_id ?? "");
  if (!categoryId) {
    return json({ ok: false, error: "Category is required." }, 400);
  }
  const { data: cat, error: catErr } = await db.from("pos_finance_categories")
    .select("id").eq("customer_id", ctx.customerId).eq("id", categoryId)
    .is("deleted_at", null).maybeSingle();
  if (catErr) throw new Error(catErr.message);
  if (!cat) {
    return json({ ok: false, error: "Person not found." }, 404);
  }
  const { data, error } = await db.from("pos_finance_entries").insert({
    id,
    customer_id: ctx.customerId,
    category_id: categoryId,
    source: str(body.source),
    amount_minor_units: amount,
    description,
    status: "PENDING",
    payment_method: paymentMethod,
    entry_date: body.entry_date ?? now,
    created_at: now,
    created_by: ctx.userId,
    updated_at: now,
  }).select().single();
  if (error) throw new Error(error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "FINANCE_ENTRY_ADDED",
    `${body.source} ${amount}.`,
  );
  return json({
    ok: true,
    entry: await withCategoryName(db, ctx, strip([data])[0]),
  });
}

export async function financeUpdateEntry(db: any, ctx: Ctx, body: any) {
  const amount = Number(body.amount_minor_units ?? 0);
  if (amount <= 0) {
    return json({ ok: false, error: "Amount must be positive." }, 400);
  }
  const description = body.description == null
    ? null
    : str(body.description) || null;
  const paymentMethod = body.payment_method == null
    ? null
    : str(body.payment_method).toUpperCase() || null;
  const up = await db.from("pos_finance_entries").update({
    source: str(body.source),
    amount_minor_units: amount,
    description,
    payment_method: paymentMethod,
    entry_date: body.entry_date ?? new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("customer_id", ctx.customerId).eq("id", String(body.entry_id ?? "")).eq(
    "status",
    "PENDING",
  ).select("id");
  if (up.error) throw new Error(up.error.message);
  if (!up.data || up.data.length === 0) {
    return json(
      { ok: false, error: "Entry not found or already completed." },
      409,
    );
  }
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "FINANCE_ENTRY_UPDATED",
    `Entry ${body.entry_id} edited.`,
  );
  return json({ ok: true });
}

export async function financeMarkCompleted(db: any, ctx: Ctx, body: any) {
  const entryId = String(body.entry_id ?? "");
  if (!entryId) return json({ ok: false, error: "Entry is not pending." }, 409);
  const { error } = await db.rpc("pos_complete_finance", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_entry_id: entryId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

export async function financeDeleteEntry(db: any, ctx: Ctx, body: any) {
  const entryId = String(body.entry_id ?? "");
  if (!entryId) return json({ ok: false, error: "Entry not found." }, 404);
  const { error } = await db.rpc("pos_delete_finance_entry", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_entry_id: entryId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

async function withCategoryName(db: any, ctx: Ctx, entry: any): Promise<any> {
  const cats = await categoryNames(db, ctx);
  return {
    ...entry,
    category_name: cats[entry.category_id] ?? null,
    updated_at: entry.updated_at ?? entry.created_at,
    created_by: entry.created_by ?? "",
  };
}

export async function categoryNames(
  db: any,
  ctx: Ctx,
): Promise<Record<string, string>> {
  const { data } = await db.from("pos_finance_categories").select("id, name")
    .eq("customer_id", ctx.customerId);
  const map: Record<string, string> = {};
  for (const c of data ?? []) map[c.id] = c.name;
  return map;
}

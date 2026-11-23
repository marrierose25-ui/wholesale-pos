import type { Ctx } from "../../shared/types.ts";
import { audit, json, pageLimit, str, strip } from "../../shared/helpers.ts";

// Status re-derived from the full item set, mirroring the native
// SqflitePicklistRepository: all lines fulfilled -> COMPLETED, none taken ->
// PENDING, anything in between -> PARTIAL.
function derivePicklistStatus(items: any[]): string {
  const active = items.filter((i) => !i.deleted_at);
  if (active.length === 0) return "PENDING";
  const takenOf = (i: any) => Number(i.taken_qty ?? 0);
  const requestedOf = (i: any) => Number(i.requested_qty ?? 0);
  if (active.every((i) => takenOf(i) >= requestedOf(i))) return "COMPLETED";
  if (active.every((i) => takenOf(i) <= 0)) return "PENDING";
  return "PARTIAL";
}

// Picklist money columns are Postgres `int` (32-bit), so a price or line total
// above this would fail the write instead of landing as a value.
const PICKLIST_MAX_MINOR_UNITS = 2147483647;

export async function listPicklists(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  let q = db.from("picklists").select("*")
    .eq("customer_id", ctx.customerId)
    .is("deleted_at", null)
    .order("created_at", { ascending: false })
    .limit(pageLimit(body));
  if (body.status && body.status !== "ALL") q = q.eq("status", body.status);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return json({ ok: true, picklists: strip(data) });
}

export async function getPicklistItems(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const picklistId = String(body.picklist_id ?? "");
  if (!picklistId) {
    return json({ ok: false, error: "Picklist not found." }, 404);
  }
  const { data: header, error: headErr } = await db.from("picklists")
    .select("id").eq("customer_id", ctx.customerId).eq("id", picklistId)
    .is("deleted_at", null).maybeSingle();
  if (headErr) throw new Error(headErr.message);
  if (!header) return json({ ok: false, error: "Picklist not found." }, 404);
  // Stable order (product name) so the fulfillment screen matches native.
  // A soft-deleted line is never returned; the row is kept only so the
  // tombstone can sync to every device.
  const { data, error } = await db.from("picklist_items").select("*")
    .eq("customer_id", ctx.customerId).eq("picklist_id", picklistId)
    .is("deleted_at", null)
    .order("product_name");
  if (error) throw new Error(error.message);
  const items = strip(data);
  // Price columns are only dropped for a context that is not allowed money.
  // Both warehouse ticks (and the owner) now pass that gate, so fill workers
  // receive the same line prices as the shop side.
  if (!ctx.canSeePicklistMoney) {
    for (const item of items) {
      delete item.unit_price_minor_units;
      delete item.line_total_minor_units;
    }
  }
  return json({ ok: true, items });
}

export async function createPicklist(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const header = body.picklist ?? {};
  const items = Array.isArray(body.items) ? body.items : [];
  const id = str(header.id);
  const customerName = str(header.customer_name);
  if (!id) return json({ ok: false, error: "Missing picklist id." }, 400);
  if (!customerName) {
    return json({ ok: false, error: "A customer name is required." }, 400);
  }
  if (items.length === 0) {
    return json(
      { ok: false, error: "A picklist needs at least one item." },
      400,
    );
  }

  const now = new Date().toISOString();
  // Ownership + created_by are server-authoritative; the body's created_by /
  // customer_id are ignored so a crafted call cannot mis-attribute the header.
  const headerRow = {
    id,
    customer_id: ctx.customerId,
    customer_name: customerName,
    // A brand-new picklist always starts unfulfilled; status is re-derived on
    // update, so any client-supplied status is ignored here.
    status: "PENDING",
    created_by: ctx.userId,
    created_at: now,
    updated_at: now,
  };
  const { error: headErr } = await db.from("picklists").insert(headerRow);
  if (headErr) {
    if (/duplicate key|unique/i.test(headErr.message)) {
      return json({
        ok: false,
        error: "A picklist with that id already exists.",
      }, 409);
    }
    throw new Error(headErr.message);
  }

  // Validate + normalise every line before the one atomic batch insert. The
  // picklist_id is forced to this header so a stray child id can never point a
  // line at another picklist.
  const itemRows: any[] = [];
  for (const raw of items) {
    const productName = str(raw.product_name);
    const requested = Number(raw.requested_qty ?? 0);
    if (!productName) {
      await db.from("picklists").delete().eq("customer_id", ctx.customerId).eq(
        "id",
        id,
      );
      return json(
        { ok: false, error: "Every item needs a product name." },
        400,
      );
    }
    if (!Number.isInteger(requested) || requested <= 0) {
      await db.from("picklists").delete().eq("customer_id", ctx.customerId).eq(
        "id",
        id,
      );
      return json({
        ok: false,
        error: "Requested quantity must be a positive whole number.",
      }, 400);
    }
    // Pricing is a display hint only (never a ledger write). The unit price is
    // taken in minor units; the line total is recomputed server-side as
    // price * requested so a crafted body can't post a value that disagrees
    // with its own quantity.
    const unit = str(raw.unit) || null;
    const unitPrice = Math.max(
      0,
      Number.isInteger(Number(raw.unit_price_minor_units))
        ? Number(raw.unit_price_minor_units)
        : 0,
    );
    // A value the int column cannot hold (or a line total that would overflow
    // it) is refused up front instead of failing the batch insert with a raw
    // database error.
    if (
      unitPrice > PICKLIST_MAX_MINOR_UNITS ||
      (unitPrice > 0 &&
        requested > Math.floor(PICKLIST_MAX_MINOR_UNITS / unitPrice))
    ) {
      await db.from("picklists").delete().eq("customer_id", ctx.customerId).eq(
        "id",
        id,
      );
      return json(
        { ok: false, error: "Price is too large for that quantity." },
        400,
      );
    }
    const rawTaken = Number(raw.taken_qty ?? 0);
    const takenQty = Math.min(
      Math.max(Number.isInteger(rawTaken) ? rawTaken : 0, 0),
      requested,
    );
    itemRows.push({
      id: str(raw.id) || crypto.randomUUID(),
      customer_id: ctx.customerId,
      picklist_id: id,
      product_name: productName,
      requested_qty: requested,
      taken_qty: takenQty,
      unit,
      unit_price_minor_units: unitPrice,
      line_total_minor_units: unitPrice * requested,
      updated_at: now,
    });
  }
  // One insert of the whole array is a single PostgREST statement (all rows or
  // none). If it still fails, the header is removed so no orphan is left behind
  // — the closest we get to a transaction without a dedicated RPC.
  const { error: itemsErr } = await db.from("picklist_items").insert(itemRows);
  if (itemsErr) {
    await db.from("picklists").delete().eq("customer_id", ctx.customerId).eq(
      "id",
      id,
    );
    throw new Error(itemsErr.message);
  }
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PICKLIST_CREATED",
    `Picklist for "${customerName}" (${itemRows.length} items).`,
  );
  return json({ ok: true, id });
}

export async function updatePicklistItems(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const picklistId = String(body.picklist_id ?? "");
  const updates = Array.isArray(body.items) ? body.items : [];
  if (!picklistId) {
    return json({ ok: false, error: "Picklist not found." }, 404);
  }

  const { data: header, error: headErr } = await db.from("picklists")
    .select("id, status").eq("customer_id", ctx.customerId).eq("id", picklistId)
    .is("deleted_at", null).maybeSingle();
  if (headErr) throw new Error(headErr.message);
  if (!header) return json({ ok: false, error: "Picklist not found." }, 404);
  if (header.status === "COMPLETED") {
    return json({
      ok: false,
      error: "A completed picklist can no longer be edited.",
    }, 409);
  }

  const now = new Date().toISOString();
  for (const raw of updates) {
    const itemId = str(raw.id);
    if (!itemId) continue;
    const taken = Number(raw.taken_qty ?? 0);
    if (!Number.isInteger(taken) || taken < 0) {
      return json({
        ok: false,
        error: "Taken quantity must be a non-negative whole number.",
      }, 400);
    }
    // Scoped by tenant AND parent picklist so an id from another list/tenant is
    // a no-op rather than a cross-list write. A tombstoned line is skipped.
    const up = await db.from("picklist_items").update({
      taken_qty: taken,
      updated_at: now,
    })
      .eq("customer_id", ctx.customerId).eq("picklist_id", picklistId).eq(
        "id",
        itemId,
      )
      .is("deleted_at", null);
    if (up.error) throw new Error(up.error.message);
  }

  // Re-read the whole active line set (not just the edited subset) to re-derive
  // status, exactly like the native repository's progress pass.
  const { data: itemRows, error: itemsErr } = await db.from("picklist_items")
    .select("requested_qty, taken_qty, deleted_at").eq(
      "customer_id",
      ctx.customerId,
    )
    .eq("picklist_id", picklistId).is("deleted_at", null);
  if (itemsErr) throw new Error(itemsErr.message);
  const status = derivePicklistStatus(itemRows ?? []);

  const upHeader = await db.from("picklists").update({
    status,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("id", picklistId);
  if (upHeader.error) throw new Error(upHeader.error.message);

  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PICKLIST_UPDATED",
    `Picklist ${picklistId} progress saved (status ${status}).`,
  );
  return json({ ok: true, status });
}

export async function getCustomers(
  db: any,
  ctx: Ctx,
  _body: any,
): Promise<Response> {
  const { data, error } = await db.from("picklist_customers").select("*")
    .eq("customer_id", ctx.customerId)
    .order("name")
    .limit(pageLimit(_body));
  if (error) throw new Error(error.message);
  return json({ ok: true, customers: strip(data) });
}

export async function addCustomer(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const cust = body.customer ?? {};
  const name = str(cust.name);
  if (!name) {
    return json({ ok: false, error: "A customer name is required." }, 400);
  }
  const phone = str(cust.phone) || null;
  const id = str(cust.id) || crypto.randomUUID();
  const now = new Date().toISOString();
  // Ownership is server-authoritative; a client-supplied customer_id is dropped.
  const { error } = await db.from("picklist_customers").insert({
    id,
    customer_id: ctx.customerId,
    name,
    phone,
    created_at: now,
  });
  if (error) {
    if (/duplicate key|unique/i.test(error.message)) {
      return json({ ok: false, error: "That customer already exists." }, 409);
    }
    throw new Error(error.message);
  }
  return json({ ok: true, id });
}

// One-tap fulfillment: set a line's taken qty to its requested qty (or 0), then
// re-derive the parent status. Mirrors the native toggleItemTaken transaction
// and its COMPLETED freeze, so the PWA checkbox behaves exactly like the till.
export async function togglePicklistItem(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const picklistId = str(body.picklist_id);
  const itemId = str(body.item_id);
  const isTaken = body.is_taken === true;
  if (!picklistId || !itemId) {
    return json({ ok: false, error: "Picklist not found." }, 404);
  }

  const { data: header, error: headErr } = await db.from("picklists")
    .select("id, status").eq("customer_id", ctx.customerId).eq("id", picklistId)
    .is("deleted_at", null).maybeSingle();
  if (headErr) throw new Error(headErr.message);
  if (!header) return json({ ok: false, error: "Picklist not found." }, 404);
  if (header.status === "COMPLETED") {
    return json({
      ok: false,
      error: "A completed picklist can no longer be edited.",
    }, 409);
  }

  const { data: item, error: itemErr } = await db.from("picklist_items")
    .select("id, requested_qty").eq("customer_id", ctx.customerId)
    .eq("picklist_id", picklistId).eq("id", itemId).is("deleted_at", null)
    .maybeSingle();
  if (itemErr) throw new Error(itemErr.message);
  if (!item) return json({ ok: false, error: "Item not found." }, 404);

  const now = new Date().toISOString();
  const taken = isTaken ? Number(item.requested_qty ?? 0) : 0;
  const up = await db.from("picklist_items").update({
    taken_qty: taken,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("picklist_id", picklistId).eq(
      "id",
      itemId,
    )
    .is("deleted_at", null);
  if (up.error) throw new Error(up.error.message);

  const { data: itemRows, error: itemsErr } = await db.from("picklist_items")
    .select("requested_qty, taken_qty, deleted_at").eq(
      "customer_id",
      ctx.customerId,
    )
    .eq("picklist_id", picklistId).is("deleted_at", null);
  if (itemsErr) throw new Error(itemsErr.message);
  const status = derivePicklistStatus(itemRows ?? []);

  const upHeader = await db.from("picklists").update({
    status,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("id", picklistId);
  if (upHeader.error) throw new Error(upHeader.error.message);

  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PICKLIST_UPDATED",
    `Picklist ${picklistId} item ${itemId} toggled (status ${status}).`,
  );
  return json({ ok: true, status });
}

// Corrects one line (name, requested quantity, unit, unit price). Price is a
// display hint, so the line total is recomputed here from price * requested
// instead of trusting the body. Mirrors the native updatePicklistItem.
export async function updatePicklistItem(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const picklistId = str(body.picklist_id);
  const itemId = str(body.item_id);
  if (!picklistId || !itemId) {
    return json({ ok: false, error: "Item not found." }, 404);
  }

  const { data: header, error: headErr } = await db.from("picklists")
    .select("id, status").eq("customer_id", ctx.customerId).eq("id", picklistId)
    .is("deleted_at", null).maybeSingle();
  if (headErr) throw new Error(headErr.message);
  if (!header) return json({ ok: false, error: "Picklist not found." }, 404);
  if (header.status === "COMPLETED") {
    return json({
      ok: false,
      error: "A completed picklist can no longer be edited.",
    }, 409);
  }

  // The line must still exist and be active: an UPDATE that matches nothing
  // would otherwise report success and then re-derive the header from a set
  // that never contained this id.
  const { data: existing, error: itemErr } = await db.from("picklist_items")
    .select("id, taken_qty").eq("customer_id", ctx.customerId)
    .eq("picklist_id", picklistId).eq("id", itemId)
    .is("deleted_at", null).maybeSingle();
  if (itemErr) throw new Error(itemErr.message);
  if (!existing) return json({ ok: false, error: "Item not found." }, 404);

  const productName = str(body.product_name);
  const requested = Number(body.requested_qty ?? 0);
  if (!productName) {
    return json({ ok: false, error: "Every item needs a product name." }, 400);
  }
  if (!Number.isInteger(requested) || requested <= 0) {
    return json({
      ok: false,
      error: "Requested quantity must be a positive whole number.",
    }, 400);
  }
  const unit = str(body.unit) || null;
  const rawPrice = Number(body.unit_price_minor_units ?? 0);
  if (!Number.isInteger(rawPrice) || rawPrice < 0) {
    return json({
      ok: false,
      error: "Price must be a whole, non-negative number of cents.",
    }, 400);
  }
  const unitPrice = rawPrice;
  // Keep the value (and the computed total) inside what the Postgres `int`
  // columns can hold, so a huge price is a clear 400 rather than a 500.
  if (
    unitPrice > PICKLIST_MAX_MINOR_UNITS ||
    (unitPrice > 0 &&
      requested > Math.floor(PICKLIST_MAX_MINOR_UNITS / unitPrice))
  ) {
    return json(
      { ok: false, error: "Price is too large for that quantity." },
      400,
    );
  }
  const lineTotal = unitPrice * requested;

  // Lowering the requested quantity must never leave the line "more taken than
  // requested": clamp the stored progress to the new ceiling.
  const storedTaken = Number(existing.taken_qty ?? 0);
  const takenQty = Math.min(
    Math.max(Number.isInteger(storedTaken) ? storedTaken : 0, 0),
    requested,
  );

  const now = new Date().toISOString();
  const up = await db.from("picklist_items").update({
    product_name: productName,
    requested_qty: requested,
    taken_qty: takenQty,
    unit,
    unit_price_minor_units: unitPrice,
    line_total_minor_units: lineTotal,
    updated_at: now,
  }).eq("customer_id", ctx.customerId).eq("picklist_id", picklistId).eq(
    "id",
    itemId,
  )
    .is("deleted_at", null).select("id");
  if (up.error) throw new Error(up.error.message);
  // Belt and braces: if the row vanished between the read and the write, fail
  // loudly instead of reporting a phantom edit.
  if (!Array.isArray(up.data) || up.data.length === 0) {
    return json({ ok: false, error: "Item not found." }, 404);
  }

  const { data: itemRows, error: itemsErr } = await db.from("picklist_items")
    .select("requested_qty, taken_qty, deleted_at").eq(
      "customer_id",
      ctx.customerId,
    )
    .eq("picklist_id", picklistId).is("deleted_at", null);
  if (itemsErr) throw new Error(itemsErr.message);
  const status = derivePicklistStatus(itemRows ?? []);

  const upHeader = await db.from("picklists").update({
    status,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("id", picklistId);
  if (upHeader.error) throw new Error(upHeader.error.message);

  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PICKLIST_UPDATED",
    `Picklist ${picklistId} item ${itemId} edited (status ${status}).`,
  );
  return json({ ok: true, status });
}

// Soft-deletes one line. When it was the last active line the header is
// tombstoned too, so the queue never shows an empty list.
export async function deletePicklistItem(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const picklistId = str(body.picklist_id);
  const itemId = str(body.item_id);
  if (!picklistId || !itemId) {
    return json({ ok: false, error: "Item not found." }, 404);
  }

  const { data: header, error: headErr } = await db.from("picklists")
    .select("id, status").eq("customer_id", ctx.customerId).eq("id", picklistId)
    .is("deleted_at", null).maybeSingle();
  if (headErr) throw new Error(headErr.message);
  if (!header) return json({ ok: false, error: "Picklist not found." }, 404);
  if (header.status === "COMPLETED") {
    return json({
      ok: false,
      error: "A completed picklist can no longer be edited.",
    }, 409);
  }

  const now = new Date().toISOString();
  const up = await db.from("picklist_items").update({
    deleted_at: now,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("picklist_id", picklistId).eq(
      "id",
      itemId,
    )
    .is("deleted_at", null).select("id");
  if (up.error) throw new Error(up.error.message);
  // Deleting an already-gone line is not a silent success: the caller may be
  // looking at a stale screen, and reporting the truth lets it refresh.
  if (!Array.isArray(up.data) || up.data.length === 0) {
    return json({ ok: false, error: "Item not found." }, 404);
  }

  const { data: remaining, error: itemsErr } = await db.from("picklist_items")
    .select("requested_qty, taken_qty, deleted_at").eq(
      "customer_id",
      ctx.customerId,
    )
    .eq("picklist_id", picklistId).is("deleted_at", null);
  if (itemsErr) throw new Error(itemsErr.message);

  if ((remaining ?? []).length === 0) {
    // Last line gone: hide the header as well so no empty list stays queued.
    const upHeader = await db.from("picklists").update({
      deleted_at: now,
      updated_at: now,
    })
      .eq("customer_id", ctx.customerId).eq("id", picklistId);
    if (upHeader.error) throw new Error(upHeader.error.message);
    await audit(
      db,
      ctx.customerId,
      ctx.userId,
      "PICKLIST_DELETED",
      `Picklist ${picklistId} item ${itemId} deleted (status DELETED).`,
    );
    return json({ ok: true, status: "DELETED" });
  }

  const status = derivePicklistStatus(remaining);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PICKLIST_UPDATED",
    `Picklist ${picklistId} item ${itemId} deleted (status ${status}).`,
  );
  return json({ ok: true, status });
}

// Soft-deletes a whole list (header + every active line) so every device's
// pull sees the tombstone and hides it.
export async function deletePicklist(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const picklistId = str(body.picklist_id);
  if (!picklistId) {
    return json({ ok: false, error: "Picklist not found." }, 404);
  }

  const { data: header, error: headErr } = await db.from("picklists")
    .select("id, status, customer_name, deleted_at").eq(
      "customer_id",
      ctx.customerId,
    )
    .eq("id", picklistId).maybeSingle();
  if (headErr) throw new Error(headErr.message);
  if (!header) return json({ ok: false, error: "Picklist not found." }, 404);

  const now = new Date().toISOString();
  if (header.deleted_at) {
    // Idempotent retry: the header was already hidden, but an earlier attempt
    // may have failed before its lines were tombstoned. Finish the cleanup so
    // no active line can outlive its list.
    const cleanup = await db.from("picklist_items").update({
      deleted_at: now,
      updated_at: now,
    })
      .eq("customer_id", ctx.customerId).eq("picklist_id", picklistId)
      .is("deleted_at", null);
    if (cleanup.error) throw new Error(cleanup.error.message);
    return json({ ok: true });
  }
  if (header.status === "COMPLETED") {
    return json({
      ok: false,
      error: "A completed picklist can no longer be edited.",
    }, 409);
  }

  // Header first: hiding the list is the critical outcome. If the line update
  // then fails, the queue is already correct and the idempotent branch above
  // finishes the cleanup on a retry.
  const upHeader = await db.from("picklists").update({
    deleted_at: now,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("id", picklistId).is(
      "deleted_at",
      null,
    );
  if (upHeader.error) throw new Error(upHeader.error.message);

  const upItems = await db.from("picklist_items").update({
    deleted_at: now,
    updated_at: now,
  })
    .eq("customer_id", ctx.customerId).eq("picklist_id", picklistId).is(
      "deleted_at",
      null,
    );
  if (upItems.error) throw new Error(upItems.error.message);

  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PICKLIST_DELETED",
    `Picklist for "${header.customer_name}" (${picklistId}) deleted.`,
  );
  return json({ ok: true });
}

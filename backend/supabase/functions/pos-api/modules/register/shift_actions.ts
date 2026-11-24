import type { Ctx } from "../../shared/types.ts";
import { OWNER } from "../../shared/auth.ts";
import {
  computeExpectedCash,
  demoUserIds,
  deSnake,
  excludeDemoRows,
  json,
  pageLimit,
  rpcFailure,
  str,
  strip,
} from "../../shared/helpers.ts";

export async function getActiveShift(db: any, ctx: Ctx) {
  const { data } = await db.from("shifts").select("*")
    .eq("customer_id", ctx.customerId).eq("status", "OPEN").limit(1)
    .maybeSingle();
  return json({ ok: true, shift: data ? deSnake(data) : null });
}

export async function ensureShift(db: any, ctx: Ctx) {
  const { data, error } = await db.rpc("pos_ensure_shift", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_device: ctx.deviceId,
  });
  if (error) throw new Error(error.message);
  const shiftId = String(data);
  const { data: row } = await db.from("shifts").select("*")
    .eq("customer_id", ctx.customerId).eq("id", shiftId).maybeSingle();
  return json({ ok: true, shift: row ? deSnake(row) : { id: shiftId } });
}

export async function registerSnapshot(db: any, ctx: Ctx, body: any) {
  const { data: shift } = await db.from("shifts").select("*")
    .eq("customer_id", ctx.customerId).eq("status", "OPEN").limit(1)
    .maybeSingle();
  if (!shift) {
    return json({
      ok: true,
      snapshot: {
        balance: 0,
        today_cash_sales: 0,
        today_bank_sales: 0,
        today_deposits: 0,
        today_withdrawals: 0,
      },
    });
  }
  const balance = await computeExpectedCash(db, ctx.customerId, shift);
  const { data: counters, error: cErr } = await db.rpc("pos_shift_counters", {
    p_customer: ctx.customerId,
    p_shift_id: shift.id,
    p_start: body.period_start ?? null,
    p_end: body.period_end ?? null,
  });
  if (cErr) throw new Error(cErr.message);
  const c = typeof counters === "string"
    ? JSON.parse(counters)
    : (counters ?? {});
  return json({
    ok: true,
    snapshot: {
      balance,
      today_cash_sales: Number(c.cash_sales ?? 0),
      today_bank_sales: Number(c.bank_sales ?? 0),
      today_deposits: Number(c.deposits ?? 0),
      today_withdrawals: Number(c.withdrawals ?? 0),
    },
  });
}

export async function shiftHistory(db: any, ctx: Ctx, body: any) {
  let q = db.from("shifts").select("*").eq("customer_id", ctx.customerId)
    .order("opened_at", { ascending: false });
  if (body.status) q = q.eq("status", body.status);
  if (body.period_start) q = q.gte("opened_at", body.period_start);
  if (body.period_end) q = q.lt("opened_at", body.period_end);
  q = excludeDemoRows(q, await demoUserIds(db, ctx), "cashier_id");
  const limit = pageLimit(body);
  const { data, error } = await q.limit(limit);
  if (error) throw new Error(error.message);
  const shifts = strip(data);
  return json({ ok: true, shifts, truncated: shifts.length >= limit });
}

export async function openShift(db: any, ctx: Ctx, body: any) {
  const opening = Number(body.opening_cash_minor_units ?? 0);
  if (!Number.isFinite(opening) || opening < 0) {
    return json({ ok: false, error: "Opening cash cannot be negative." }, 400);
  }
  const { data, error } = await db.rpc("pos_open_shift", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_device: ctx.deviceId,
    p_opening: opening,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true, id: String(data) });
}

export async function closeShift(db: any, ctx: Ctx, body: any) {
  const closing = Number(body.closing_cash_minor_units ?? 0);
  if (!Number.isFinite(closing) || closing < 0) {
    return json({ ok: false, error: "Closing cash cannot be negative." }, 400);
  }
  const shiftId = String(body.shift_id ?? "");
  if (!shiftId) {
    return json({ ok: false, error: "Shift is no longer open." }, 409);
  }
  const { data, error } = await db.rpc("pos_close_shift", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_shift_id: shiftId,
    p_closing: closing,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true, expected_cash_minor_units: Number(data) });
}

export async function shiftSummary(db: any, ctx: Ctx, body: any) {
  const { data: shift } = await db.from("shifts").select("id, status")
    .eq("customer_id", ctx.customerId).eq("id", String(body.shift_id ?? ""))
    .maybeSingle();
  if (!shift) return json({ ok: false, error: "Shift not found." }, 404);
  if (ctx.role !== OWNER && shift.status !== "OPEN") {
    return json({ ok: false, error: "Owners can review a closed shift." }, 403);
  }
  const { data, error } = await db.rpc("pos_shift_summary", {
    p_customer: ctx.customerId,
    p_shift_id: shift.id,
  });
  if (error) throw new Error(error.message);
  const s = typeof data === "string" ? JSON.parse(data) : (data ?? {});
  return json({
    ok: true,
    summary: {
      cash_sales: Number(s.cash_sales ?? 0),
      bank_sales: Number(s.bank_sales ?? 0),
      voids: Number(s.voids ?? 0),
      deposits: Number(s.deposits ?? 0),
      withdrawals: Number(s.withdrawals ?? 0),
      cash_refunds: Number(s.cash_refunds ?? 0),
      expected_cash: Number(s.expected_cash ?? 0),
    },
  });
}

export async function addCashMovement(db: any, ctx: Ctx, body: any) {
  const amount = Number(body.amount_minor_units ?? 0);
  const type = String(body.type ?? "").toUpperCase();
  if (!Number.isFinite(amount) || amount <= 0) {
    return json({ ok: false, error: "Amount must be positive." }, 400);
  }
  if (!["WITHDRAWAL", "DEPOSIT", "EXPENSE"].includes(type)) {
    return json({ ok: false, error: "Invalid movement type." }, 400);
  }
  const shiftId = String(body.shift_id ?? "");
  if (!shiftId) {
    return json({ ok: false, error: "Movement requires an open shift." }, 400);
  }
  const reason = str(body.reason);
  if (!reason) return json({ ok: false, error: "A reason is required." }, 400);
  const reason2 = reason.slice(0, 240);
  const photo = typeof body.photo === "string" && body.photo.length > 0
    ? body.photo
    : null;
  if (photo !== null && photo.length > 300_000) {
    return json({ ok: false, error: "Proof photo is too large." }, 400);
  }
  const { data, error } = await db.rpc("pos_add_cash_movement", {
    p_customer: ctx.customerId,
    p_user: ctx.userId,
    p_shift_id: shiftId,
    p_type: type,
    p_amount: amount,
    p_reason: reason2,
    p_photo: photo,
  });
  if (error) return rpcFailure(error.message);
  const res = typeof data === "string" ? JSON.parse(data) : (data ?? {});
  return json({ ok: true, id: res.id });
}

export async function listCashMovements(db: any, ctx: Ctx, body: any) {
  let q = db.from("cash_movements").select("*").eq(
    "customer_id",
    ctx.customerId,
  );
  if (body.shift_id != null && String(body.shift_id) !== "") {
    q = q.eq("shift_id", String(body.shift_id));
  }
  q = excludeDemoRows(q, await demoUserIds(db, ctx), "user_id");
  const limit = pageLimit(body);
  const { data, error } = await q.order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error(error.message);
  const rows = strip(data);
  const userIds = [...new Set(rows.map((r: any) => r.user_id).filter(Boolean))];
  let nameById: Record<string, string> = {};
  if (userIds.length > 0) {
    const { data: users } = await db.from("pos_users")
      .select("id, username").eq("customer_id", ctx.customerId).in(
        "id",
        userIds,
      );
    nameById = Object.fromEntries(
      (users ?? []).map((u: any) => [u.id, u.username]),
    );
  }
  return json({
    ok: true,
    movements: rows.map((r: any) => ({
      ...r,
      user_name: nameById[r.user_id] ?? null,
    })),
    truncated: rows.length >= limit,
  });
}

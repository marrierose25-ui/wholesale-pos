import type { Ctx } from "./types.ts";

export type AuditFn = (
  db: any,
  customerId: string,
  userId: string | null,
  action: string,
  details: string,
) => Promise<void>;

export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, apikey, x-client-info",
  "Access-Control-Max-Age": "600",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

export function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

// Best-effort client-address HINT for rate limiting (Request 2 review).
//
// Honesty note: whether Supabase's hosted edge ingress rewrites, appends to,
// or passes through X-Forwarded-For is NOT authoritatively documented.
// Supabase's own examples read the header, but no published contract
// guarantees the value reaching this function is sanitized — a client may
// control the entire header, including the rightmost entry. We therefore
// treat the parsed address as a hint for ONE extra throttle bucket, never
// as a trusted identity. The security guarantee for the public endpoints is
// carried by the durable per-code and global limits, which do not depend on
// this value at all; this bucket only adds a bound against clients that do
// not forge forwarding headers.
//
// The rightmost IP-literal entry is parsed only because that is the shape a
// proxy-appended chain would have — it is NOT evidence the platform added
// it. Missing header or a non-IP literal yields null and the caller falls
// back to shared buckets — fail-safe, never fail-open.
const IP_LITERAL = /^[0-9a-fA-F:.%[\]]{3,45}$/;
export function bestEffortSourceAddress(req: Request): string | null {
  const xff = req.headers.get("x-forwarded-for");
  if (!xff) return null;
  const parts = xff.split(",").map((s) => s.trim()).filter((s) => s.length);
  const last = parts[parts.length - 1];
  if (!last || !IP_LITERAL.test(last)) return null;
  return last;
}

export function strip(rows: any[] | null): any[] {
  return (rows ?? []).map((r) => {
    const { customer_id: _c, received_at: _r, ...rest } = r;
    return rest;
  });
}

export function deSnake(row: any): any {
  return row;
}

export function tenantRow(
  ctx: Ctx,
  src: any,
  defaults: Record<string, unknown>,
): any {
  const { customer_id: _drop, ...rest } = src;
  return { ...rest, ...defaults, customer_id: ctx.customerId };
}

export function userStamp(
  patch: Record<string, unknown>,
): Record<string, unknown> {
  return { ...patch, received_at: new Date().toISOString() };
}

export async function audit(
  db: any,
  customerId: string,
  userId: string | null,
  action: string,
  details: string,
): Promise<void> {
  // Audit must never block a write, but a dropped audit row is itself a finding,
  // so a failure is logged instead of swallowed (audit #11). Mutation RPCs write
  // their audit row inside the same transaction and are the authoritative trail.
  try {
    const { error } = await db.from("pos_audit_logs").insert({
      id: crypto.randomUUID(),
      customer_id: customerId,
      user_id: userId,
      action,
      details,
      created_at: new Date().toISOString(),
    });
    if (error) {
      console.error("AUXILIARY audit insert failed:", action, error.message);
    }
  } catch (err) {
    console.error("audit insert threw:", action, err);
  }
}

export async function hydrateItems(db: any, ctx: Ctx, sales: any[]) {
  if (!sales.length) return;
  const ids = sales.map((s) => s.id);
  const bySale: Record<string, any[]> = {};
  const CHUNK = 500;
  for (let i = 0; i < ids.length; i += CHUNK) {
    const chunk = ids.slice(i, i + CHUNK);
    const { data: items, error } = await db.from("sale_items").select("*")
      .eq("customer_id", ctx.customerId).in("sale_id", chunk);
    if (error) throw new Error(`hydrateItems: ${error.message}`);
    for (const it of strip(items)) (bySale[it.sale_id] ??= []).push(it);
  }
  for (const s of sales) s.items = bySale[s.id] ?? [];
}

export async function usernamesById(
  db: any,
  ctx: Ctx,
  ids: (string | null)[],
): Promise<Record<string, string>> {
  const unique = [...new Set(ids.filter((x): x is string => !!x))];
  if (!unique.length) return {};
  const { data } = await db.from("pos_users").select("id, username")
    .eq("customer_id", ctx.customerId).in("id", unique);
  const map: Record<string, string> = {};
  for (const u of data ?? []) map[u.id] = u.username;
  return map;
}

export async function pendingSaleIds(
  db: any,
  ctx: Ctx,
  saleIds: string[],
): Promise<Set<string>> {
  const unique = [...new Set(saleIds.filter(Boolean))];
  if (!unique.length) return new Set();
  const { data } = await db.from("void_requests").select("sale_id")
    .eq("customer_id", ctx.customerId).eq("status", "PENDING").in(
      "sale_id",
      unique,
    );
  return new Set((data ?? []).map((r: any) => r.sale_id));
}

export function excludeDemoRows(q: any, ids: string[], column: string): any {
  if (!ids.length) return q;
  return q.not(column, "in", `(${ids.map((id) => `"${id}"`).join(",")})`);
}

export async function demoUserIds(db: any, ctx: Ctx): Promise<string[]> {
  const { data, error } = await db.from("pos_users").select("id")
    .eq("customer_id", ctx.customerId).eq("is_demo", true);
  if (error) throw new Error(error.message);
  return strip(data).map((r: any) => r.id) as string[];
}

export const MAX_PAGE = 1000;

export function pageLimit(body: any, fallback: number = MAX_PAGE): number {
  const n = Number(body?.limit);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(Math.floor(n), MAX_PAGE);
}

export const SHOP_TIME_ZONE = "Africa/Addis_Ababa";

export function shopDay(d: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: SHOP_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}${get("month")}${get("day")}`;
}

export function rpcFailure(message: string): Response {
  const m = String(message || "").trim();
  if (
    /not found|no longer|already voided|not voidable|not pending|already decided|already open|already exists|no longer open/i
      .test(m)
  ) {
    return json({ ok: false, error: m }, 409);
  }
  return json({ ok: false, error: m || "Operation rejected." }, 400);
}

// Picklist money columns are Postgres `int` (32-bit), so a price or line total
// above this would fail the write instead of landing as a value.
export const PICKLIST_MAX_MINOR_UNITS = 2147483647;

// Reconciliation shared by register_snapshot + shift_summary + dashboard.
// Delegates to the pos_expected_cash SQL aggregate (audit #9) so the drawer
// balance stays exact even when a shift has more than PostgREST's 1000-row
// fetch cap worth of sales/movements. Mirrors the native rule including the
// cross-shift cash refund netting (a sale rung up in another shift but refunded
// while this one was open is the only void that drains THIS drawer).
export async function computeExpectedCash(
  db: any,
  customerId: string,
  shift: any,
): Promise<number> {
  const { data, error } = await db.rpc("pos_expected_cash", {
    p_customer: customerId,
    p_shift_id: shift.id,
  });
  if (error) throw new Error(error.message);
  return Number(data ?? 0);
}

// Register balance (all-time expected cash) plus today's activity counters,
// date-filtered so the counters reset each calendar day. Mirrors
// ShiftRepository.getRegisterSnapshot. Zeros when no shift is open.
export function registerSnapshotHelper(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  return (async () => {
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
  })();
}

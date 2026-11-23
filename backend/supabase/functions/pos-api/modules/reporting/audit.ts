import type { Ctx } from "../../shared/types.ts";
import { json, pageLimit, strip, usernamesById } from "../../shared/helpers.ts";

export async function listAudit(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const limit = pageLimit(body, 500);
  const { data, error } = await db.from("pos_audit_logs").select("*")
    .eq("customer_id", ctx.customerId).order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error(error.message);
  const logs = strip(data);
  // `username` is display-only and never stored; joined from pos_users so the
  // Audit screen renders the same shape as the local SQLite implementation.
  const names = await usernamesById(db, ctx, logs.map((l: any) => l.user_id));
  for (const l of logs) {
    l.username = l.user_id ? (names[l.user_id] ?? null) : null;
  }
  return json({ ok: true, audit_logs: logs, truncated: logs.length >= limit });
}

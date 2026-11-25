import type { Ctx } from "../../shared/types.ts";
import { audit, json, str, userStamp } from "../../shared/helpers.ts";
import {
  CASHIER,
  FEATURE_KEYS,
  hashPassword,
  normalizePhone,
  OWNER,
  PHONE_INVALID,
  revokeActorGrants,
} from "../../shared/auth.ts";

// userStamp is used across user mutations — mirroring the sync gateway paging requirement
export { userStamp };

export async function createUser(db: any, ctx: Ctx, body: any) {
  const rawName = str(body.username);
  const role = String(body.role ?? "");
  const password = String(body.password ?? "");
  if (!rawName) {
    return json({ ok: false, error: "Phone number required." }, 400);
  }
  if (rawName.trim().toLowerCase() === "demo") {
    return json({
      ok: false,
      error: "That name is reserved for the demo account.",
    }, 400);
  }
  const username = normalizePhone(rawName);
  if (!username) return json({ ok: false, error: PHONE_INVALID }, 400);
  if (![OWNER, CASHIER].includes(role)) {
    return json({ ok: false, error: "Invalid role." }, 400);
  }
  if (role === OWNER) {
    const { count } = await db.from("pos_users")
      .select("*", { count: "exact", head: true })
      .eq("customer_id", ctx.customerId).eq("role", OWNER);
    if ((count ?? 0) > 0) {
      return json({
        ok: false,
        error: "This shop already has an owner account.",
      }, 409);
    }
  }
  const minLen = role === OWNER ? 12 : 8;
  if (password.length < minLen) {
    return json({
      ok: false,
      error: `Password must be at least ${minLen} characters.`,
    }, 400);
  }
  if (password.length > 256) {
    return json({ ok: false, error: "Password is too long." }, 400);
  }
  const rawPerms = Array.isArray(body.permissions)
    ? body.permissions.map(String)
    : [];
  const perms = role === OWNER
    ? []
    : Array.from(new Set(rawPerms.filter((k: string) => FEATURE_KEYS.has(k))));
  const { data: dup, error: dupErr } = await db.from("pos_users").select(
    "id, deleted_at",
  )
    .eq("customer_id", ctx.customerId).ilike(
      "username",
      username.toLowerCase().replace(/[%_]/g, ""),
    ).maybeSingle();
  if (dupErr) throw new Error(`duplicate username check: ${dupErr.message}`);
  if (dup && !dup.deleted_at) {
    return json(
      { ok: false, error: "That phone number is already in use." },
      409,
    );
  }
  const { salt, hash } = await hashPassword(password);
  if (dup?.deleted_at) {
    const up = await db.from("pos_users").update(userStamp({
      username,
      role,
      pw_salt: salt,
      pw_hash: hash,
      active: true,
      permissions: perms,
      is_demo: false,
      deleted_at: null,
    })).eq("customer_id", ctx.customerId).eq("id", dup.id);
    if (up.error) {
      if (/duplicate key|unique/i.test(up.error.message)) {
        return json({
          ok: false,
          error: "That phone number is already in use.",
        }, 409);
      }
      throw new Error(up.error.message);
    }
    await audit(
      db,
      ctx.customerId,
      ctx.userId,
      "USER_CREATED",
      `Deleted account "${username}" reused (${role}).`,
    );
    return json({ ok: true, id: dup.id });
  }
  const id = crypto.randomUUID();
  const ins = await db.from("pos_users").insert({
    id,
    customer_id: ctx.customerId,
    username,
    role,
    pw_salt: salt,
    pw_hash: hash,
    active: true,
    permissions: perms,
  });
  if (ins.error) {
    if (/duplicate key|unique/i.test(ins.error.message)) {
      return json(
        { ok: false, error: "That phone number is already in use." },
        409,
      );
    }
    throw new Error(ins.error.message);
  }
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "USER_CREATED",
    `User "${username}" (${role}).`,
  );
  return json({ ok: true, id });
}

export async function setUserPermissions(db: any, ctx: Ctx, body: any) {
  const target = String(body.target_user_id ?? "");
  const rawPerms = Array.isArray(body.permissions)
    ? body.permissions.map(String)
    : [];
  const perms = Array.from(
    new Set(rawPerms.filter((k: string) => FEATURE_KEYS.has(k))),
  );
  const { data: t } = await db.from("pos_users").select("role, username")
    .eq("customer_id", ctx.customerId).eq("id", target).is("deleted_at", null)
    .maybeSingle();
  if (!t) return json({ ok: false, error: "User not found." }, 404);
  if (t.role === OWNER) {
    return json({
      ok: false,
      error: "Owner accounts bypass feature permissions.",
    }, 400);
  }
  const up = await db.from("pos_users").update(
    userStamp({ permissions: perms }),
  )
    .eq("customer_id", ctx.customerId).eq("id", target);
  if (up.error) throw new Error(up.error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "USER_PERMISSIONS_SET",
    `Permissions for "${t.username}": ${perms.join(", ") || "(none)"}.`,
  );
  return json({ ok: true });
}

export async function setUserPhone(db: any, ctx: Ctx, body: any) {
  const target = String(body.target_user_id ?? "");
  const phone = normalizePhone(String(body.phone ?? ""));
  if (!phone) return json({ ok: false, error: PHONE_INVALID }, 400);
  const { data: t } = await db.from("pos_users").select("username, is_demo")
    .eq("customer_id", ctx.customerId).eq("id", target).is("deleted_at", null)
    .maybeSingle();
  if (!t) return json({ ok: false, error: "User not found." }, 404);
  if (t.is_demo) {
    return json(
      { ok: false, error: "The demo account keeps its demo login." },
      400,
    );
  }
  const { data: dup, error: dupErr } = await db.from("pos_users").select("id")
    .eq("customer_id", ctx.customerId).ilike("username", phone).neq(
      "id",
      target,
    ).maybeSingle();
  if (dupErr) throw new Error(`duplicate phone check: ${dupErr.message}`);
  if (dup) {
    return json(
      { ok: false, error: "That phone number is already in use." },
      409,
    );
  }
  const up = await db.from("pos_users").update(userStamp({ username: phone }))
    .eq("customer_id", ctx.customerId).eq("id", target);
  if (up.error) throw new Error(up.error.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "USER_PHONE_CHANGED",
    `Login phone for "${t.username}" is now "${phone}".`,
  );
  return json({ ok: true });
}

export async function resetPassword(db: any, ctx: Ctx, body: any) {
  const target = String(body.target_user_id ?? "");
  const password = String(body.new_password ?? "");
  const { data: t } = await db.from("pos_users").select(
    "role, username, token_version",
  )
    .eq("customer_id", ctx.customerId).eq("id", target).is("deleted_at", null)
    .maybeSingle();
  if (!t) return json({ ok: false, error: "User not found." }, 404);
  const minLen = t.role === OWNER ? 12 : 8;
  if (password.length < minLen) {
    return json({
      ok: false,
      error: `Password must be at least ${minLen} characters.`,
    }, 400);
  }
  if (password.length > 256) {
    return json({ ok: false, error: "Password is too long." }, 400);
  }
  const { salt, hash } = await hashPassword(password);
  const up = await db.from("pos_users").update(
    userStamp({
      pw_salt: salt,
      pw_hash: hash,
      token_version: (t.token_version ?? 0) + 1,
    }),
  )
    .eq("customer_id", ctx.customerId).eq("id", target);
  if (up.error) throw new Error(up.error.message);
  await revokeActorGrants(db, ctx.customerId, target, null);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PASSWORD_RESET",
    `Password reset for "${t.username}".`,
  );
  return json({ ok: true });
}

export async function setUserActive(db: any, ctx: Ctx, body: any) {
  const target = String(body.target_user_id ?? "");
  if (!target) {
    return json({ ok: false, error: "Target user is required." }, 400);
  }
  if (typeof body.active !== "boolean") {
    return json({ ok: false, error: "active must be true or false." }, 400);
  }
  const active: boolean = body.active;
  if (target === ctx.userId && !active) {
    return json(
      { ok: false, error: "You cannot deactivate your own account." },
      400,
    );
  }
  const { data: t, error: readErr } = await db.from("pos_users")
    .select("role, is_demo, username, token_version")
    .eq("customer_id", ctx.customerId).eq("id", target).is("deleted_at", null)
    .maybeSingle();
  if (readErr) throw new Error(readErr.message);
  if (!t) return json({ ok: false, error: "User not found." }, 404);
  if (!active) {
    if (t.is_demo) {
      return json({
        ok: false,
        error: "The demo account cannot be deactivated.",
      }, 400);
    }
    if (t.role === OWNER) {
      const { count, error: countErr } = await db.from("pos_users").select(
        "*",
        { count: "exact", head: true },
      )
        .eq("customer_id", ctx.customerId).eq("role", OWNER).eq("active", true);
      if (countErr) throw new Error(countErr.message);
      if ((count ?? 0) <= 1) {
        return json({
          ok: false,
          error: "At least one active owner is required.",
        }, 409);
      }
    }
  }
  const up = await db.from("pos_users")
    .update(
      userStamp({ active, token_version: Number(t.token_version ?? 0) + 1 }),
    )
    .eq("customer_id", ctx.customerId).eq("id", target).is("deleted_at", null)
    .select("id");
  if (up.error) throw new Error(up.error.message);
  if (!Array.isArray(up.data) || up.data.length !== 1) {
    return json({ ok: false, error: "User not found." }, 404);
  }
  await revokeActorGrants(db, ctx.customerId, target, null);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    active ? "USER_ACTIVATED" : "USER_DEACTIVATED",
    `Account "${t.username ?? target}" ${
      active ? "activated" : "deactivated"
    }.`,
  );
  return json({ ok: true });
}

export async function deleteUser(db: any, ctx: Ctx, body: any) {
  const target = String(body.target_user_id ?? "");
  if (target === ctx.userId) {
    return json(
      { ok: false, error: "You cannot delete your own account." },
      400,
    );
  }
  const { data: t } = await db.from("pos_users").select(
    "username, active, is_demo, token_version",
  )
    .eq("customer_id", ctx.customerId).eq("id", target).is("deleted_at", null)
    .maybeSingle();
  if (!t) return json({ ok: false, error: "User not found." }, 404);
  if (t.is_demo) {
    return json(
      { ok: false, error: "The demo account cannot be deleted." },
      400,
    );
  }
  if (t.active !== false) {
    return json({
      ok: false,
      error: "Deactivate the account before deleting it.",
    }, 400);
  }

  const counted = async (table: string, column: string): Promise<number> => {
    const { count, error } = await db.from(table).select("*", {
      count: "exact",
      head: true,
    })
      .eq("customer_id", ctx.customerId).eq(column, target);
    if (error) throw new Error(error.message);
    return count ?? 0;
  };
  const records = (await counted("sales", "cashier_id")) +
    (await counted("shifts", "cashier_id")) +
    (await counted("cash_movements", "user_id")) +
    (await counted("void_requests", "requested_by")) +
    (await counted("void_requests", "decided_by")) +
    (await counted("pos_finance_entries", "created_by")) +
    (await counted("pos_finance_entries", "completed_by"));

  if (records > 0) {
    const up = await db.from("pos_users").update(userStamp({
      deleted_at: new Date().toISOString(),
      token_version: (t.token_version ?? 0) + 1,
    })).eq("customer_id", ctx.customerId).eq("id", target);
    if (up.error) throw new Error(up.error.message);
  } else {
    const del = await db.from("pos_users").delete()
      .eq("customer_id", ctx.customerId).eq("id", target);
    if (del.error) throw new Error(del.error.message);
  }
  await revokeActorGrants(db, ctx.customerId, target, null);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "USER_DELETED",
    `Account "${t.username}" was deleted${
      records > 0 ? " (history retained)" : ""
    }.`,
  );
  return json({ ok: true, retained: records > 0 });
}

// Device management for the shop's activation code(s).
//
// Security posture (Request 2):
//   * OWNER-only — enforced upstream by OWNER_ONLY in shared/authorization.ts
//     (verified JWT + active OWNER row + token-version match). `ctx.customerId`
//     comes from the verified token, never from the request body.
//   * Tenant-scoped — every read/write is filtered through the license rows
//     that belong to `ctx.customerId`; a registration id from another shop
//     resolves to 404, not data.
//   * Masked fingerprints — the management list never returns a full device
//     fingerprint, only `fingerprint_masked` plus the registration `id` the
//     client uses for deactivation.
//   * Self-deactivation is refused server-side when the device identity
//     carried inside the caller's Ed25519-signed license proof — a bearer
//     document, NOT a request field and NOT hardware-bound proof-of-
//     possession (see shared/license_proof.ts) — matches the target
//     registration; hiding the button in the UI is not the enforcement.
//     Requests without a verifiable device proof are rejected outright
//     (fail closed): an unbound session cannot even assert which device
//     identity it holds, so it must not claim self-protection.

import { audit, json, str } from "../../shared/helpers.ts";
import { verifyDeviceLicense } from "../../shared/license_proof.ts";
import { revokeActorGrants } from "../../shared/auth.ts";
import type { Ctx } from "../../shared/types.ts";

const MAX_FIELD_LEN = 256;

function maskFingerprint(fp: string): string {
  if (fp.length <= 8) return fp;
  return `${fp.slice(0, 4)}...${fp.slice(-4)}`;
}

/// The activation codes owned by this tenant. Device registrations hang off
/// `licenses.activation_code`, so tenant scoping always goes through here.
async function tenantCodes(db: any, customerId: string) {
  const { data, error } = await db.from("licenses")
    .select("activation_code, expires_at, revoked_at")
    .eq("customer_id", customerId);
  if (error) throw new Error(error.message);
  return (data ?? []) as any[];
}

// list_devices — every ACTIVE registration across the tenant's codes.
// Input:  { action, device_fingerprint?, license? }
//   `license` is the caller's signed device license; when it verifies, its
//   fingerprint (not the request field) marks is_self. Bearer semantics:
//   a copied license marks ITS device as self regardless of which hardware
//   presents it — is_self is display-only, never an authorization input.
// Output: { ok, devices: [{id, device_name, fingerprint_masked,
//           activation_code_masked, first_seen, last_heartbeat, is_self}],
//           active_devices }
export async function listDevices(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const selfFp = str(body.device_fingerprint);
  if (selfFp.length > MAX_FIELD_LEN) {
    return json({ ok: false, error: "Field too long." }, 400);
  }
  // A verified license proof upgrades the self marker from a client-supplied
  // hint to a server-verified identity ASSERTION. Because the license is a
  // bearer document (no device-held key, no challenge), the assertion is
  // "the presented license belongs to device X" — not proof that hardware
  // X is calling. An absent/invalid proof simply falls back to the hint —
  // is_self is display-only, never an authorization input.
  let verifiedFp: string | null = null;
  const license = str(body.license);
  if (license) {
    const proof = await verifyDeviceLicense(db, license, ctx.customerId);
    if (proof.ok) verifiedFp = proof.deviceFingerprint;
  }
  const licenses = await tenantCodes(db, ctx.customerId);
  const codes = licenses.map((l) => l.activation_code);
  if (!codes.length) {
    return json({ ok: true, devices: [], active_devices: 0 });
  }
  const { data: regs, error } = await db.from("device_registrations")
    .select(
      "id, activation_code, device_fingerprint, device_name, first_seen, last_heartbeat",
    )
    .in("activation_code", codes).is("revoked_at", null).order("first_seen");
  if (error) throw new Error(error.message);

  const devices = (regs ?? []).map((r: any) => ({
    id: r.id,
    device_name: r.device_name,
    fingerprint_masked: maskFingerprint(String(r.device_fingerprint ?? "")),
    activation_code_masked: maskFingerprint(String(r.activation_code ?? "")),
    first_seen: r.first_seen,
    last_heartbeat: r.last_heartbeat,
    is_self: (verifiedFp ?? selfFp).length > 0 &&
      r.device_fingerprint === (verifiedFp ?? selfFp),
  }));
  return json({ ok: true, devices, active_devices: devices.length });
}

// deactivate_device — revoke one registration by its database id.
// Input:  { action, registration_id, license }
//   `license` is REQUIRED: the signed device license whose embedded
//   fingerprint decides self-protection. It is a bearer document — whoever
//   holds a valid license_code asserts that device identity, so the check
//   below compares the LICENSE's fingerprint, not proven hardware.
//   body.device_fingerprint is deliberately NOT consulted — it is
//   client-supplied and forgeable, so it can never stand in for the proof.
// Output: { ok } | 403 no/invalid device proof | 404 unknown/foreign id |
//         409 already revoked / self
export async function deactivateDevice(
  db: any,
  ctx: Ctx,
  body: any,
): Promise<Response> {
  const registrationId = str(body.registration_id ?? body.device_id);
  if (!registrationId || registrationId.length > MAX_FIELD_LEN) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }

  // Device binding: the caller must present its signed license so the
  // server knows which device identity is asserted. Sessions that cannot
  // produce one (e.g. a web/PWA sign-in, which has no per-device license)
  // fail closed — the endpoint never falls back to trusting a request
  // field for self-protection. Bearer caveat: a copied license from
  // another active device verifies too (see shared/license_proof.ts), so
  // this binds the license STRING to a fingerprint, not the caller to
  // hardware.
  const proof = await verifyDeviceLicense(
    db,
    str(body.license),
    ctx.customerId,
  );
  if (!proof.ok) {
    return json({ ok: false, error: proof.error }, proof.status);
  }
  const selfFp = proof.deviceFingerprint;

  const { data: reg, error: regErr } = await db.from("device_registrations")
    .select("id, activation_code, device_fingerprint, device_name")
    .eq("id", registrationId).maybeSingle();
  if (regErr) throw new Error(regErr.message);
  if (!reg) return json({ ok: false, error: "Device not found." }, 404);

  // Tenant check: the registration's license must belong to this customer.
  // A foreign id is indistinguishable from a missing one.
  const { data: lic, error: licErr } = await db.from("licenses")
    .select("customer_id").eq("activation_code", reg.activation_code)
    .maybeSingle();
  if (licErr) throw new Error(licErr.message);
  if (!lic || lic.customer_id !== ctx.customerId) {
    return json({ ok: false, error: "Device not found." }, 404);
  }

  // Server-side self-deactivation protection: the device fingerprint inside
  // the VERIFIED license proof — not any request field — decides whether
  // the target registration is the device identity this request claims.
  // Bearer semantics apply: presenting another active device's license
  // asserts THAT device, so self-protection follows the license, not the
  // physical hardware (documented limitation — Request 3 threat model).
  if (reg.device_fingerprint === selfFp) {
    return json(
      { ok: false, error: "You cannot deactivate the device you are using." },
      409,
    );
  }

  // Atomic revoke: the .is(revoked_at, null) guard collapses a concurrent
  // double-deactivate to a 0-row update instead of a false success.
  const { data: revoked, error: updErr } = await db.from("device_registrations")
    .update({ revoked_at: new Date().toISOString() })
    .eq("id", registrationId).is("revoked_at", null).select("id");
  if (updErr) throw new Error(updErr.message);
  if (!revoked || revoked.length === 0) {
    return json({ ok: false, error: "Device was already deactivated." }, 409);
  }

  // A deactivated device must not keep a usable actor grant. The gateway also
  // refuses an inactive seat, but revoking here removes the credential itself.
  await revokeActorGrants(
    db,
    ctx.customerId,
    null,
    reg.device_fingerprint,
  );

  // Audit on BOTH trails: license_audit is the licensing-domain record the
  // operator tools read; pos_audit_logs is the tenant-visible activity log.
  const { error: auditErr } = await db.from("license_audit").insert({
    activation_code: reg.activation_code,
    device_fingerprint: reg.device_fingerprint,
    event: "deactivate",
    detail: { by_user_id: ctx.userId, device_name: reg.device_name },
  });
  if (auditErr) console.error("license_audit insert failed:", auditErr.message);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "DEVICE_DEACTIVATED",
    `Device "${reg.device_name ?? reg.device_fingerprint}" deactivated.`,
  );
  return json({ ok: true });
}

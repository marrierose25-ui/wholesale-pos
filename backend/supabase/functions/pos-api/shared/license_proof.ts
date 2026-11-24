// Server-side verification of the signed device license (the same Ed25519
// payload the `licensing` function mints at activation and the `sync`
// gateway already verifies). Used by device-management actions to bind a
// request to a device identity the CLIENT CANNOT FORGE *in a request
// field*: the fingerprint is carved out of the verified signature payload,
// never read from a request field.
//
// BEARER SEMANTICS — read before relying on this: the license is a signed
// DOCUMENT, not a hardware-bound credential. There is no device-held
// private key and no challenge-response, so verification proves only that
// a genuine license was issued for (activation_code, device_fingerprint)
// and that the pair still holds an ACTIVE device_registrations row. Anyone
// holding a valid license_code string — a copied file, a backed-up
// activation response, another device's stored license — presents the
// SAME proof. The result means "this request carries a valid license for
// device X", never "the physical device X is calling". Do not describe
// this as proof-of-possession; that claim requires a mechanism that does
// not exist yet (flagged for the Request 3 threat-model review).
//
// A valid proof means ALL of:
//   * the Ed25519 signature verifies against POS_API_LICENSE_PUBLIC_KEY;
//   * payload is format wholesale-pos-license v2 with the required fields;
//   * expires_at is still in the future;
//   * the license row exists, is not revoked, and belongs to the caller's
//     tenant (customer_id inside the signed payload);
//   * the (activation_code, device_fingerprint) pair still holds an ACTIVE
//     device_registrations row — a deactivated device's unexpired license
//     stops being proof the moment its seat is revoked.

import { ed25519 } from "https://esm.sh/@noble/curves@1.4.0/ed25519";
import { LICENSE_PUBLIC_KEY_HEX } from "./env.ts";

export interface DeviceProof {
  ok: true;
  activationCode: string;
  deviceFingerprint: string;
  customerId: string;
}
export interface DeviceProofFailure {
  ok: false;
  status: number;
  error: string;
}
export type DeviceProofResult = DeviceProof | DeviceProofFailure;

function proofFail(status: number, error: string): DeviceProofFailure {
  return { ok: false, status, error };
}

function base64UrlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/// Verify `licenseCode` (the `<payload>.<signature>` string activation
/// returns) end-to-end. `expectedCustomerId` is the tenant carved from the
/// caller's verified session JWT — a license minted for another shop is
/// rejected even though its signature is genuine.
///
/// Bearer document: a copied license_code from ANY still-active device on
/// the same tenant verifies identically. See the file header — this is not
/// hardware-bound proof-of-possession.
export async function verifyDeviceLicense(
  db: any,
  licenseCode: string,
  expectedCustomerId: string,
): Promise<DeviceProofResult> {
  if (!licenseCode) {
    return proofFail(403, "A device license proof is required.");
  }
  const dot = licenseCode.indexOf(".");
  if (dot <= 0) {
    return proofFail(403, "Device license proof is invalid.");
  }
  let payload: any;
  let code = "";
  let fingerprint = "";
  try {
    const payloadBytes = base64UrlDecode(licenseCode.slice(0, dot));
    const signature = base64UrlDecode(licenseCode.slice(dot + 1));
    if (
      !ed25519.verify(
        signature,
        payloadBytes,
        hexToBytes(LICENSE_PUBLIC_KEY_HEX),
      )
    ) {
      return proofFail(403, "Device license proof is invalid.");
    }
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return proofFail(403, "Device license proof is invalid.");
  }

  if (payload.format !== "wholesale-pos-license" || payload.version !== 2) {
    return proofFail(403, "Device license proof is invalid.");
  }
  code = String(payload.activation_code ?? "");
  fingerprint = String(payload.device_fingerprint ?? "");
  const customerId = String(payload.customer_id ?? "");
  if (!code || !fingerprint || !customerId) {
    return proofFail(403, "Device license proof is invalid.");
  }
  if (customerId !== expectedCustomerId) {
    return proofFail(403, "Device license proof is invalid.");
  }

  const expires = Date.parse(String(payload.expires_at ?? ""));
  if (!Number.isFinite(expires) || expires < Date.now()) {
    return proofFail(403, "Device license proof has expired.");
  }

  const { data: licRow, error: licErr } = await db
    .from("licenses").select("revoked_at").eq("activation_code", code)
    .maybeSingle();
  if (licErr) throw new Error(licErr.message);
  if (!licRow) return proofFail(403, "Device license proof is invalid.");
  if (licRow.revoked_at) {
    return proofFail(403, "Device license proof is invalid.");
  }

  const { data: seat, error: seatErr } = await db
    .from("device_registrations").select("id")
    .eq("activation_code", code).eq("device_fingerprint", fingerprint)
    .is("revoked_at", null).maybeSingle();
  if (seatErr) throw new Error(seatErr.message);
  if (!seat) {
    return proofFail(403, "Device license proof is no longer active.");
  }

  return {
    ok: true,
    activationCode: code,
    deviceFingerprint: fingerprint,
    customerId,
  };
}

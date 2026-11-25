// Server-side verification of the signed device license (the same Ed25519
// payload the `licensing` function mints at activation and the `sync`
// gateway already verifies). Used by device-management actions and by
// `issue_actor_grant` to bind a request to a device identity the CLIENT
// CANNOT FORGE *in a request field*: the fingerprint is carved out of the
// verified signature payload, never read from a request field.
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
// not exist yet.
//
// A valid proof means ALL of:
//   * the Ed25519 signature verifies against POS_API_LICENSE_PUBLIC_KEY;
//   * payload is format wholesale-pos-license v2 with the required fields;
//   * expires_at is still in the future;
//   * the license row exists, is not revoked, and its customer_id matches the
//     customer_id inside the signed payload;
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

interface ParsedPayload {
  ok: true;
  code: string;
  fingerprint: string;
  customerId: string;
}
type ParsedResult = ParsedPayload | DeviceProofFailure;

/// Signature + format + expiry. Does NOT touch the database, so both the
/// authenticated and standalone entry points share exactly one parser.
function parseSignedLicense(licenseCode: string): ParsedResult {
  if (!licenseCode) {
    return proofFail(403, "A device license proof is required.");
  }
  const dot = licenseCode.indexOf(".");
  if (dot <= 0) {
    return proofFail(403, "Device license proof is invalid.");
  }
  let payload: any;
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
  const code = String(payload.activation_code ?? "");
  const fingerprint = String(payload.device_fingerprint ?? "");
  const customerId = String(payload.customer_id ?? "");
  if (!code || !fingerprint || !customerId) {
    return proofFail(403, "Device license proof is invalid.");
  }
  const expires = Date.parse(String(payload.expires_at ?? ""));
  if (!Number.isFinite(expires) || expires < Date.now()) {
    return proofFail(403, "Device license proof has expired.");
  }
  return { ok: true, code, fingerprint, customerId };
}

/// Confirm the database still backs the parsed licence: the activation code
/// exists, is not revoked, belongs to the customer named in the payload, and
/// the (code, fingerprint) pair still holds an active seat.
async function activeSeat(
  db: any,
  code: string,
  fingerprint: string,
  customerId: string,
): Promise<DeviceProofResult> {
  const { data: licRow, error: licErr } = await db
    .from("licenses").select("customer_id, revoked_at")
    .eq("activation_code", code).maybeSingle();
  if (licErr) throw new Error(licErr.message);
  if (!licRow) return proofFail(403, "Device license proof is invalid.");
  if (licRow.revoked_at) {
    return proofFail(403, "Device license proof is invalid.");
  }
  // The signed payload and the license row must name the same tenant. Without
  // this, a mis-issued signature could bind a code to the wrong partition.
  if (String(licRow.customer_id) !== customerId) {
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

/// Verify `licenseCode` end-to-end. `expectedCustomerId` is the tenant carved
/// from the caller's verified session JWT — a license minted for another shop
/// is rejected even though its signature is genuine.
///
/// Bearer document: a copied license_code from ANY still-active device on
/// the same tenant verifies identically. See the file header — this is not
/// hardware-bound proof-of-possession.
export async function verifyDeviceLicense(
  db: any,
  licenseCode: string,
  expectedCustomerId: string,
): Promise<DeviceProofResult> {
  const parsed = parseSignedLicense(licenseCode);
  if (!parsed.ok) return parsed;
  if (parsed.customerId !== expectedCustomerId) {
    return proofFail(403, "Device license proof is invalid.");
  }
  return await activeSeat(
    db,
    parsed.code,
    parsed.fingerprint,
    parsed.customerId,
  );
}

/// Verify a licence presented by an UNAUTHENTICATED caller (grant issuance).
/// There is no session tenant to compare against, so the tenant is taken from
/// the signed payload and then checked against the license row and the active
/// seat. Same bearer caveat: this proves the string is a genuine, active
/// licence, not that the physical device is present.
export async function verifyStandaloneDeviceLicense(
  db: any,
  licenseCode: string,
): Promise<DeviceProofResult> {
  const parsed = parseSignedLicense(licenseCode);
  if (!parsed.ok) return parsed;
  return await activeSeat(
    db,
    parsed.code,
    parsed.fingerprint,
    parsed.customerId,
  );
}

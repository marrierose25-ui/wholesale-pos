import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Base64 budget for a web proof photo. It has to clear every downstream cap
/// at once: the PWA's own save (`pos-api` rejects base64 longer than 300 KB),
/// the native pull (drops anything longer than 200 KB) and the native local
/// add (rejects anything longer than 200 KB). Stay under the tightest of them
/// with headroom so a photo captured here survives the whole round-trip and
/// shows up on the till that made it.
const int _maxProofBase64 = 190 * 1024;

/// Web proof-photo picker: the browser's own file pick (camera included on
/// capable devices) followed by a pure-Dart JPEG compression. dart:ui has no
/// JPEG encoder on web — the old canvas/PNG path produced multi-megabyte
/// base64 that the server rejected with "Proof photo is too large", which is
/// why PWA proof uploads failed while the native app (image_picker's JPEG)
/// worked. `package:image` resizes and re-encodes to a ledger-sized JPEG here.
Future<String?> pickProofPhoto(BuildContext context) async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp']),
    ],
  );
  if (file == null) return null;
  return encodeProof(await file.readAsBytes());
}

/// Downscales to at most 1280px on the longest side and returns a base64 JPEG
/// guaranteed to fit [_maxProofBase64]. Null when the bytes are not a decodable
/// image.
Future<String?> encodeProof(Uint8List bytes) async {
  var decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  const maxSide = 1280;
  if (decoded.width > maxSide || decoded.height > maxSide) {
    decoded = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxSide)
        : img.copyResize(decoded, height: maxSide);
  }

  // Walk quality down at the current frame; if even the lowest quality is
  // still over budget, shrink the frame and repeat. Guarantees a ledger-sized
  // JPEG for any decodable image — a normal photograph exits on the first
  // quality step, dense/high-detail captures fall back to a smaller frame.
  var work = decoded;
  for (var pass = 0; pass < 6; pass++) {
    for (final quality in const [85, 70, 55, 40]) {
      final b64 = base64Encode(img.encodeJpg(work, quality: quality));
      if (b64.length <= _maxProofBase64) return b64;
    }
    final nextWidth = (work.width * 0.75).round();
    if (nextWidth < 320) break;
    work = img.copyResize(work, width: nextWidth);
  }
  // Smallest allowed frame at low quality — always comfortably under budget.
  return base64Encode(img.encodeJpg(work, quality: 30));
}

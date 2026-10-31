import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wholesale_pos_app/core/utils/proof_photo_web.dart';

// The PWA proof-photo picker compresses the picked file to a base64 JPEG that
// clears every downstream cap in one shot: pos-api's 300 KB save limit and the
// native pull / local-add 200 KB limits. The old canvas/PNG path produced
// multi-megabyte base64 that the server rejected with "Proof photo is too
// large" — which is exactly why PWA uploads failed while the native app worked.
void main() {
  // A large, high-entropy 1600x1200 source. Per-pixel random noise is the
  // worst case for PNG (incompressible), so the base64 pick is multi-megabyte
  // — the exact shape that used to blow past pos-api's 300 KB cap. Seeded for
  // a deterministic run.
  Uint8List bigSource() {
    final rng = math.Random(42);
    final image = img.Image(width: 1600, height: 1200);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(
          x,
          y,
          rng.nextInt(256),
          rng.nextInt(256),
          rng.nextInt(256),
        );
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  test(
    'encodeProof compresses a large photo to a base64 JPEG under budget',
    () async {
      final source = bigSource();
      // Sanity: the raw pick is oversized, otherwise the assertion is vacuous.
      expect(base64Encode(source).length, greaterThan(300 * 1024));

      final encoded = await encodeProof(source);
      expect(encoded, isNotNull);
      final b64 = encoded!;

      // Under the tightest downstream cap (the 200 KB native pull / local add),
      // with the 190 KB budget leaving headroom.
      expect(b64.length, lessThanOrEqualTo(200 * 1024));

      // It is a real, decodable JPEG (SOI marker FF D8), not a PNG.
      final bytes = base64Decode(b64);
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
      final decoded = img.decodeJpg(bytes);
      expect(decoded, isNotNull);

      // Downscaled to at most 1280px on the longest side.
      expect(decoded!.width, lessThanOrEqualTo(1280));
      expect(decoded.height, lessThanOrEqualTo(1280));
    },
  );

  test('encodeProof returns null for undecodable bytes', () async {
    expect(await encodeProof(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
  });
}

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

/// Web proof-photo picker: a file pick (the browser's own picker, camera
/// included on capable devices) followed by a canvas downscale, because the
/// web engine has no JPEG encoder — the resized PNG is encoded base64.
Future<String?> pickProofPhoto(BuildContext context) async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp']),
    ],
  );
  if (file == null) return null;
  return encodeProof(await file.readAsBytes());
}

/// Downscales to at most 1280px on the longest side and returns base64 PNG.
Future<String?> encodeProof(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = (await codec.getNextFrame()).image;
  final width = frame.width;
  final height = frame.height;
  const maxSide = 1280;
  final scale = width > maxSide || height > maxSide
      ? maxSide / (width > height ? width : height)
      : 1.0;
  final targetWidth = (width * scale).round();
  final targetHeight = (height * scale).round();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    frame,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final image = await recorder.endRecording().toImage(
    targetWidth,
    targetHeight,
  );
  frame.dispose();
  codec.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) return null;
  return base64Encode(data.buffer.asUint8List());
}

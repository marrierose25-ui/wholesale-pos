import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'proof_photo.dart' show proofSupportsCamera;

/// Native proof-photo picker (Windows/macOS/Linux/Android/iOS).
///
/// Phones get a camera-or-gallery sheet; everything else jumps straight to a
/// file picker. image_picker downscales to 1280px and re-encodes at quality
/// 80 platform-side, so the base64 proof stays ledger-sized without any
/// Dart-side decode.
Future<String?> pickProofPhoto(BuildContext context) async {
  if (proofSupportsCamera) {
    final source = await showModalBottomSheet<_ProofSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, _ProofSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, _ProofSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return null;
    // imageQuality/maxWidth keep the captured proof small; cancel -> null.
    final file = await ImagePicker().pickImage(
      source: source == _ProofSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 80,
    );
    if (file == null) return null;
    return base64Encode(await file.readAsBytes());
  }
  // Desktop: a plain image file pick (a captured photo lives as a file).
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp']),
    ],
  );
  if (file == null) return null;
  return base64Encode(await file.readAsBytes());
}

enum _ProofSource { camera, gallery }

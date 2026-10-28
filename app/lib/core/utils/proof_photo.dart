import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'proof_photo_io.dart'
    if (dart.library.js_interop) 'proof_photo_web.dart'
    as impl;

/// Picks an optional proof photo for a register cash movement.
///
/// Returns the image as a base64-encoded compressed JPEG (native, via
/// image_picker's own resizing) or PNG (desktop file picks and web), ready
/// to store in the movement's `photo` column. Null when the user cancels. On
/// Android/iOS the user first chooses camera or gallery; on Windows desktop
/// and web a plain file picker opens instead.
Future<String?> pickProofPhoto(BuildContext context) =>
    impl.pickProofPhoto(context);

/// Whether the app runs on a phone/tablet where the camera option exists.
bool get proofSupportsCamera =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

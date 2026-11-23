import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'proof_photo_codec.dart';

/// Web proof-photo picker. The user first chooses between the device camera
/// and a normal file pick; on a tablet the camera option opens the camera app
/// directly (the HTML `capture` attribute), which a plain file picker does not
/// offer on many Android browsers. The picked bytes then go through the shared
/// pure-Dart JPEG compression in [encodeProof].
Future<String?> pickProofPhoto(BuildContext context) async {
  final camera = await showModalBottomSheet<bool>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(CupertinoIcons.camera),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(context, true),
          ),
          ListTile(
            leading: const Icon(CupertinoIcons.photo_on_rectangle),
            title: const Text('Choose from files'),
            onTap: () => Navigator.pop(context, false),
          ),
        ],
      ),
    ),
  );
  if (camera == null) return null;

  final bytes = await _pickImageBytes(camera: camera);
  if (bytes == null) return null;
  return encodeProof(bytes);
}

/// Opens a hidden file input and resolves with the selected file's bytes, or
/// null when the picker is cancelled. When [camera] is true the input carries
/// `capture="environment"` so a phone/tablet opens its rear camera.
Future<Uint8List?> _pickImageBytes({required bool camera}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*';
  if (camera) input.capture = 'environment';
  // Older mobile browsers only open the picker for elements that are in the
  // document, so keep it attached but invisible until the pick settles.
  input.style.display = 'none';
  web.document.body?.appendChild(input);

  final completer = Completer<Uint8List?>();
  var settled = false;
  void finish(Uint8List? bytes) {
    if (settled) return;
    settled = true;
    input.remove();
    completer.complete(bytes);
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      final file = (files == null || files.length == 0) ? null : files.item(0);
      if (file == null) {
        finish(null);
        return;
      }
      file
          .arrayBuffer()
          .toDart
          .then((buffer) {
            finish(buffer.toDart.asUint8List());
          })
          .catchError((Object _) {
            finish(null);
          });
    }).toJS,
  );

  // Cancelling a native picker fires no `change` event. The window regains
  // focus when the picker closes, so check shortly after that and settle with
  // null if nothing was chosen — otherwise the caller's "picking" flag would
  // stay stuck forever. The delay is generous: on a slow tablet the camera app
  // can take a moment to hand the file back after focus returns.
  void onFocus(web.Event _) {
    web.window.removeEventListener('focus', onFocus.toJS);
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      final files = input.files;
      if (files == null || files.length == 0) finish(null);
    });
  }

  web.window.addEventListener('focus', onFocus.toJS);
  input.click();
  return completer.future;
}

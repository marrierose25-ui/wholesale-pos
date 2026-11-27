// Web (PWA) entry point.
//
// Built with `flutter build web -t lib/main_web.dart` (and run with the same
// `-t`). Keeping the web bootstrap in its OWN entry — separate from the native
// `main.dart` — means the browser compile graph contains no `dart:io`,
// `dart:ffi` (`sqflite_common_ffi`) or `path_provider`, all of which are hard
// *compile-time* failures on the web and cannot be gated by a runtime `kIsWeb`
// check. Native builds keep using `main.dart` unchanged.
//
// This entry constructs the [CloudBackend] (every screen reads/writes the
// `pos-api` Edge Function; browser preferences + the signed session live in
// localStorage) and hands it to the SAME adaptive shell the app uses
// ([PosRoot]). There is no device-license gate here: the browser's tenant
// identity is captured once on the activation step [PosRoot] shows.
import 'package:material_ui/material_ui.dart';

import 'app_shell.dart';
import 'core/backend/app_backend.dart';
import 'core/backend/cloud_backend.dart';
import 'core/backend/web_local_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final backend = CloudBackend();
  // Honour a previously chosen theme on first paint (dark is the flagship
  // look; only an explicit 'light' flips it), read synchronously from the
  // browser so there is no flash on reload.
  final theme = webRead('pos.setting.${AppBackend.themeSettingKey}');

  runApp(PosRoot(backend: backend, initialDarkMode: theme != 'light'));
}

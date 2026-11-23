import 'package:web/web.dart' as web;

/// Minimal browser `localStorage` facade for the web/PWA build.
///
/// Web-only: this file imports `package:web`, so it must never be reached from
/// the native compile graph. It is referenced only by [CloudBackend] and the
/// web auth screens, which the browser entry (`main_web.dart`) wires and
/// `main.dart` never imports.
///
/// It stores only non-secret browser preferences (theme, "stay signed in", the
/// shop activation code, this browser's device id) and the persisted session
/// envelope. The session envelope carries the `pos-api` JWT, which is the
/// browser's sole credential — no Supabase key ever lives here or in the bundle.
String? webRead(String key) => web.window.localStorage.getItem(key);

void webWrite(String key, String value) =>
    web.window.localStorage.setItem(key, value);

void webErase(String key) => web.window.localStorage.removeItem(key);

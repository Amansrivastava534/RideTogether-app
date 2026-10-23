// Browser-only helpers (no-ops on Android/iOS). See web/index.html for the
// JavaScript side.
export 'web_support_stub.dart' if (dart.library.js_interop) 'web_support_web.dart';

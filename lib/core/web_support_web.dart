import 'dart:js_interop';

@JS('rtWakeLock')
external void _wakeLock(JSBoolean on);

/// Keeps the screen on while sharing: iOS stops location in a hidden page.
void setScreenWakeLock(bool on) => _wakeLock(on.toJS);

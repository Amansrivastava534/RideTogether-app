import 'dart:js_interop';

@JS('rtLoadMaps')
external JSPromise<JSAny?> _loadMaps(JSString apiKey);

@JS('rtWakeLock')
external void _wakeLock(JSBoolean on);

/// Loads the Google Maps JavaScript API before the first map is created.
Future<void> loadMapsScript(String apiKey) => _loadMaps(apiKey.toJS).toDart;

/// Keeps the screen on while sharing: iOS stops location in a hidden page.
void setScreenWakeLock(bool on) => _wakeLock(on.toJS);

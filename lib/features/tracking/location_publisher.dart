import 'dart:async';

import '../../domain/models.dart';
import '../../domain/ride_logic.dart';

/// Turns a stream of GPS fixes into throttled backend writes.
///
/// - [PublishPolicy] decides which fixes are worth sending.
/// - At most one write is in flight. While it is pending (e.g. offline, the
///   Firestore SDK holds it until reconnect) newer fixes replace the queued
///   one instead of piling up, so reconnecting sends at most one stale and
///   one current fix, never a backlog.
/// - Fixes never go backwards in time; the backend rules enforce it too.
class LocationPublisher {
  LocationPublisher({
    required this.write,
    required this.batteryPercent,
    this.policy = const PublishPolicy(),
    this.onSent,
    this.onError,
    this.onFix,
  });

  final Future<void> Function(LiveLocation) write;
  final int? Function() batteryPercent;
  final PublishPolicy policy;
  final void Function(LiveLocation)? onSent;
  final void Function(LiveLocation)? onFix;
  final void Function(Object error)? onError;

  StreamSubscription<LiveLocation>? _sub;
  LiveLocation? _accepted; // newest fix chosen for sending
  LiveLocation? _queued;
  bool _inFlight = false;
  LiveLocation? lastSent;

  bool get isRunning => _sub != null;

  void start(Stream<LiveLocation> fixes) {
    if (_sub != null) return;
    _sub = fixes.listen(_onFix, onError: (Object e) => onError?.call(e));
  }

  /// Cancels the GPS subscription. With geolocator this also stops the
  /// Android foreground service / iOS background updates.
  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    _queued = null;
    await s?.cancel();
  }

  void _onFix(LiveLocation fix) {
    onFix?.call(fix);
    if (!policy.shouldPublish(fix: fix, lastSent: _accepted, batteryPercent: batteryPercent())) return;
    _accepted = fix;
    _queued = fix;
    _drain();
  }

  Future<void> _drain() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      while (_queued != null && _sub != null) {
        final next = _queued!;
        _queued = null;
        try {
          await write(next);
          lastSent = next;
          onSent?.call(next);
        } catch (e) {
          onError?.call(e);
        }
      }
    } finally {
      _inFlight = false;
    }
  }
}

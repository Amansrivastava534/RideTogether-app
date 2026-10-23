import 'dart:math' as math;

import '../core/geo.dart';
import 'models.dart';

/// Tunables in one place. All thresholds are approximate by nature.
abstract final class RideConfig {
  /// Above this speed (m/s, ~5.4 km/h) a rider counts as moving.
  static const movingSpeedMps = 1.5;

  /// No update for this long → "Location unavailable" (shown greyed).
  static const staleAfter = Duration(seconds: 45);

  /// No update for this long → "Last seen …", treated as offline.
  static const offlineAfter = Duration(minutes: 3);

  /// Fixes worse than this are not used for group/fall-behind maths.
  static const maxUsableAccuracyM = 100.0;

  /// A rider must be beyond the threshold this long before we alert.
  static const fallBehindDwell = Duration(seconds: 60);

  /// Hysteresis: alert clears once back within this fraction of threshold.
  static const fallBehindClearRatio = 0.8;

  /// Fall-behind needs at least this many usable riders to mean anything.
  static const minRidersForSpread = 3;

  static const inviteValidity = Duration(hours: 24);

  /// Retention (enforced by Firestore TTL on `expireAt`).
  static const liveLocationTtl = Duration(hours: 24);
  static const rideDataTtl = Duration(days: 30);
  static const historyTtl = Duration(days: 90);
  static const alertTtl = Duration(days: 7);
}

enum RiderStatus { moving, stationary, paused, stale, offline, noLocation }

extension RiderStatusLabel on RiderStatus {
  String get label => switch (this) {
    RiderStatus.moving => 'Moving',
    RiderStatus.stationary => 'Stopped',
    RiderStatus.paused => 'Sharing paused',
    RiderStatus.stale => 'Location unavailable',
    RiderStatus.offline => 'Offline',
    RiderStatus.noLocation => 'Not sharing',
  };

  /// Whether the marker can be presented as a live position.
  bool get isLive => this == RiderStatus.moving || this == RiderStatus.stationary;
}

RiderStatus statusOf(LiveLocation? loc, DateTime now) {
  if (loc == null) return RiderStatus.noLocation;
  if (!loc.sharing) return RiderStatus.paused;
  final age = now.difference(loc.updatedAt);
  if (age > RideConfig.offlineAfter) return RiderStatus.offline;
  if (age > RideConfig.staleAfter) return RiderStatus.stale;
  return (loc.speed ?? 0) >= RideConfig.movingSpeedMps ? RiderStatus.moving : RiderStatus.stationary;
}

String ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inSeconds < 10) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds}s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

// ---------------------------------------------------------------------------
// Membership. The backend (Firestore rules) is the real authority; these are
// mirrored on the client only to pick the right UI.

bool canViewLocations(RideMember? me) => me != null && me.isActive;

bool canPublishLocation(RideMember? me, Ride ride) => canViewLocations(me) && !ride.isEnded;

MemberStatus initialJoinStatus({required bool requireApproval}) =>
    requireApproval ? MemberStatus.pending : MemberStatus.active;

/// Crockford-ish alphabet: no 0/O/1/I/L to avoid read-aloud mistakes.
const inviteAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
const inviteCodeLength = 8;

/// 31^8 ≈ 8.5e11 codes. Pass `Random.secure()` in production.
String generateInviteCode(math.Random rng) => String.fromCharCodes(
  List.generate(inviteCodeLength, (_) => inviteAlphabet.codeUnitAt(rng.nextInt(inviteAlphabet.length))),
);

/// Normalises user-typed codes ("abcd-2345 " → "ABCD2345"); null if invalid.
String? normalizeInviteCode(String input) {
  final c = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (c.length != inviteCodeLength) return null;
  return c.split('').every(inviteAlphabet.contains) ? c : null;
}

/// Extracts a code from a pasted invite link like https://…/j/ABCD2345.
String? inviteCodeFromText(String text) {
  final m = RegExp(r'/j/([A-Za-z0-9]{8})').firstMatch(text);
  return normalizeInviteCode(m?.group(1) ?? text);
}

// ---------------------------------------------------------------------------
// Group spread.

class RiderSpread {
  const RiderSpread({required this.distanceFromGroupM, this.alongTrackM});

  /// Straight-line distance from the group's median position.
  final double distanceFromGroupM;

  /// Signed distance along the group's direction of travel; negative means
  /// behind. Null when the group heading is unknown.
  final double? alongTrackM;
}

/// Usable = live status and decent accuracy.
Map<String, LiveLocation> usableLocations(Iterable<LiveLocation> locs, DateTime now) => {
  for (final l in locs)
    if (statusOf(l, now).isLive && l.accuracy <= RideConfig.maxUsableAccuracyM) l.uid: l,
};

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// Circular mean of the headings of moving riders, null if none.
double? groupHeading(Iterable<LiveLocation> locs) {
  var x = 0.0, y = 0.0, n = 0;
  for (final l in locs) {
    final h = l.heading;
    if (h == null || (l.speed ?? 0) < RideConfig.movingSpeedMps) continue;
    x += math.sin(h * math.pi / 180);
    y += math.cos(h * math.pi / 180);
    n++;
  }
  if (n == 0 || (x.abs() < 1e-9 && y.abs() < 1e-9)) return null;
  return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
}

/// Spread of each usable rider relative to the group median. The median (not
/// mean) keeps one far-off rider from dragging the "group" towards them.
Map<String, RiderSpread> groupSpread(Map<String, LiveLocation> usable) {
  if (usable.length < 2) return const {};
  final median = Coord(
    _median([for (final l in usable.values) l.point.lat]),
    _median([for (final l in usable.values) l.point.lng]),
  );
  final heading = groupHeading(usable.values);
  return {
    for (final MapEntry(:key, :value) in usable.entries)
      key: RiderSpread(
        distanceFromGroupM: distanceMeters(median, value.point),
        alongTrackM: heading == null ? null : _alongTrack(median, value.point, heading),
      ),
  };
}

double _alongTrack(Coord origin, Coord p, double headingDeg) {
  final o = offsetMeters(origin, p);
  final h = headingDeg * math.pi / 180;
  return o.east * math.sin(h) + o.north * math.cos(h);
}

/// Flags riders far from the group, with safeguards against GPS noise:
/// needs ≥3 usable riders, a sustained dwell above threshold, and hysteresis
/// before clearing. Never infers a crash — it only reports distance.
class FallBehindDetector {
  final _farSince = <String, DateTime>{};
  final _flagged = <String>{};

  Set<String> get flagged => Set.unmodifiable(_flagged);

  /// Returns riders newly flagged on this evaluation.
  Set<String> update(Map<String, RiderSpread> spread, double thresholdM, DateTime now) {
    final newly = <String>{};
    if (spread.length < RideConfig.minRidersForSpread) {
      _farSince.clear();
      _flagged.clear();
      return newly;
    }
    _farSince.removeWhere((uid, _) => !spread.containsKey(uid));
    _flagged.removeWhere((uid) => !spread.containsKey(uid));
    for (final MapEntry(key: uid, value: s) in spread.entries) {
      final d = s.distanceFromGroupM;
      if (_flagged.contains(uid)) {
        if (d < thresholdM * RideConfig.fallBehindClearRatio) {
          _flagged.remove(uid);
          _farSince.remove(uid);
        }
      } else if (d >= thresholdM) {
        final since = _farSince.putIfAbsent(uid, () => now);
        if (now.difference(since) >= RideConfig.fallBehindDwell) {
          _flagged.add(uid);
          newly.add(uid);
        }
      } else {
        _farSince.remove(uid);
      }
    }
    return newly;
  }
}

// ---------------------------------------------------------------------------
// Adaptive publishing policy: how often a device writes its location.

class PublishPolicy {
  const PublishPolicy({
    this.movingInterval = const Duration(seconds: 4),
    this.stationaryInterval = const Duration(seconds: 15),
    this.heartbeat = const Duration(seconds: 30),
    this.minMoveM = 10,
    this.lowBatteryFactor = 2.5,
    this.lowBatteryPercent = 20,
  });

  final Duration movingInterval;
  final Duration stationaryInterval;

  /// Always write at least this often so peers know we're still here.
  final Duration heartbeat;
  final double minMoveM;
  final double lowBatteryFactor;
  final int lowBatteryPercent;

  bool shouldPublish({required LiveLocation fix, required LiveLocation? lastSent, required int? batteryPercent}) {
    if (lastSent == null) return true;
    // Never send an older fix than one already sent.
    if (!fix.clientTs.isAfter(lastSent.clientTs)) return false;
    final low = batteryPercent != null && batteryPercent <= lowBatteryPercent;
    Duration scale(Duration d) => low ? d * lowBatteryFactor : d;
    final elapsed = fix.clientTs.difference(lastSent.clientTs);
    // Heartbeat is not scaled: it must stay below RideConfig.staleAfter.
    if (elapsed >= heartbeat) return true;
    // Poor fixes only go out on heartbeat; don't spam jittery positions.
    if (fix.accuracy > RideConfig.maxUsableAccuracyM) return false;
    final moving = (fix.speed ?? 0) >= RideConfig.movingSpeedMps;
    final interval = scale(moving ? movingInterval : stationaryInterval);
    final moved = distanceMeters(lastSent.point, fix.point) >= math.max(minMoveM, fix.accuracy);
    return elapsed >= interval && (moved || moving);
  }
}

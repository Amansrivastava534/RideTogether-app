import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/geo.dart';
import '../../core/web_support.dart';
import '../../domain/models.dart';
import '../../providers.dart';
import 'location_publisher.dart';

enum SharingPhase { off, sharing, paused }

enum LocationAccess { granted, denied, deniedForever, serviceDisabled }

class TrackingState {
  const TrackingState({this.rideId, this.phase = SharingPhase.off, this.lastFix, this.lastSentAt, this.error});
  final String? rideId;
  final SharingPhase phase;
  final LiveLocation? lastFix;
  final DateTime? lastSentAt;
  final String? error;

  bool get isSharing => phase == SharingPhase.sharing;

  TrackingState copyWith({
    String? rideId,
    SharingPhase? phase,
    LiveLocation? lastFix,
    DateTime? lastSentAt,
    String? error,
    bool clearError = false,
  }) => TrackingState(
    rideId: rideId ?? this.rideId,
    phase: phase ?? this.phase,
    lastFix: lastFix ?? this.lastFix,
    lastSentAt: lastSentAt ?? this.lastSentAt,
    error: clearError ? null : error ?? this.error,
  );
}

// Prefs keys for active-ride recovery. Only the latest fix is cached locally.
const _kActiveRide = 'activeRideId';
const _kWasSharing = 'wasSharing';
const _kLastFix = 'lastFix';
String _kRoute(String rideId) => 'route_$rideId';

/// Owns the GPS subscription for the whole app (not tied to any screen), so
/// navigating away never silently keeps or kills tracking.
class TrackingController extends Notifier<TrackingState> {
  LocationPublisher? _publisher;
  final _battery = Battery();
  int? _batteryPercent;
  Timer? _batteryTimer;
  StreamSubscription<Object?>? _guard;
  final _route = <Coord>[];

  @override
  TrackingState build() {
    ref.onDispose(_shutdownGps);
    final p = ref.read(prefsProvider);
    final cached = p.getString(_kLastFix);
    return TrackingState(rideId: p.getString(_kActiveRide), lastFix: cached == null ? null : _decodeFix(cached));
  }

  bool get wasSharing => ref.read(prefsProvider).getBool(_kWasSharing) ?? false;

  Future<LocationAccess> checkAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    return _map(await Geolocator.checkPermission());
  }

  /// Foreground ("while in use") permission only. Background delivery comes
  /// from the Android foreground service / iOS background mode started while
  /// the app is in use, so ACCESS_BACKGROUND_LOCATION / "Always" is not needed.
  Future<LocationAccess> requestAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    return _map(await Geolocator.requestPermission());
  }

  LocationAccess _map(LocationPermission p) => switch (p) {
    LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
    LocationPermission.deniedForever => LocationAccess.deniedForever,
    _ => LocationAccess.denied,
  };

  /// Marks [rideId] as the active ride (for "Resume" after restart) without
  /// starting GPS.
  /// Only one ride can be active; switching stops sharing in the old one.
  Future<void> setActiveRide(String rideId) async {
    if (state.rideId == rideId) return;
    if (state.phase != SharingPhase.off) await stopSharing();
    ref.read(prefsProvider).setString(_kActiveRide, rideId);
    state = TrackingState(rideId: rideId, lastFix: state.lastFix);
  }

  Future<void> startSharing(String rideId) async {
    if (await checkAccess() != LocationAccess.granted) {
      state = state.copyWith(error: 'Location permission is required to share your location.');
      return;
    }
    await setActiveRide(rideId);
    final uid = ref.read(authUserProvider).value?.uid;
    if (uid == null || (_publisher?.isRunning ?? false)) return;
    final repo = ref.read(rideRepoProvider);
    final prefs = ref.read(prefsProvider);
    _restoreRoute(rideId);

    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(minutes: 2), (_) => _readBattery());
    unawaited(_readBattery());

    final publisher = _publisher = LocationPublisher(
      write: (loc) => repo.publishLocation(rideId, loc),
      batteryPercent: () => _batteryPercent,
      onFix: (fix) {
        state = state.copyWith(lastFix: fix);
      },
      onSent: (loc) {
        state = state.copyWith(lastSentAt: DateTime.now(), clearError: true);
        prefs.setString(_kLastFix, _encodeFix(loc));
        _record(rideId, loc);
      },
      onError: (e) {
        // Never log coordinates; only the error kind.
        dev.log('location error: ${e.runtimeType} ${e is FirebaseException ? e.code : ''}', name: 'tracking');
        if (e is FirebaseException && e.code == 'permission-denied') {
          // Removed from ride / ride ended: backend refuses, so stop for real.
          unawaited(stopSharing(deleteLocation: false));
          state = state.copyWith(error: 'You can no longer share in this ride.');
        } else if (e is LocationServiceDisabledException) {
          state = state.copyWith(error: 'Location services are off. Turn on GPS to keep sharing.');
        } else if (e is PermissionDeniedException) {
          unawaited(stopSharing(deleteLocation: false));
          state = state.copyWith(error: 'Location permission was revoked.');
        } else {
          state = state.copyWith(error: 'Having trouble updating your location. Retrying…');
        }
      },
    );
    publisher.start(_positions(uid, rideId));
    setScreenWakeLock(true);
    prefs.setBool(_kWasSharing, true);
    state = state.copyWith(phase: SharingPhase.sharing, clearError: true);

    // Stop GPS by itself if the ride ends or we are removed, even when no
    // screen is open.
    // (Writes would also start failing with permission-denied; this is faster.)
    await _guard?.cancel();
    _guard = repo.watchPublishRevoked(rideId, uid).listen((_) => unawaited(stopSharing()));
  }

  /// Pause: GPS off, peers see "Sharing paused" at the last position.
  Future<void> pauseSharing() async {
    final rideId = state.rideId;
    final last = _publisher?.lastSent;
    await _shutdownGps();
    ref.read(prefsProvider).setBool(_kWasSharing, false);
    state = state.copyWith(phase: SharingPhase.paused);
    if (rideId != null && last != null) {
      await ref
          .read(rideRepoProvider)
          .publishLocation(rideId, last.copyWith(sharing: false, clientTs: DateTime.now()))
          .catchError((Object _) {});
    }
  }

  /// Full stop: GPS off and (by default) our live location document deleted
  /// so peers no longer see it at all.
  Future<void> stopSharing({bool deleteLocation = true}) async {
    final rideId = state.rideId;
    await _shutdownGps();
    ref.read(prefsProvider).setBool(_kWasSharing, false);
    state = state.copyWith(phase: SharingPhase.off);
    final uid = ref.read(authUserProvider).value?.uid;
    if (deleteLocation && rideId != null && uid != null) {
      await ref.read(rideRepoProvider).deleteMyLocation(rideId, uid).catchError((Object _) {});
    }
  }

  /// Stops everything and forgets the active ride. Returns the history
  /// record if the user consented and a route was recorded.
  Future<RideHistory?> finishRide({
    required Ride ride,
    required List<RideMember> members,
    required UserProfile me,
  }) async {
    await stopSharing();
    final prefs = ref.read(prefsProvider);
    RideHistory? history;
    if (me.historyConsent && _route.length >= 2) {
      final route = simplify(_route, 10);
      history = RideHistory(
        rideId: ride.id,
        name: ride.name,
        startedAt: ride.startedAt ?? ride.createdAt ?? DateTime.now(),
        endedAt: ride.endedAt ?? DateTime.now(),
        distanceMeters: pathLengthMeters(_route),
        // Cap document size: ~1500 points ≈ 10 KB encoded.
        route: route.length > 1500
            ? [for (var i = 0; i < route.length; i += route.length ~/ 1500 + 1) route[i]]
            : route,
        participants: [
          for (final m in members)
            if (m.isActive) m.name,
        ],
      );
      await ref.read(userRepoProvider).saveHistory(me.uid, history).catchError((Object _) {});
    }
    _route.clear();
    await prefs.remove(_kRoute(ride.id));
    await prefs.remove(_kActiveRide);
    await prefs.remove(_kLastFix);
    state = const TrackingState();
    return history;
  }

  Future<void> _shutdownGps() async {
    setScreenWakeLock(false);
    _batteryTimer?.cancel();
    _batteryTimer = null;
    await _guard?.cancel();
    _guard = null;
    await _publisher?.stop();
    _publisher = null;
  }

  Future<void> _readBattery() async {
    try {
      _batteryPercent = await _battery.batteryLevel;
    } catch (_) {
      _batteryPercent = null;
    }
  }

  Stream<LiveLocation> _positions(String uid, String rideId) {
    final background = ref.read(settingsProvider).backgroundSharing;
    // Browser (iPhone PWA): watchPosition. Note defaultTargetPlatform is iOS
    // in Safari, so check kIsWeb first.
    final LocationSettings settings = kIsWeb
        ? const LocationSettings(accuracy: LocationAccuracy.high)
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 3),
              foregroundNotificationConfig: background
                  ? const ForegroundNotificationConfig(
                      notificationTitle: 'Sharing your location with your ride',
                      notificationText: 'Ride members can see you. Stop sharing in the app.',
                      notificationChannelName: 'Live location sharing',
                      enableWakeLock: true,
                      setOngoing: true,
                    )
                  : null,
            ),
            TargetPlatform.iOS => AppleSettings(
              accuracy: LocationAccuracy.high,
              activityType: ActivityType.automotiveNavigation,
              distanceFilter: 0,
              pauseLocationUpdatesAutomatically: false,
              allowBackgroundLocationUpdates: background,
              showBackgroundLocationIndicator: background,
            ),
            _ => const LocationSettings(accuracy: LocationAccuracy.high),
          };
    return Geolocator.getPositionStream(locationSettings: settings).map((p) => positionToLive(uid, p));
  }

  void _record(String rideId, LiveLocation loc) {
    if (!(ref.read(profileProvider).value?.historyConsent ?? false)) return;
    if (loc.accuracy > 50) return;
    _route.add(loc.point);
    if (_route.length % 20 == 0) {
      ref.read(prefsProvider).setString(_kRoute(rideId), encodePolyline(_route));
    }
  }

  void _restoreRoute(String rideId) {
    if (_route.isNotEmpty) return;
    final saved = ref.read(prefsProvider).getString(_kRoute(rideId));
    if (saved != null) _route.addAll(decodePolyline(saved));
  }
}

LiveLocation positionToLive(String uid, Position p) {
  final speed = p.speed >= 0 ? p.speed : null;
  // Bearing is meaningless when (almost) stationary or invalid (<0 on iOS).
  final heading = (p.heading >= 0 && (speed ?? 0) >= 1) ? p.heading : null;
  return LiveLocation(
    uid: uid,
    point: Coord(p.latitude, p.longitude),
    accuracy: p.accuracy,
    speed: speed,
    heading: heading,
    clientTs: p.timestamp,
  );
}

String _encodeFix(LiveLocation l) => jsonEncode({
  'uid': l.uid,
  'lat': l.point.lat,
  'lng': l.point.lng,
  'acc': l.accuracy,
  'ts': l.clientTs.millisecondsSinceEpoch,
});

LiveLocation? _decodeFix(String s) {
  try {
    final m = jsonDecode(s) as Map<String, dynamic>;
    return LiveLocation(
      uid: m['uid'] as String,
      point: Coord((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
      accuracy: (m['acc'] as num).toDouble(),
      clientTs: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
    );
  } catch (_) {
    return null;
  }
}

final trackingProvider = NotifierProvider<TrackingController, TrackingState>(TrackingController.new);

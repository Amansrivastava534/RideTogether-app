import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ridetogether/core/geo.dart';
import 'package:ridetogether/domain/models.dart';
import 'package:ridetogether/domain/ride_logic.dart';

final t0 = DateTime.utc(2026, 10, 23, 10);

LiveLocation loc(
  String uid,
  double lat,
  double lng, {
  DateTime? at,
  double speed = 10,
  double? heading = 0,
  double acc = 8,
  bool sharing = true,
}) => LiveLocation(
  uid: uid,
  point: Coord(lat, lng),
  accuracy: acc,
  speed: speed,
  heading: heading,
  clientTs: at ?? t0,
  serverTs: at ?? t0,
  sharing: sharing,
);

RideMember member(MemberStatus s) => RideMember(uid: 'u', name: 'U', role: MemberRole.member, status: s);

void main() {
  group('distance', () {
    test('Jodhpur → Jaipur is ~ 280 km straight line', () {
      final d = distanceMeters(const Coord(26.2389, 73.0243), const Coord(26.9124, 75.7873));
      expect(d, closeTo(285000, 8000));
    });
    test('zero and symmetric', () {
      const a = Coord(12.97, 77.59), b = Coord(12.98, 77.60);
      expect(distanceMeters(a, a), 0);
      expect(distanceMeters(a, b), closeTo(distanceMeters(b, a), 1e-6));
      expect(distanceMeters(a, b), closeTo(1550, 50));
    });
    test('formatDistance', () {
      expect(formatDistance(420), '420 m');
      expect(formatDistance(1234), '1.2 km');
      expect(formatDistance(25400), '25 km');
    });
  });

  group('polyline', () {
    test('matches Google reference encoding', () {
      const pts = [Coord(38.5, -120.2), Coord(40.7, -120.95), Coord(43.252, -126.453)];
      expect(encodePolyline(pts), '_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), pts);
    });
    test('simplify drops collinear points, keeps corners', () {
      final line = [for (var i = 0; i <= 10; i++) Coord(26 + i * 0.001, 73.0), const Coord(26.01, 73.01)];
      final s = simplify(line, 5);
      expect(s.first, line.first);
      expect(s.last, line.last);
      expect(s.length, 3);
    });
  });

  group('status', () {
    test('null location → noLocation', () => expect(statusOf(null, t0), RiderStatus.noLocation));
    test('paused beats freshness', () {
      expect(statusOf(loc('a', 0, 0, sharing: false), t0), RiderStatus.paused);
    });
    test('moving vs stationary by speed', () {
      expect(statusOf(loc('a', 0, 0, speed: 8), t0), RiderStatus.moving);
      expect(statusOf(loc('a', 0, 0, speed: 0.3), t0), RiderStatus.stationary);
    });
    test('stale and offline thresholds', () {
      final l = loc('a', 0, 0);
      expect(statusOf(l, t0.add(const Duration(seconds: 44))), RiderStatus.moving);
      expect(statusOf(l, t0.add(const Duration(seconds: 46))), RiderStatus.stale);
      expect(statusOf(l, t0.add(const Duration(minutes: 4))), RiderStatus.offline);
      expect(statusOf(l, t0.add(const Duration(minutes: 4))).isLive, isFalse);
    });
    test('ago()', () {
      expect(ago(t0, t0.add(const Duration(seconds: 3))), 'just now');
      expect(ago(t0, t0.add(const Duration(minutes: 5))), '5 min ago');
    });
  });

  group('membership', () {
    test('only active members see locations', () {
      expect(canViewLocations(null), isFalse);
      expect(canViewLocations(member(MemberStatus.pending)), isFalse);
      expect(canViewLocations(member(MemberStatus.removed)), isFalse);
      expect(canViewLocations(member(MemberStatus.active)), isTrue);
    });
    test('no publishing into an ended ride', () {
      Ride ride(RideStatus s) => Ride(id: 'r', name: 'x', ownerId: 'o', code: 'C', requireApproval: true, status: s);
      expect(canPublishLocation(member(MemberStatus.active), ride(RideStatus.active)), isTrue);
      expect(canPublishLocation(member(MemberStatus.active), ride(RideStatus.ended)), isFalse);
    });
    test('join status follows approval setting', () {
      expect(initialJoinStatus(requireApproval: true), MemberStatus.pending);
      expect(initialJoinStatus(requireApproval: false), MemberStatus.active);
    });
    test('invite codes', () {
      final c = generateInviteCode(math.Random.secure());
      expect(c.length, 8);
      expect(normalizeInviteCode(c.toLowerCase()), c);
      expect(normalizeInviteCode('ABCD-2345'), 'ABCD2345');
      expect(normalizeInviteCode('ABCD0345'), isNull, reason: '0 is not in alphabet');
      expect(inviteCodeFromText('Join https://x.web.app/j/ABCD2345 now'), 'ABCD2345');
    });
    test('invitation expiry', () {
      final inv = RideInvitation(code: 'c', rideId: 'r', rideName: 'n', requireApproval: true, expireAt: t0);
      expect(inv.isExpired(t0.subtract(const Duration(seconds: 1))), isFalse);
      expect(inv.isExpired(t0), isTrue);
    });
  });

  group('group spread & fall behind', () {
    // Riders heading north (heading 0) along a meridian; ~111 m per 0.001°.
    Map<String, LiveLocation> riders(double laggardLat, {double acc = 8}) => usableLocations([
      loc('a', 26.100, 73.0),
      loc('b', 26.1005, 73.0),
      loc('c', 26.101, 73.0),
      loc('slow', laggardLat, 73.0, acc: acc),
    ], t0);

    test('laggard is far and behind', () {
      final s = groupSpread(riders(26.06));
      expect(s['slow']!.distanceFromGroupM, greaterThan(4000));
      expect(s['slow']!.alongTrackM, lessThan(0));
      expect(s['c']!.alongTrackM, greaterThan(0));
    });

    test('inaccurate and stale fixes are excluded', () {
      expect(riders(26.06, acc: 500).containsKey('slow'), isFalse);
      final stale = usableLocations([loc('x', 0, 0)], t0.add(const Duration(minutes: 1)));
      expect(stale, isEmpty);
    });

    test('alert needs sustained distance, then clears with hysteresis', () {
      final d = FallBehindDetector();
      final far = groupSpread(riders(26.06));
      expect(d.update(far, 3000, t0), isEmpty, reason: 'single noisy reading');
      expect(d.update(far, 3000, t0.add(const Duration(seconds: 30))), isEmpty);
      expect(d.update(far, 3000, t0.add(const Duration(seconds: 61))), {'slow'});
      expect(d.update(far, 3000, t0.add(const Duration(seconds: 90))), isEmpty, reason: 'not re-alerted');
      // 2.7 km: below threshold but above clear ratio → still flagged.
      final near = groupSpread(riders(26.0755));
      d.update(near, 3000, t0.add(const Duration(seconds: 100)));
      expect(d.flagged, contains('slow'));
      d.update(groupSpread(riders(26.099)), 3000, t0.add(const Duration(seconds: 110)));
      expect(d.flagged, isEmpty);
    });

    test('a brief GPS jump does not alert', () {
      final d = FallBehindDetector();
      d.update(groupSpread(riders(26.06)), 3000, t0);
      d.update(groupSpread(riders(26.0995)), 3000, t0.add(const Duration(seconds: 20)));
      expect(d.update(groupSpread(riders(26.06)), 3000, t0.add(const Duration(seconds: 70))), isEmpty);
    });

    test('two riders are never flagged', () {
      final d = FallBehindDetector();
      final two = groupSpread(usableLocations([loc('a', 26.1, 73), loc('b', 26.0, 73)], t0));
      d.update(two, 3000, t0);
      expect(d.update(two, 3000, t0.add(const Duration(minutes: 5))), isEmpty);
    });
  });

  group('publish policy', () {
    const p = PublishPolicy();
    LiveLocation at(int s, {double lat = 26.1, double speed = 10, double acc = 8}) => loc(
      'me',
      lat,
      73,
      at: t0.add(Duration(seconds: s)),
      speed: speed,
      acc: acc,
    );

    test(
      'first fix always sent',
      () => expect(p.shouldPublish(fix: at(0), lastSent: null, batteryPercent: 80), isTrue),
    );
    test('moving: every ~4 s', () {
      expect(p.shouldPublish(fix: at(2, lat: 26.1003), lastSent: at(0), batteryPercent: 80), isFalse);
      expect(p.shouldPublish(fix: at(4, lat: 26.1004), lastSent: at(0), batteryPercent: 80), isTrue);
    });
    test('low battery stretches interval', () {
      expect(p.shouldPublish(fix: at(5, lat: 26.1005), lastSent: at(0), batteryPercent: 10), isFalse);
      expect(p.shouldPublish(fix: at(10, lat: 26.101), lastSent: at(0), batteryPercent: 10), isTrue);
    });
    test('stationary: only heartbeat', () {
      expect(p.shouldPublish(fix: at(20, speed: 0), lastSent: at(0, speed: 0), batteryPercent: 80), isFalse);
      expect(p.shouldPublish(fix: at(30, speed: 0), lastSent: at(0, speed: 0), batteryPercent: 10), isTrue);
    });
    test('older or equal fix never replaces a newer one', () {
      expect(p.shouldPublish(fix: at(0), lastSent: at(40), batteryPercent: 80), isFalse);
    });
    test('poor accuracy waits for heartbeat', () {
      expect(p.shouldPublish(fix: at(10, lat: 26.11, acc: 300), lastSent: at(0), batteryPercent: 80), isFalse);
      expect(p.shouldPublish(fix: at(31, lat: 26.11, acc: 300), lastSent: at(0), batteryPercent: 80), isTrue);
    });
  });
}

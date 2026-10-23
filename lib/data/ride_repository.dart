import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/models.dart';
import '../domain/ride_logic.dart';

class RideException implements Exception {
  const RideException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Hosting domain serving the /j/<code> invite page (see public/j).
const inviteHost = 'ridetogether-4590.web.app';
String inviteLink(String code) => 'https://$inviteHost/j/$code';

/// All Firestore access for rides. Authorization is enforced server-side by
/// firestore.rules; this class only shapes requests.
class RideRepository {
  RideRepository(this._db, {math.Random? random}) : _rng = random ?? math.Random.secure();

  final FirebaseFirestore _db;
  final math.Random _rng;

  DocumentReference<Map<String, dynamic>> _ride(String id) => _db.collection('rides').doc(id);
  CollectionReference<Map<String, dynamic>> _members(String id) => _ride(id).collection('members');
  CollectionReference<Map<String, dynamic>> _locations(String id) => _ride(id).collection('locations');
  DocumentReference<Map<String, dynamic>> _invite(String code) => _db.collection('invites').doc(code);
  DocumentReference<Map<String, dynamic>> _recent(String uid, String rideId) =>
      _db.collection('users').doc(uid).collection('recentRides').doc(rideId);

  Timestamp _expiry(Duration d) => Timestamp.fromDate(DateTime.now().add(d));

  Map<String, dynamic> _memberMap(UserProfile me, MemberRole role, MemberStatus status, {String? code}) => {
    'name': me.name,
    'photoUrl': me.photoUrl,
    'bikeName': me.bikeName,
    'role': role.name,
    'status': status.name,
    'joinedAt': FieldValue.serverTimestamp(),
    'expireAt': _expiry(RideConfig.rideDataTtl),
    if (code != null) 'inviteCode': code,
  };

  Map<String, dynamic> _inviteMap(String rideId, String name, bool requireApproval, String uid) => {
    'rideId': rideId,
    'rideName': name,
    'requireApproval': requireApproval,
    'createdBy': uid,
    'expireAt': _expiry(RideConfig.inviteValidity),
  };

  Future<String> createRide({required UserProfile me, required String name, required bool requireApproval}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final ref = _db.collection('rides').doc();
      final code = generateInviteCode(_rng);
      final batch = _db.batch()
        ..set(ref, {
          'name': name.trim(),
          'ownerId': me.uid,
          'code': code,
          'requireApproval': requireApproval,
          'status': RideStatus.waiting.name,
          'createdAt': FieldValue.serverTimestamp(),
          'fallBehindMeters': Ride.defaultFallBehindMeters,
          'expireAt': _expiry(RideConfig.rideDataTtl),
        })
        ..set(_members(ref.id).doc(me.uid), _memberMap(me, MemberRole.owner, MemberStatus.active))
        ..set(_invite(code), _inviteMap(ref.id, name.trim(), requireApproval, me.uid))
        ..set(_recent(me.uid, ref.id), {
          'name': name.trim(),
          'joinedAt': FieldValue.serverTimestamp(),
          'expireAt': _expiry(RideConfig.rideDataTtl),
        });
      try {
        await batch.commit();
        return ref.id;
      } on FirebaseException catch (e) {
        // A colliding invite code shows up as permission-denied (no update
        // rule on invites). Astronomically rare; retry with a fresh code.
        if (e.code != 'permission-denied' || attempt == 2) rethrow;
      }
    }
    throw const RideException('Could not create ride');
  }

  Future<RideInvitation> lookupInvite(String code) async {
    final snap = await _invite(code).get();
    if (!snap.exists) throw const RideException('No ride found for that code');
    final inv = RideInvitation.fromMap(code, snap.data()!);
    if (inv.isExpired(DateTime.now())) {
      throw const RideException('This invitation has expired. Ask the ride owner for a new code.');
    }
    return inv;
  }

  /// Returns the rideId. Status (pending/active) is validated by the rules
  /// against the real ride setting.
  Future<String> joinRide(UserProfile me, RideInvitation inv) async {
    final memberRef = _members(inv.rideId).doc(me.uid);
    final existing = await memberRef.get().then((s) => s.exists ? s : null, onError: (_) => null);
    if (existing != null) {
      final m = RideMember.fromMap(me.uid, existing.data()!);
      if (m.status == MemberStatus.removed) {
        throw const RideException('You were removed from this ride by the owner.');
      }
      return inv.rideId;
    }
    try {
      await (_db.batch()
            ..set(
              memberRef,
              _memberMap(
                me,
                MemberRole.member,
                initialJoinStatus(requireApproval: inv.requireApproval),
                code: inv.code,
              ),
            )
            ..set(_recent(me.uid, inv.rideId), {
              'name': inv.rideName,
              'joinedAt': FieldValue.serverTimestamp(),
              'expireAt': _expiry(RideConfig.rideDataTtl),
            }))
          .commit();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw const RideException('Could not join. The ride may have ended or the code was changed.');
      }
      rethrow;
    }
    return inv.rideId;
  }

  Stream<Ride?> watchRide(String id) =>
      _ride(id).snapshots().map((s) => s.exists ? Ride.fromMap(s.id, s.data()!) : null);

  Stream<RideMember?> watchMyMembership(String rideId, String uid) =>
      _members(rideId).doc(uid).snapshots().map((s) => s.exists ? RideMember.fromMap(uid, s.data()!) : null);

  /// Emits once the server confirms we may no longer publish: membership gone
  /// / not active, or the ride ended. Cache-only snapshots are ignored so a
  /// cold cache never looks like a revocation.
  Stream<void> watchPublishRevoked(String rideId, String uid) {
    late final StreamController<void> c;
    final subs = <StreamSubscription<Object?>>[];
    c = StreamController<void>(
      onListen: () {
        subs
          ..add(
            _members(rideId).doc(uid).snapshots().listen((s) {
              if (s.metadata.isFromCache) return;
              if (!s.exists || s.data()?['status'] != MemberStatus.active.name) c.add(null);
            }, onError: (_) => c.add(null)),
          )
          ..add(
            _ride(rideId).snapshots().listen((s) {
              if (s.metadata.isFromCache) return;
              if (s.data()?['status'] == RideStatus.ended.name) c.add(null);
            }, onError: (_) => c.add(null)),
          );
      },
      onCancel: () => Future.wait(subs.map((s) => s.cancel())),
    );
    return c.stream;
  }

  /// Only active members may list members (rules).
  Stream<List<RideMember>> watchMembers(String rideId) => _members(rideId).snapshots().map(
    (q) =>
        [for (final d in q.docs) RideMember.fromMap(d.id, d.data())]
          ..sort((a, b) => (a.joinedAt ?? DateTime(3000)).compareTo(b.joinedAt ?? DateTime(3000))),
  );

  /// Emits locations plus whether the data came from the offline cache.
  Stream<({Map<String, LiveLocation> locations, bool fromCache})> watchLocations(String rideId) => _locations(rideId)
      .snapshots(includeMetadataChanges: true)
      .map(
        (q) => (
          locations: {for (final d in q.docs) d.id: LiveLocation.fromMap(d.id, d.data())},
          fromCache: q.metadata.isFromCache,
        ),
      );

  Stream<List<RideAlert>> watchAlerts(String rideId, DateTime since) => _ride(rideId)
      .collection('alerts')
      .where('createdAt', isGreaterThan: Timestamp.fromDate(since))
      .snapshots()
      .map((q) => [for (final d in q.docs) RideAlert.fromMap(d.id, d.data())]);

  Stream<List<RecentRide>> watchRecentRides(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('recentRides')
      .orderBy('joinedAt', descending: true)
      .limit(10)
      .snapshots()
      .map((q) => [for (final d in q.docs) RecentRide.fromMap(d.id, d.data())]);

  /// Completes when the server acknowledges the write. While offline it stays
  /// pending (the SDK queues it), which the publisher uses for backpressure.
  Future<void> publishLocation(String rideId, LiveLocation loc) => _locations(rideId).doc(loc.uid).set({
    ...loc.toMap(),
    'serverTs': FieldValue.serverTimestamp(),
    'expireAt': _expiry(RideConfig.liveLocationTtl),
  });

  Future<void> deleteMyLocation(String rideId, String uid) => _locations(rideId).doc(uid).delete();

  Future<void> sendSos(String rideId, UserProfile me, LiveLocation? last) => _ride(rideId).collection('alerts').add({
    'type': 'sos',
    'uid': me.uid,
    'name': me.name,
    if (last != null) ...{'lat': last.point.lat, 'lng': last.point.lng},
    'createdAt': FieldValue.serverTimestamp(),
    'expireAt': _expiry(RideConfig.alertTtl),
  });

  // --- owner actions -------------------------------------------------------

  Future<void> startRide(String rideId) =>
      _ride(rideId).update({'status': RideStatus.active.name, 'startedAt': FieldValue.serverTimestamp()});

  Future<void> endRide(String rideId) =>
      _ride(rideId).update({'status': RideStatus.ended.name, 'endedAt': FieldValue.serverTimestamp()});

  Future<void> approve(String rideId, String uid) =>
      _members(rideId).doc(uid).update({'status': MemberStatus.active.name});

  /// Marks removed (not deleted) so the user cannot re-join with the code,
  /// and deletes their live location so peers stop seeing it immediately.
  Future<void> removeMember(String rideId, String uid) =>
      (_db.batch()
            ..update(_members(rideId).doc(uid), {'status': MemberStatus.removed.name})
            ..delete(_locations(rideId).doc(uid)))
          .commit();

  Future<void> updateSettings(Ride ride, {bool? requireApproval, double? fallBehindMeters}) {
    final batch = _db.batch()
      ..update(_ride(ride.id), {'requireApproval': ?requireApproval, 'fallBehindMeters': ?fallBehindMeters});
    if (requireApproval != null) {
      batch.update(_invite(ride.code), {'requireApproval': requireApproval});
    }
    return batch.commit();
  }

  /// Revokes the old code and issues a new one (also renews expiry).
  Future<void> regenerateInvite(Ride ride, String uid) {
    final code = generateInviteCode(_rng);
    return (_db.batch()
          ..delete(_invite(ride.code))
          ..set(_invite(code), _inviteMap(ride.id, ride.name, ride.requireApproval, uid))
          ..update(_ride(ride.id), {'code': code}))
        .commit();
  }

  // --- member actions ------------------------------------------------------

  Future<void> leaveRide(String rideId, String uid) =>
      (_db.batch()
            ..delete(_locations(rideId).doc(uid))
            ..delete(_members(rideId).doc(uid)))
          .commit();
}

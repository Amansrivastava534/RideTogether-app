import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/geo.dart';

DateTime? _date(Object? v) => switch (v) {
  Timestamp t => t.toDate(),
  DateTime d => d,
  _ => null,
};

double? _num(Object? v) => (v as num?)?.toDouble();

class UserProfile {
  const UserProfile({required this.uid, required this.name, this.photoUrl, this.bikeName, this.historyConsent = false});

  final String uid;
  final String name;
  final String? photoUrl;
  final String? bikeName;

  /// User opted in to recording their own route for ride history.
  final bool historyConsent;

  static String? validateName(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Enter your name';
    if (t.length > 40) return 'Max 40 characters';
    return null;
  }

  factory UserProfile.fromMap(String uid, Map<String, dynamic> m) => UserProfile(
    uid: uid,
    name: m['name'] as String? ?? 'Rider',
    photoUrl: m['photoUrl'] as String?,
    bikeName: m['bikeName'] as String?,
    historyConsent: m['historyConsent'] as bool? ?? false,
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'photoUrl': photoUrl,
    'bikeName': bikeName,
    'historyConsent': historyConsent,
  };

  UserProfile copyWith({String? name, String? bikeName, bool? historyConsent}) => UserProfile(
    uid: uid,
    name: name ?? this.name,
    photoUrl: photoUrl,
    bikeName: bikeName ?? this.bikeName,
    historyConsent: historyConsent ?? this.historyConsent,
  );
}

enum RideStatus { waiting, active, ended }

class Ride {
  const Ride({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.code,
    required this.requireApproval,
    required this.status,
    this.createdAt,
    this.startedAt,
    this.endedAt,
    this.fallBehindMeters = defaultFallBehindMeters,
  });

  static const defaultFallBehindMeters = 3000.0;

  final String id;
  final String name;
  final String ownerId;
  final String code;
  final bool requireApproval;
  final RideStatus status;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final double fallBehindMeters;

  bool get isEnded => status == RideStatus.ended;

  static String? validateName(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Give the ride a name';
    if (t.length > 60) return 'Max 60 characters';
    return null;
  }

  factory Ride.fromMap(String id, Map<String, dynamic> m) => Ride(
    id: id,
    name: m['name'] as String? ?? '',
    ownerId: m['ownerId'] as String? ?? '',
    code: m['code'] as String? ?? '',
    requireApproval: m['requireApproval'] as bool? ?? true,
    status: RideStatus.values.asNameMap()[m['status']] ?? RideStatus.waiting,
    createdAt: _date(m['createdAt']),
    startedAt: _date(m['startedAt']),
    endedAt: _date(m['endedAt']),
    fallBehindMeters: _num(m['fallBehindMeters']) ?? defaultFallBehindMeters,
  );
}

enum MemberRole { owner, member }

enum MemberStatus { pending, active, removed }

class RideMember {
  const RideMember({
    required this.uid,
    required this.name,
    required this.role,
    required this.status,
    this.photoUrl,
    this.bikeName,
    this.joinedAt,
  });

  final String uid;
  final String name;
  final String? photoUrl;
  final String? bikeName;
  final MemberRole role;
  final MemberStatus status;
  final DateTime? joinedAt;

  bool get isOwner => role == MemberRole.owner;
  bool get isActive => status == MemberStatus.active;

  factory RideMember.fromMap(String uid, Map<String, dynamic> m) => RideMember(
    uid: uid,
    name: m['name'] as String? ?? 'Rider',
    photoUrl: m['photoUrl'] as String?,
    bikeName: m['bikeName'] as String?,
    role: MemberRole.values.asNameMap()[m['role']] ?? MemberRole.member,
    status: MemberStatus.values.asNameMap()[m['status']] ?? MemberStatus.pending,
    joinedAt: _date(m['joinedAt']),
  );
}

/// Latest known location of one rider. One document per rider per ride;
/// history is never appended here.
class LiveLocation {
  const LiveLocation({
    required this.uid,
    required this.point,
    required this.accuracy,
    required this.clientTs,
    this.speed,
    this.heading,
    this.serverTs,
    this.sharing = true,
  });

  final String uid;
  final Coord point;

  /// Horizontal accuracy radius in metres.
  final double accuracy;

  /// Metres per second, null when the device did not report it.
  final double? speed;

  /// Degrees from north, null when unknown (e.g. stationary).
  final double? heading;

  /// GPS fix time on the sender. Used for ordering (newer wins).
  final DateTime clientTs;

  /// When the backend accepted the write. Used for freshness.
  final DateTime? serverTs;

  /// False when the rider paused sharing; the point is their last position.
  final bool sharing;

  DateTime get updatedAt => serverTs ?? clientTs;

  factory LiveLocation.fromMap(String uid, Map<String, dynamic> m) => LiveLocation(
    uid: uid,
    point: Coord(_num(m['lat']) ?? 0, _num(m['lng']) ?? 0),
    accuracy: _num(m['accuracy']) ?? 9999,
    speed: _num(m['speed']),
    heading: _num(m['heading']),
    clientTs: _date(m['clientTs']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    serverTs: _date(m['serverTs']),
    sharing: m['sharing'] as bool? ?? true,
  );

  /// [serverTs] is set by the repository with FieldValue.serverTimestamp().
  Map<String, dynamic> toMap() => {
    'lat': point.lat,
    'lng': point.lng,
    'accuracy': accuracy,
    'speed': speed,
    'heading': heading,
    'clientTs': Timestamp.fromDate(clientTs),
    'sharing': sharing,
  };

  LiveLocation copyWith({bool? sharing, DateTime? clientTs}) => LiveLocation(
    uid: uid,
    point: point,
    accuracy: accuracy,
    speed: speed,
    heading: heading,
    clientTs: clientTs ?? this.clientTs,
    serverTs: serverTs,
    sharing: sharing ?? this.sharing,
  );
}

class RideInvitation {
  const RideInvitation({
    required this.code,
    required this.rideId,
    required this.rideName,
    required this.requireApproval,
    required this.expireAt,
  });

  final String code;
  final String rideId;
  final String rideName;
  final bool requireApproval;
  final DateTime expireAt;

  bool isExpired(DateTime now) => !now.isBefore(expireAt);

  factory RideInvitation.fromMap(String code, Map<String, dynamic> m) => RideInvitation(
    code: code,
    rideId: m['rideId'] as String? ?? '',
    rideName: m['rideName'] as String? ?? '',
    requireApproval: m['requireApproval'] as bool? ?? true,
    expireAt: _date(m['expireAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
}

class RideAlert {
  const RideAlert({required this.id, required this.uid, required this.name, required this.point, this.createdAt});

  final String id;
  final String uid;
  final String name;
  final Coord? point;
  final DateTime? createdAt;

  factory RideAlert.fromMap(String id, Map<String, dynamic> m) => RideAlert(
    id: id,
    uid: m['uid'] as String? ?? '',
    name: m['name'] as String? ?? 'A rider',
    point: m['lat'] == null ? null : Coord(_num(m['lat'])!, _num(m['lng'])!),
    createdAt: _date(m['createdAt']),
  );
}

class RideHistory {
  const RideHistory({
    required this.rideId,
    required this.name,
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.route,
    required this.participants,
  });

  final String rideId;
  final String name;
  final DateTime startedAt;
  final DateTime endedAt;
  final double distanceMeters;

  /// Simplified route of the current user only.
  final List<Coord> route;
  final List<String> participants;

  Duration get duration => endedAt.difference(startedAt);
  Coord? get start => route.isEmpty ? null : route.first;
  Coord? get end => route.isEmpty ? null : route.last;

  factory RideHistory.fromMap(String id, Map<String, dynamic> m) => RideHistory(
    rideId: id,
    name: m['name'] as String? ?? '',
    startedAt: _date(m['startedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    endedAt: _date(m['endedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    distanceMeters: _num(m['distanceMeters']) ?? 0,
    route: decodePolyline(m['polyline'] as String? ?? ''),
    participants: List<String>.from(m['participants'] as List? ?? const []),
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'startedAt': Timestamp.fromDate(startedAt),
    'endedAt': Timestamp.fromDate(endedAt),
    'distanceMeters': distanceMeters,
    'polyline': encodePolyline(route),
    'participants': participants,
  };
}

class RecentRide {
  const RecentRide({required this.rideId, required this.name, this.joinedAt});
  final String rideId;
  final String name;
  final DateTime? joinedAt;

  factory RecentRide.fromMap(String id, Map<String, dynamic> m) =>
      RecentRide(rideId: id, name: m['name'] as String? ?? '', joinedAt: _date(m['joinedAt']));
}

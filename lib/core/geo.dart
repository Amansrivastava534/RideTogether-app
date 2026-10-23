import 'dart:math' as math;

/// Minimal lat/lng value type for domain code. Keeps the domain free of
/// Google Maps / geolocator types so it can be unit tested in isolation.
class Coord {
  const Coord(this.lat, this.lng);
  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) => other is Coord && other.lat == lat && other.lng == lng;
  @override
  int get hashCode => Object.hash(lat, lng);
  @override
  String toString() => 'Coord($lat, $lng)';
}

const double _earthRadiusM = 6371008.8;
double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// Great-circle (haversine) distance in metres. This is straight-line
/// distance, NOT road distance.
double distanceMeters(Coord a, Coord b) {
  final dLat = _rad(b.lat - a.lat);
  final dLng = _rad(b.lng - a.lng);
  final h =
      math.pow(math.sin(dLat / 2), 2) + math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Initial bearing from [a] to [b], degrees clockwise from north, 0..360.
double bearingDegrees(Coord a, Coord b) {
  final y = math.sin(_rad(b.lng - a.lng)) * math.cos(_rad(b.lat));
  final x =
      math.cos(_rad(a.lat)) * math.sin(_rad(b.lat)) -
      math.sin(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.cos(_rad(b.lng - a.lng));
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

/// Local east/north offset of [p] from [origin] in metres (equirectangular;
/// accurate enough for the few-km spans of a group ride).
({double east, double north}) offsetMeters(Coord origin, Coord p) => (
  east: _rad(p.lng - origin.lng) * math.cos(_rad(origin.lat)) * _earthRadiusM,
  north: _rad(p.lat - origin.lat) * _earthRadiusM,
);

/// Sum of segment lengths, skipping nothing. Callers filter bad fixes first.
double pathLengthMeters(List<Coord> pts) {
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += distanceMeters(pts[i - 1], pts[i]);
  }
  return total;
}

/// Ramer–Douglas–Peucker simplification with tolerance in metres.
List<Coord> simplify(List<Coord> pts, double toleranceM) {
  if (pts.length < 3) return List.of(pts);
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (s, e) = stack.removeLast();
    var maxD = 0.0;
    var idx = -1;
    for (var i = s + 1; i < e; i++) {
      final d = _perpendicularMeters(pts[i], pts[s], pts[e]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx != -1 && maxD > toleranceM) {
      keep[idx] = true;
      stack
        ..add((s, idx))
        ..add((idx, e));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

double _perpendicularMeters(Coord p, Coord a, Coord b) {
  final pb = offsetMeters(a, b);
  final pp = offsetMeters(a, p);
  final len2 = pb.east * pb.east + pb.north * pb.north;
  if (len2 == 0) return math.sqrt(pp.east * pp.east + pp.north * pp.north);
  final t = ((pp.east * pb.east + pp.north * pb.north) / len2).clamp(0.0, 1.0);
  final dx = pp.east - t * pb.east;
  final dy = pp.north - t * pb.north;
  return math.sqrt(dx * dx + dy * dy);
}

/// Google encoded polyline format (precision 5).
String encodePolyline(List<Coord> pts) {
  final sb = StringBuffer();
  var pLat = 0, pLng = 0;
  void enc(int v) {
    var x = v < 0 ? ~(v << 1) : v << 1;
    while (x >= 0x20) {
      sb.writeCharCode((0x20 | (x & 0x1f)) + 63);
      x >>= 5;
    }
    sb.writeCharCode(x + 63);
  }

  for (final p in pts) {
    final lat = (p.lat * 1e5).round();
    final lng = (p.lng * 1e5).round();
    enc(lat - pLat);
    enc(lng - pLng);
    pLat = lat;
    pLng = lng;
  }
  return sb.toString();
}

List<Coord> decodePolyline(String s) {
  final out = <Coord>[];
  var i = 0, lat = 0, lng = 0;
  int dec() {
    var shift = 0, result = 0, b = 0;
    do {
      b = s.codeUnitAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (i < s.length) {
    lat += dec();
    lng += dec();
    out.add(Coord(lat / 1e5, lng / 1e5));
  }
  return out;
}

String formatDistance(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';

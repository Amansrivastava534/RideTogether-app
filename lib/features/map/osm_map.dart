import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:url_launcher/url_launcher.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import 'map_camera.dart';

// OpenStreetMap via flutter_map — used on the web, where no Google Maps
// key is available. Free, no key; requires visible attribution and light
// use (fine for a riding group). See https://operations.osmfoundation.org/policies/tiles/

LatLng _ll(Coord c) => LatLng(c.lat, c.lng);

class OsmCamera implements RideCamera {
  OsmCamera(this._c);
  final MapController _c;

  @override
  void moveTo(Coord c, {double? zoom}) => _c.move(_ll(c), zoom ?? _c.camera.zoom);

  @override
  void fit(List<Coord> pts, {required EdgeInsets padding}) {
    if (pts.isEmpty) return;
    if (pts.length == 1) return moveTo(pts.first, zoom: 15);
    _c.fitCamera(CameraFit.coordinates(coordinates: [for (final p in pts) _ll(p)], padding: padding, maxZoom: 17));
  }

  @override
  void zoomBy(double delta) => _c.move(_c.camera.center, _c.camera.zoom + delta);
}

/// One rider on the OSM map.
class OsmRider {
  const OsmRider({
    required this.uid,
    required this.name,
    required this.point,
    required this.live,
    this.heading,
    this.selected = false,
    this.onTap,
  });
  final String uid;
  final String name;
  final Coord point;
  final bool live;
  final double? heading;
  final bool selected;
  final VoidCallback? onTap;
}

/// One shared tile layer. The live map rebuilds every few frames (marker
/// animation, clock); a new TileLayer each time would get a new tile provider
/// and flutter_map would discard in-flight tiles, leaving the map grey.
final _tiles = TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.ridetogether.app',
  maxNativeZoom: 19,
);

class OsmMap extends StatelessWidget {
  const OsmMap({
    super.key,
    this.controller,
    required this.initial,
    this.fitTo = const [],
    this.initialZoom = 13,
    this.riders = const [],
    this.route = const [],
    this.routeColor,
    this.pins = const [],
    this.onMapTap,
    this.onReady,
    this.interactive = true,
    this.attributionBottom = 0,
  });

  final MapController? controller;
  final Coord initial;

  /// If given, the map opens fitted to these points instead of [initial].
  final List<Coord> fitTo;
  final double initialZoom;
  final List<OsmRider> riders;

  /// Optional polyline (ride history).
  final List<Coord> route;
  final Color? routeColor;

  /// Plain pins (e.g. route start/end), with a colour each.
  final List<(Coord, Color)> pins;
  final VoidCallback? onMapTap;
  final VoidCallback? onReady;
  final bool interactive;

  /// Extra bottom inset for the attribution, to keep it visible above overlays.
  final double attributionBottom;

  @override
  Widget build(BuildContext context) => FlutterMap(
    mapController: controller,
    options: MapOptions(
      initialCenter: _ll(initial),
      initialZoom: initialZoom,
      initialCameraFit: fitTo.length < 2
          ? null
          : CameraFit.coordinates(
              coordinates: [for (final p in fitTo) _ll(p)],
              padding: const EdgeInsets.all(32),
              maxZoom: 16,
            ),
      minZoom: 3,
      maxZoom: 19,
      onTap: onMapTap == null ? null : (_, _) => onMapTap!(),
      onMapReady: onReady,
      interactionOptions: InteractionOptions(
        flags: interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none,
      ),
    ),
    children: [
      _tiles,
      if (route.length >= 2)
        PolylineLayer(
          polylines: [
            Polyline(
              points: [for (final p in route) _ll(p)],
              strokeWidth: 5,
              color: routeColor ?? Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      MarkerLayer(
        markers: [
          for (final (c, color) in pins)
            Marker(
              point: _ll(c),
              width: 22,
              height: 22,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
          // Selected rider drawn last = on top.
          for (final r in [...riders]..sort((a, b) => (a.selected ? 1 : 0) - (b.selected ? 1 : 0)))
            Marker(
              point: _ll(r.point),
              width: 64,
              height: 64,
              child: GestureDetector(
                onTap: r.onTap,
                child: _RiderMarker(rider: r),
              ),
            ),
        ],
      ),
      // Required credit; lifted above any overlay (e.g. the ride panel).
      Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: EdgeInsets.only(left: 6, bottom: 6 + attributionBottom),
          child: GestureDetector(
            onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: const Color(0xCCFFFFFF),
              child: const Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 11, color: Colors.black87)),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Same look as the native bitmap markers: coloured disc with initials,
/// white ring, direction arrow when moving; grey + faded when not live.
class _RiderMarker extends StatelessWidget {
  const _RiderMarker({required this.rider});
  final OsmRider rider;

  @override
  Widget build(BuildContext context) {
    final fill = rider.live ? riderColor(rider.uid) : const Color(0xFF9E9E9E);
    return Opacity(
      opacity: rider.live ? 1 : 0.65,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (rider.heading != null)
            Transform.rotate(
              angle: rider.heading! * math.pi / 180,
              child: Align(
                alignment: Alignment.topCenter,
                child: CustomPaint(size: const Size(18, 14), painter: _ArrowPainter(fill)),
              ),
            ),
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: rider.selected ? 4 : 3),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1.5))],
            ),
            child: Text(
              initials(rider.name),
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(s.width / 2, 0)
      ..lineTo(0, s.height)
      ..lineTo(s.width, s.height)
      ..close();
    canvas
      ..drawPath(path, Paint()..color = color)
      ..drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

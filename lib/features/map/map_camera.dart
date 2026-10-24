import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/geo.dart';

/// Camera moves the live map needs, so it can run on Google Maps
/// (Android/iOS) or OpenStreetMap (web) without caring which.
abstract interface class RideCamera {
  void moveTo(Coord c, {double? zoom});
  void fit(List<Coord> pts, {required EdgeInsets padding});
  void zoomBy(double delta);
}

class GoogleCamera implements RideCamera {
  GoogleCamera(this._c);
  final GoogleMapController _c;

  @override
  void moveTo(Coord c, {double? zoom}) => _c.animateCamera(
    zoom == null
        ? CameraUpdate.newLatLng(LatLng(c.lat, c.lng))
        : CameraUpdate.newLatLngZoom(LatLng(c.lat, c.lng), zoom),
  );

  /// Google applies the map's own padding (set on the widget), so only a
  /// uniform margin is used here.
  @override
  void fit(List<Coord> pts, {required EdgeInsets padding}) {
    if (pts.isEmpty) return;
    if (pts.length == 1) return moveTo(pts.first, zoom: 14);
    _c.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(pts.map((p) => p.lat).reduce(math.min), pts.map((p) => p.lng).reduce(math.min)),
          northeast: LatLng(pts.map((p) => p.lat).reduce(math.max), pts.map((p) => p.lng).reduce(math.max)),
        ),
        72,
      ),
    );
  }

  @override
  void zoomBy(double delta) => _c.animateCamera(CameraUpdate.zoomBy(delta));
}

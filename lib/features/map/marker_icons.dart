import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/ui.dart';

/// Renders rider markers: coloured disc with initials, plus a direction
/// arrow when a GPS bearing is known. Non-live riders are drawn grey.
/// Icons are cached per (rider, live, 15° heading bucket).
class MarkerIcons {
  final _cache = <String, BitmapDescriptor>{};
  final _inflight = <String, Future<BitmapDescriptor>>{};

  static const _size = 64.0; // logical px, includes arrow margin

  BitmapDescriptor? cached(String key) => _cache[key];

  static String keyFor(String uid, String name, {required bool live, double? heading}) =>
      '$uid|$name|$live|${heading == null ? '-' : ((heading / 15).round() * 15) % 360}';

  Future<BitmapDescriptor> get(String uid, String name, {required bool live, double? heading, required double dpr}) {
    final key = keyFor(uid, name, live: live, heading: heading);
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    return _inflight[key] ??=
        _render(uid, name, live, heading == null ? null : ((heading / 15).round() * 15) % 360, dpr).then((b) {
          _inflight.remove(key);
          return _cache[key] = b;
        });
  }

  Future<BitmapDescriptor> _render(String uid, String name, bool live, num? heading, double dpr) async {
    final px = _size * dpr;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec)..scale(dpr);
    const center = Offset(_size / 2, _size / 2);
    const r = 19.0;
    final fill = live ? riderColor(uid) : const Color(0xFF9E9E9E);

    if (heading != null) {
      c.save();
      c.translate(center.dx, center.dy);
      c.rotate(heading * math.pi / 180);
      final arrow = Path()
        ..moveTo(0, -r - 11)
        ..lineTo(-8, -r + 1)
        ..lineTo(8, -r + 1)
        ..close();
      c.drawPath(arrow, Paint()..color = fill);
      c.drawPath(
        arrow,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      c.restore();
    }
    c.drawCircle(
      center + const Offset(0, 1.5),
      r + 3,
      Paint()
        ..color = Colors.black26
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    c.drawCircle(center, r + 3, Paint()..color = Colors.white);
    c.drawCircle(center, r, Paint()..color = fill);
    final tp = TextPainter(
      text: TextSpan(
        text: initials(name),
        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));

    final img = await rec.endRecording().toImage(px.round(), px.round());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), imagePixelRatio: dpr);
  }
}

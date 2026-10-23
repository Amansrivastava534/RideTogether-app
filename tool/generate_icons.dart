// Generates the launcher icons (orange background, white bike) for Android
// and iOS from the Material "two_wheeler" glyph — the same bike as the splash.
//
//   flutter test tool/generate_icons.dart
//
// Then strip alpha from the iOS PNGs (App Store rejects alpha) — see README.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ridetogether/core/splash.dart';

const _bg = splashColor;

Future<void> _loadIconFont() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  final font = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
  await loader.load();
}

/// [glyph] is the bike's size as a fraction of the canvas; [radius] the corner
/// radius fraction (0 = square, null = transparent background).
Future<void> _render(String path, int px, {required double glyph, double? radius}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final s = px.toDouble();
  if (radius != null) {
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * radius)), Paint()..color = _bg);
  }
  final tp = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(Icons.two_wheeler.codePoint),
      style: TextStyle(fontFamily: 'MaterialIcons', fontSize: s * glyph, color: Colors.white, height: 1),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, Offset((s - tp.width) / 2, (s - tp.height) / 2));
  final img = await rec.endRecording().toImage(px, px);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  testWidgets('generate launcher icons', (tester) async {
    await tester.runAsync(() async {
      await _loadIconFont();
      const res = 'android/app/src/main/res';
      const densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
      for (final MapEntry(key: d, value: k) in densities.entries) {
        // Legacy (API < 26): rounded orange square, 48 dp.
        await _render('$res/mipmap-$d/ic_launcher.png', (48 * k).round(), glyph: 0.66, radius: 0.22);
        // Adaptive foreground (108 dp, transparent): bike inside the 66 dp safe zone.
        await _render('$res/mipmap-$d/ic_launcher_foreground.png', (108 * k).round(), glyph: 0.5);
      }
      // iOS: full-bleed square (the OS applies the mask).
      const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      const sizes = {
        '20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60, '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87, //
        '40x40@1x': 40, '40x40@2x': 80, '40x40@3x': 120, '60x60@2x': 120, '60x60@3x': 180, //
        '76x76@1x': 76, '76x76@2x': 152, '83.5x83.5@2x': 167, '1024x1024@1x': 1024,
      };
      for (final MapEntry(key: name, value: px) in sizes.entries) {
        await _render('$ios/Icon-App-$name.png', px, glyph: 0.66, radius: 0);
      }
      // Web / PWA (iPhone "Add to Home Screen" uses apple-touch-icon).
      await _render('web/icons/apple-touch-icon.png', 180, glyph: 0.66, radius: 0);
      await _render('web/icons/Icon-192.png', 192, glyph: 0.66, radius: 0.22);
      await _render('web/icons/Icon-512.png', 512, glyph: 0.66, radius: 0.22);
      // Maskable: full bleed, bike inside the 80% safe circle.
      await _render('web/icons/Icon-maskable-192.png', 192, glyph: 0.5, radius: 0);
      await _render('web/icons/Icon-maskable-512.png', 512, glyph: 0.5, radius: 0);
      await _render('web/favicon.png', 32, glyph: 0.78, radius: 0.22);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ridetogether/core/splash.dart';

void main() {
  Widget app(bool ready) => MaterialApp(
    home: SplashOverlay(
      ready: ready,
      child: const Scaffold(body: Text('home')),
    ),
  );

  testWidgets('stays until ready, then fades out and releases taps', (tester) async {
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(seconds: 3)); // intro done, still loading
    expect(find.text('RideTogether'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'slow start shows progress');

    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(find.text('RideTogether'), findsNothing, reason: 'overlay removed');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('covers the whole screen', (tester) async {
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(milliseconds: 500));
    final splash = find.byWidgetPredicate((w) => w is Material && w.color == splashColor);
    expect(tester.getSize(splash), tester.view.physicalSize / tester.view.devicePixelRatio);
  });

  testWidgets('never hides before the intro finishes, even if ready at once', (tester) async {
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('RideTogether'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('RideTogether'), findsNothing);
  });
}

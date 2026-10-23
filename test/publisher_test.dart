import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridetogether/core/geo.dart';
import 'package:ridetogether/domain/models.dart';
import 'package:ridetogether/features/tracking/location_publisher.dart';

final t0 = DateTime.utc(2026, 10, 23, 10);

LiveLocation fix(int s, {double lat = 26.1}) => LiveLocation(
  uid: 'me',
  point: Coord(lat + s * 0.0002, 73),
  accuracy: 5,
  speed: 10,
  clientTs: t0.add(Duration(seconds: s)),
);

void main() {
  test('one write in flight; offline backlog collapses to latest fix', () async {
    final gps = StreamController<LiveLocation>();
    final writes = <LiveLocation>[];
    var gate = Completer<void>();
    final p = LocationPublisher(
      write: (l) {
        writes.add(l);
        return gate.future; // stays pending, like an offline Firestore write
      },
      batteryPercent: () => 90,
    )..start(gps.stream);

    for (var s = 0; s <= 40; s += 4) {
      gps.add(fix(s));
    }
    await pumpEventQueue();
    expect(writes.map((w) => w.clientTs), [t0], reason: 'only the first write is in flight');

    gate.complete(); // reconnect
    gate = Completer<void>()..complete();
    await pumpEventQueue();
    expect(writes.length, 2);
    expect(writes.last.clientTs, t0.add(const Duration(seconds: 40)), reason: 'latest, not backlog');
    expect(p.lastSent, writes.last);
    await p.stop();
  });

  test('older fixes never replace newer ones', () async {
    final gps = StreamController<LiveLocation>();
    final writes = <DateTime>[];
    final p = LocationPublisher(write: (l) async => writes.add(l.clientTs), batteryPercent: () => 90)
      ..start(gps.stream);
    gps
      ..add(fix(10))
      ..add(fix(5))
      ..add(fix(14));
    await pumpEventQueue();
    expect(writes, [t0.add(const Duration(seconds: 10)), t0.add(const Duration(seconds: 14))]);
    await p.stop();
  });

  test('stop() cancels the GPS subscription and drops queued writes', () async {
    final gps = StreamController<LiveLocation>();
    final gate = Completer<void>();
    var count = 0;
    final p = LocationPublisher(
      write: (_) {
        count++;
        return gate.future;
      },
      batteryPercent: () => null,
    )..start(gps.stream);
    gps.add(fix(0));
    await pumpEventQueue();
    gps.add(fix(8));
    await pumpEventQueue();
    expect(gps.hasListener, isTrue);

    await p.stop();
    expect(gps.hasListener, isFalse, reason: 'GPS stream really cancelled');
    expect(p.isRunning, isFalse);
    gate.complete();
    await pumpEventQueue();
    expect(count, 1, reason: 'queued fix not sent after stop');
  });

  test('write errors are reported and publishing continues', () async {
    final gps = StreamController<LiveLocation>();
    final errors = <Object>[];
    var n = 0;
    final p = LocationPublisher(
      write: (_) async {
        if (n++ == 0) throw StateError('unavailable');
      },
      batteryPercent: () => 90,
      onError: errors.add,
    )..start(gps.stream);
    gps.add(fix(0));
    await pumpEventQueue();
    gps.add(fix(5));
    await pumpEventQueue();
    expect(errors, hasLength(1));
    expect(p.lastSent?.clientTs, t0.add(const Duration(seconds: 5)));
    await p.stop();
  });
}

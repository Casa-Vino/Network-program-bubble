import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/radio_device.dart';
import 'package:device_scanner/models/room_map.dart';
import 'package:device_scanner/ui/room_signal_panel.dart';

void main() {
  testWidgets(
      'signal feedback distinguishes fresh trends, stale observations and saved measurements',
      (tester) async {
    final now = DateTime.now();
    RadioDevice device(DateTime time) {
      final d = RadioDevice('keys', false);
      for (var i = 0; i < 6; i++) {
        d.update({
          'kind': 'ble',
          'name': 'Keys',
          'detail': '',
          'rssi': i < 3 ? -80 : -60,
          'time': time.subtract(Duration(seconds: 5 - i)).millisecondsSinceEpoch
        });
      }
      return d;
    }

    final fresh = device(now),
        stale = device(now.subtract(const Duration(minutes: 1)));
    final map = RoomMap()
      ..readings.addAll([
        RoomReading(1, 0, 0, -50, now, sourceKey: fresh.key),
        RoomReading(2, 0, 0, -60, now.add(const Duration(seconds: 1)),
            sourceKey: fresh.key),
      ]);
    Future<void> show(RadioDevice d, bool ended) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: RoomSignalPanel(
                  sourceKey: fresh.key,
                  map: map,
                  devices: [d],
                  ended: ended))));
    }

    await show(fresh, false);
    expect(find.textContaining('-60 dBm · Stronger signal'), findsOneWidget);
    expect(find.textContaining('Best mapped -50 dBm · 2 readings'),
        findsOneWidget);
    await show(stale, false);
    expect(find.textContaining('Reading stale'), findsOneWidget);
    await show(stale, true);
    expect(find.textContaining('Saved measurements'), findsOneWidget);
    expect(find.textContaining('Reading stale'), findsNothing);
  });
}

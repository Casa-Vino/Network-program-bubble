import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/radio_device.dart';
import 'package:device_scanner/ui/signal_cloud.dart';

RadioDevice source(String name, int rssi, DateTime time, {bool wifi = false}) {
  final d = RadioDevice(name, wifi);
  d.update({
    'kind': wifi ? 'wifi' : 'ble',
    'name': name,
    'detail': '',
    'rssi': rssi,
    'time': time.millisecondsSinceEpoch
  });
  return d;
}

void main() {
  test(
      'cloud contains only recent measured samples, with no empty-scene points',
      () {
    final now = DateTime(2026, 11, 1, 12);
    expect(signalPoints([], now), isEmpty);
    final recent = source('Keys', -65, now);
    final old = source('Old', -65, now.subtract(const Duration(minutes: 3)));
    expect(signalPoints([recent, old], now).map((p) => p.key), [recent.key]);
  });

  test(
      'stronger readings move inward in signal space, not to metre coordinates',
      () {
    final now = DateTime(2026, 11, 1, 12);
    final weak = signalPoints([source('Keys', -95, now)], now).single;
    final strong = signalPoints([source('Keys', -45, now)], now).single;
    double radius(CloudPoint p) => p.x * p.x + p.z * p.z;
    expect(radius(strong), lessThan(radius(weak)));
    expect(strong.y, weak.y);
    expect(strong.x / strong.z, closeTo(weak.x / weak.z, 0.0001));
  });

  test('renderer caps sample count and expires stale trails', () {
    final now = DateTime(2026, 11, 1, 12);
    final devices = List.generate(150, (i) {
      final d =
          source('source$i', -60, now.subtract(const Duration(seconds: 60)));
      for (var j = 0; j < 100; j++) {
        d.update({
          'kind': 'ble',
          'name': 'source$i',
          'detail': '',
          'rssi': -60,
          'time': now.millisecondsSinceEpoch - 59000 + j * 500
        });
      }
      return d;
    });
    expect(signalPoints(devices, now).length, 6000);
    expect(signalPoints(devices, now.add(const Duration(minutes: 4))), isEmpty);
  });

  testWidgets('cloud supports source selection, isolation, freeze and rotation',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = source('Keys', -65, DateTime.now());
    String? selected;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
                appBar: AppBar(title: const Text('Bubble')),
                body: SignalCloud(
                    devices: [key],
                    scanning: true,
                    selected: selected,
                    status: '',
                    onSelect: (value) => setState(() => selected = value))))));
    expect(find.textContaining('no physical positions'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Keys'));
    await tester.pump();
    expect(selected, key.key);
    await tester.tap(find.byTooltip('Isolate selected source'));
    await tester.pump();
    expect(find.byTooltip('Show all sources'), findsOneWidget);
    await tester.tap(find.byTooltip('Freeze cloud'));
    await tester.pump();
    expect(find.textContaining('FROZEN'), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('signal-cloud-viewport')),
        const Offset(50, 25));
    await tester.pump();
    await tester.tap(find.byTooltip('Resume cloud'));
    await tester.pump();
    expect(find.textContaining('RECEIVING'), findsOneWidget);
    tester.view.physicalSize = const Size(915, 412);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

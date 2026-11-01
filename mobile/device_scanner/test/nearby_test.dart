import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/ui/nearby.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const radio = MethodChannel('bubble/radio');
  const events = MethodChannel('bubble/radio/events');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var stopped = 0;
  var started = 0;

  setUp(() {
    stopped = 0;
    started = 0;
    messenger.setMockMethodCallHandler(radio, (call) async {
      if (call.method == 'capabilities')
        return {
          'Phone': 'S21 Ultra test fixture',
          'UWB hardware (ranging not implemented)': true
        };
      if (call.method == 'start') started++;
      if (call.method == 'stop') stopped++;
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final id in call.arguments as List) id: 0};
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(radio, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(permissions, null);
  });

  Future<void> emit(Map<String, Object> event) async {
    await messenger.handlePlatformMessage('bubble/radio/events',
        const StandardMethodCodec().encodeSuccessEnvelope(event), (_) {});
  }

  testWidgets('denied permissions show guidance and other methods still start',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NearbyPage()));
    await tester.pump();
    await tester.tap(find.text('Scan nearby'));
    await tester.pump();
    await tester.pump();
    expect(started, 1);
    expect(find.textContaining('Some permissions are missing'), findsOneWidget);
    expect(find.text('Stop scan'), findsOneWidget);
    await tester.tap(find.text('Stop scan'));
    await tester.pump();
    expect(stopped, greaterThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('wireless observations can be selected and become stale',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NearbyPage()));
    await tester.pump();
    await emit({
      'type': 'observation',
      'kind': 'ble',
      'address': 'AA:BB:CC:DD:EE:FF',
      'name': 'Keys',
      'detail': 'Test advertisement',
      'rssi': -65,
      'time': DateTime.now()
          .subtract(const Duration(seconds: 20))
          .millisecondsSinceEpoch
    });
    await tester.pump();
    await tester.tap(find.text('Keys'));
    await tester.pump();
    expect(find.text('Following Keys'), findsOneWidget);
    expect(find.textContaining('Signal is stale'), findsOneWidget);
    expect(find.textContaining('not metres'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(stopped, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('capabilities label unsupported ranging implementation honestly',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NearbyPage()));
    await tester.pump();
    await tester.tap(find.byTooltip('Phone capabilities'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('S21 Ultra test fixture'), findsOneWidget);
    expect(find.textContaining('UWB hardware (ranging not implemented): true'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

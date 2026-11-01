import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/ui/room_scan.dart';
import 'package:device_scanner/models/radio_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const events = MethodChannel('bubble/room/events');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const room = MethodChannel('bubble/room');
  final torchCommands = <bool>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    torchCommands.clear();
    messenger.setMockMethodCallHandler(room, (call) async {
      final enabled = (call.arguments as Map)['enabled'] as bool;
      torchCommands.add(enabled);
      return enabled;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(permissions,
        (call) async => {for (final id in call.arguments as List) id: 0});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(room, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(permissions, null);
  });
  testWidgets('room scan discloses ARCore and waits for camera permission',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            refreshSignals: () async {},
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    expect(find.textContaining('governed by the Google Privacy Policy'),
        findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);
    await tester.tap(find.text('Start room camera'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Camera permission is needed'), findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);
    tester.view.physicalSize = const Size(915, 412);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'flashlight follows camera capability, command acknowledgement and pause',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            refreshSignals: () async {},
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    IconButton button() => tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.flashlight_off));
    expect(button().onPressed, isNull);
    Future<void> emit(Map<String, Object> event) async {
      await messenger.handlePlatformMessage('bubble/room/events',
          const StandardMethodCodec().encodeSuccessEnvelope(event), (_) {});
      await tester.pump();
    }

    await emit({'torchAvailable': true, 'cameraActive': true, 'torch': false});
    expect(button().onPressed, isNotNull);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.flashlight_off));
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Turn flashlight off'), findsOneWidget);
    await tester.tap(find.byTooltip('Turn flashlight off'));
    await tester.pump();
    await tester.pump();
    expect(torchCommands, [true, false]);
    await emit({'cameraActive': false, 'torch': false});
    expect(button().onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'room signal selector exposes other devices without reopening the map',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    RadioDevice device(String name) => RadioDevice(name, false)
      ..update({
        'kind': 'ble',
        'name': name,
        'detail': '',
        'time': now,
        'rssi': -60
      });
    final devices = [device('Keys'), device('Other phone')];
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            sources: () => devices,
            refreshSignals: () async {},
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    await messenger.handlePlatformMessage(
        'bubble/room/events',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'tracking': true,
          'pose': [0.0, 0.0, 0.0],
          'time': now
        }),
        (_) {});
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('room-source-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Other phone ·').last);
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Selected device: cyan = weaker'), findsOneWidget);
    expect(find.textContaining('Other phone ·'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

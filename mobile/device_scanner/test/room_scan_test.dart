import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/ui/room_scan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const events = MethodChannel('bubble/room/events');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(permissions,
        (call) async => {for (final id in call.arguments as List) id: 0});
  });
  tearDown(() {
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
}

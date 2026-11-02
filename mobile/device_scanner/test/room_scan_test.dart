import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/ui/room_scan.dart';
import 'package:device_scanner/models/radio_device.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:device_scanner/ui/room_painter.dart';
import 'package:device_scanner/models/room_map.dart';
import 'package:device_scanner/models/saved_room.dart';
import 'package:device_scanner/services/room_store.dart';

class MemoryRoomStore extends RoomStore {
  final snapshots = <SavedRoom>[];
  bool fail = false;
  @override
  Future<void> save(SavedRoom room) async {
    if (fail) throw StateError('Disk full');
    snapshots.add(room);
  }

  @override
  Future<List<File>> list() async =>
      snapshots.isEmpty ? [] : [File('/1793581200000000.bubble.json')];
  @override
  Future<SavedRoom> load(File file) async => snapshots.last;
}

class ExportPicker extends FilePicker {
  ExportPicker(this.destination);
  final String? destination;
  Uint8List? received;
  @override
  Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    received = bytes;
    return destination;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const events = MethodChannel('bubble/room/events');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const room = MethodChannel('bubble/room');
  final torchCommands = <bool>[];
  var endedCommands = 0;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    FilePicker.platform = ExportPicker(null);
    torchCommands.clear();
    endedCommands = 0;
    messenger.setMockMethodCallHandler(room, (call) async {
      if (call.method == 'endScan') {
        endedCommands++;
        return null;
      }
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

  testWidgets(
      'End scan freezes capture, closes camera, saves raw data then fitted walls',
      (tester) async {
    final store = MemoryRoomStore();
    var stopped = false;
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            store: store,
            refreshSignals: () async {},
            stopSignals: () async {
              stopped = true;
            },
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    final points = <double>[];
    for (var x = 0; x <= 25; x++) {
      for (var y = 0; y <= 25; y++) {
        points.addAll([x * .1, y * .1, 0]);
      }
    }
    Future<void> emit(List<double> coordinates) =>
        messenger.handlePlatformMessage(
            'bubble/room/events',
            const StandardMethodCodec().encodeSuccessEnvelope({
              'tracking': true,
              'cameraActive': true,
              'pose': [0.0, 0.0, 0.0],
              'points': coordinates,
              'time': DateTime.now().millisecondsSinceEpoch,
            }),
            (_) {});
    await emit(points);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('end-room-scan')));
    await tester.pump();
    await emit([99, 99, 99]); // Queued frames after End must be ignored.
    for (var i = 0; i < 200 && store.snapshots.length < 2; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(endedCommands, 1);
    expect(stopped, isTrue);
    expect(store.snapshots.first.walls, isEmpty);
    expect(store.snapshots.last.walls.length, 1);
    expect(store.snapshots.last.points.length, points.length ~/ 3);
    expect(store.snapshots.last.points.any((p) => p.x == 99), isFalse);
    expect(find.byType(AndroidView), findsNothing);
    expect(
        find.textContaining('Scan saved · 1 candidate wall'), findsOneWidget);
    expect(find.text('New scan'), findsOneWidget);
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            store: store,
            refreshSignals: () async {},
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    await tester.tap(find.byTooltip('Saved scans'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SimpleDialogOption));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Saved scan · 1 candidate walls'), findsOneWidget);
    expect(find.textContaining('ENDED · ${points.length ~/ 3} points'),
        findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('failed save is visible and retry preserves the frozen capture',
      (tester) async {
    final store = MemoryRoomStore()..fail = true;
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            store: store,
            refreshSignals: () async {},
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    await messenger.handlePlatformMessage(
        'bubble/room/events',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'tracking': true,
          'pose': [0.0, 0.0, 0.0],
          'points': [1.0, 2.0, 3.0],
        }),
        (_) {});
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('end-room-scan')));
    await tester.pumpAndSettle();
    expect(find.textContaining('NOT saved'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'New scan'))
            .onPressed,
        isNull);
    store.fail = false;
    await tester.tap(find.text('Retry wall fit / save'));
    for (var i = 0; i < 200 && store.snapshots.length < 2; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(store.snapshots.last.points.single.x, 1);
    expect(find.textContaining('Scan saved · no sufficiently'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'New scan'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'review supports top-down navigation and exports the full captured points',
      (tester) async {
    final store = MemoryRoomStore();
    store.snapshots.add(SavedRoom(
        DateTime(2026),
        [const RoomPoint(-1, 0, -1), const RoomPoint(1, 2, 1)],
        [],
        const RoomPoint(0, 0, 0)));
    final dir = await tester
        .runAsync(() => Directory.systemTemp.createTemp('bubble-export'));
    final previous = FilePicker.platform;
    final picker = ExportPicker('${dir!.path}/scan.ply');
    FilePicker.platform = picker;
    addTearDown(() async {
      FilePicker.platform = previous;
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            store: store,
            refreshSignals: () async {},
            signalsActive: () => false,
            signalStatus: () => '')));
    await tester.pump();
    await tester.tap(find.byTooltip('Saved scans'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SimpleDialogOption));
    await tester.pumpAndSettle();
    RoomPainter painter() => tester
        .widget<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is RoomPainter))
        .painter! as RoomPainter;
    await tester.tap(find.byTooltip('Room tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Top-down view'));
    await tester.pumpAndSettle();
    expect(painter().tilt, closeTo(math.pi / 2, .001));
    final before = painter().zoom;
    final center =
        tester.getCenter(find.byKey(const ValueKey('room-viewport')));
    final a =
        await tester.startGesture(center + const Offset(-40, 0), pointer: 1);
    final b =
        await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await a.moveBy(const Offset(20, 15));
    await b.moveBy(const Offset(-20, 15));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(painter().zoom, lessThan(before));
    expect(painter().pan, isNot(Offset.zero));
    await tester.tap(find.byTooltip('Room display settings'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.text('Hide isolated clusters (review only)'));
    await tester.tap(find.text('Hide isolated clusters (review only)'));
    for (var i = 0; i < 200 && painter().displayPoints!.isNotEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(painter().displayPoints, isEmpty);
    expect(painter().map.surfaces.length, 2);
    await tester.tap(find.byTooltip('Room tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Captured points PLY'));
    for (var i = 0; i < 200 && picker.received == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    for (var i = 0;
        i < 30 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(utf8.decode(picker.received!), contains('element vertex 2\n'));
    expect(await tester.runAsync(() => File(picker.destination!).exists()),
        isTrue);
    expect(find.textContaining('Captured points PLY exported'), findsOneWidget);
    final cancelled = ExportPicker(null);
    FilePicker.platform = cancelled;
    await tester.tap(find.byTooltip('Room tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Full scan JSON'));
    for (var i = 0; i < 200 && cancelled.received == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Export cancelled.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('repeat signal scans require an active camera and stop on pause',
      (tester) async {
    var active = false, scans = 0;
    final store = MemoryRoomStore();
    await tester.pumpWidget(MaterialApp(
        home: RoomScanPage(
            store: store,
            stopSignals: () async {
              active = false;
            },
            refreshSignals: () async {
              scans++;
              active = true;
            },
            signalsActive: () => active,
            signalStatus: () => '')));
    await tester.pump();
    await tester.tap(find.byTooltip('Room display settings'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Repeat signal scans'))
            .onChanged,
        isNull);
    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await messenger.handlePlatformMessage(
        'bubble/room/events',
        const StandardMethodCodec()
            .encodeSuccessEnvelope({'cameraActive': true}),
        (_) {});
    await tester.pump();
    await tester.tap(find.byTooltip('Room display settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Repeat signal scans'));
    await tester.tap(find.text('Repeat signal scans'));
    await tester.pumpAndSettle();
    expect(scans, 1);
    active = false;
    await tester.pump(const Duration(seconds: 32));
    await tester.pump();
    expect(scans, 2);
    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    active = false;
    await tester.pump(const Duration(seconds: 64));
    expect(scans, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await messenger.handlePlatformMessage(
        'bubble/room/events',
        const StandardMethodCodec()
            .encodeSuccessEnvelope({'cameraActive': true}),
        (_) {});
    await tester.pump();
    await tester.tap(find.byTooltip('Room display settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Repeat signal scans'));
    await tester.tap(find.text('Repeat signal scans'));
    await tester.pumpAndSettle();
    expect(scans, 3);
    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('end-room-scan')));
    for (var i = 0; i < 200 && store.snapshots.length < 2; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 64));
    expect(scans, 3);
    expect(active, isFalse);
    expect(endedCommands, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/radio_device.dart';
import '../models/room_map.dart';

class RoomScanPage extends StatefulWidget {
  const RoomScanPage(
      {super.key,
      this.source,
      this.sources,
      required this.refreshSignals,
      required this.signalsActive,
      required this.signalStatus});
  final RadioDevice? source;
  final Iterable<RadioDevice> Function()? sources;
  final Future<void> Function() refreshSignals;
  final bool Function() signalsActive;
  final String Function() signalStatus;
  @override
  State<RoomScanPage> createState() => _RoomScanPageState();
}

class _RoomScanPageState extends State<RoomScanPage>
    with WidgetsBindingObserver {
  final map = RoomMap();
  StreamSubscription<dynamic>? events;
  bool camera = false, requesting = false, refreshing = false;
  bool torch = false,
      torchAvailable = false,
      cameraActive = false,
      torchPending = false;
  String status =
      'Start the camera, then move slowly across textured surfaces in good light.';
  double yaw = 0.3, tilt = 0.45, zoom = 35;
  late String sourceFilter;
  List<RadioDevice> get availableSources => (widget.sources?.call() ??
          (widget.source == null ? <RadioDevice>[] : [widget.source!]))
      .where((d) => d.history.isNotEmpty)
      .toList();
  @override
  void initState() {
    super.initState();
    sourceFilter = widget.source?.key ?? '*';
    WidgetsBinding.instance.addObserver(this);
    events = const EventChannel('bubble/room/events')
        .receiveBroadcastStream()
        .listen((dynamic value) {
      if (!mounted || value is! Map) return;
      setState(() {
        status = value['state'] as String? ?? status;
        if (value.containsKey('tracking')) {
          map.frame(value, widget.source, sources: availableSources);
        }
        if (value['torch'] is bool) torch = value['torch'] as bool;
        if (value['torchAvailable'] is bool) {
          torchAvailable = value['torchAvailable'] as bool;
        }
        if (value['cameraActive'] is bool) {
          cameraActive = value['cameraActive'] as bool;
        }
      });
    }, onError: (Object e) {
      if (mounted) {
        setState(() {
          status = 'Room scan error: $e';
          map.tracking = false;
        });
      }
    });
  }

  Future<void> startCamera() async {
    if (requesting) return;
    setState(() => requesting = true);
    final result = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      requesting = false;
      camera = result.isGranted;
      if (!camera) {
        status =
            'Camera permission is needed for room scanning. Nearby still works without it.';
      }
    });
  }

  Future<void> toggleTorch() async {
    if (torchPending) return;
    setState(() => torchPending = true);
    try {
      final enabled = await const MethodChannel('bubble/room')
          .invokeMethod<bool>('setTorch', {'enabled': !torch});
      if (mounted && cameraActive) setState(() => torch = enabled ?? false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not change flashlight: $e')));
      }
    } finally {
      if (mounted) setState(() => torchPending = false);
    }
  }

  Future<void> refresh() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      await widget.refreshSignals();
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() {
        map.tracking = false;
        torch = false;
        cameraActive = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF050B0C),
        appBar: AppBar(title: const Text('Bubble · Room scan'), actions: [
          PopupMenuButton<int>(
              tooltip: 'Surface point limit',
              icon: const Icon(Icons.tune),
              onSelected: (limit) => setState(() => map.setSurfaceLimit(limit)),
              itemBuilder: (_) => [
                    for (final limit in [60000, 150000, 300000])
                      CheckedPopupMenuItem(
                          value: limit,
                          checked: map.maxSurfacePoints == limit,
                          child: Text(
                              '${limit ~/ 1000},000 points${limit == 300000 ? ' · experimental' : ''}'))
                  ]),
          IconButton(
              tooltip: torch ? 'Turn flashlight off' : 'Turn flashlight on',
              onPressed: cameraActive && torchAvailable && !torchPending
                  ? toggleTorch
                  : null,
              color: torch ? Colors.amber : null,
              icon: Icon(torch ? Icons.flashlight_on : Icons.flashlight_off)),
          IconButton(
              tooltip: 'Reset viewing angle',
              onPressed: () => setState(() {
                    yaw = 0.3;
                    tilt = 0.45;
                    zoom = 35;
                  }),
              icon: const Icon(Icons.center_focus_strong)),
        ]),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  'Green: estimated surfaces · blue: phone\n${sourceFilter == '*' ? 'All devices: marker colour identifies the source' : 'Selected device: cyan = weaker, orange = stronger'}\nMarkers show phone measurement positions, not transmitter locations.',
                  style: const TextStyle(color: Colors.white70, fontSize: 12))),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButton<String>(
                  key: const ValueKey('room-source-filter'),
                  isExpanded: true,
                  value: sourceFilter,
                  dropdownColor: const Color(0xFF102020),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  items: [
                    const DropdownMenuItem(
                        value: '*', child: Text('All device signal layers')),
                    for (final d in availableSources)
                      DropdownMenuItem(
                          value: d.key,
                          child: Row(children: [
                            Icon(Icons.circle,
                                color: roomSourceColor(d.key), size: 9),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                                    '${d.label} · ${map.readingCounts[d.key] ?? 0} mapped',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis))
                          ]))
                  ],
                  onChanged: (key) {
                    if (key != null) setState(() => sourceFilter = key);
                  })),
          Expanded(
              child: Stack(children: [
            if (camera)
              const Positioned.fill(
                  child: AndroidView(viewType: 'bubble/room')),
            Positioned.fill(
                child: GestureDetector(
                    onPanUpdate: (d) => setState(() {
                          yaw += d.delta.dx * 0.008;
                          tilt = (tilt + d.delta.dy * 0.006).clamp(-1.2, 1.2);
                        }),
                    child: ColoredBox(
                        color: const Color(0xFF050B0C),
                        child: CustomPaint(
                            painter: _RoomPainter(
                                map, yaw, tilt, zoom, sourceFilter))))),
            if (!camera)
              Center(
                  child: FilledButton(
                      onPressed: requesting ? null : startCamera,
                      child: Text(requesting
                          ? 'Requesting camera…'
                          : 'Start room camera'))),
            Positioned(
                left: 12,
                right: 12,
                top: 8,
                child: Text(
                    '${map.tracking ? 'TRACKING' : 'NO POSITION FIX'} · ${map.surfaces.length} surface points · ${map.readings.length} signal readings',
                    style: const TextStyle(
                        color: Color(0xFF9AF8BE), fontSize: 11))),
            const Positioned(
                left: 12,
                bottom: 8,
                child: Text(
                    'Drag to orbit · 1 m reference grid · not a detected floor',
                    style: TextStyle(color: Colors.white54, fontSize: 11))),
          ])),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(status,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  maxLines: 3)),
          Row(children: [
            const SizedBox(width: 12),
            const Text('Zoom', style: TextStyle(color: Colors.white70)),
            Expanded(
                child: Slider(
                    value: zoom,
                    min: 10,
                    max: 100,
                    onChanged: (v) => setState(() => zoom = v))),
            TextButton(
                onPressed: availableSources.isEmpty ||
                        refreshing ||
                        widget.signalsActive()
                    ? null
                    : refresh,
                child: Text(widget.signalsActive()
                    ? 'Signals scanning…'
                    : 'Scan signals'))
          ]),
          if (availableSources.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(widget.signalStatus(),
                    maxLines: 2,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11))),
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                  camera
                      ? 'Keep the phone moving slowly. Reflective, dark or featureless surfaces may be incomplete. Leaving this screen releases the camera; this experimental map is not saved.'
                      : 'This application runs on Google Play Services for AR (ARCore), provided by Google and governed by the Google Privacy Policy.',
                  style: const TextStyle(color: Colors.white54, fontSize: 10))),
          if (!camera)
            TextButton(
                onPressed: () =>
                    launchUrl(Uri.parse('https://policies.google.com/privacy')),
                child: const Text('Google Privacy Policy')),
          const SizedBox(height: 12),
        ]),
      );
}

class _RoomPainter extends CustomPainter {
  _RoomPainter(this.map, this.yaw, this.tilt, this.zoom, this.sourceFilter);
  final String sourceFilter;
  final RoomMap map;
  final double yaw, tilt, zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final origin = map.phone ?? const RoomPoint(0, 0, 0);
    final cy = math.cos(yaw),
        sy = math.sin(yaw),
        ct = math.cos(tilt),
        st = math.sin(tilt);
    Offset project(RoomPoint p) {
      final x = p.x - origin.x, y = p.y - origin.y, z = p.z - origin.z;
      final rx = x * cy - z * sy, rz = x * sy + z * cy;
      return Offset(size.width / 2 + rx * zoom,
          size.height / 2 - (y * ct - rz * st) * zoom);
    }

    final grid = Paint()
      ..color = const Color(0xFF16342B)
      ..strokeWidth = 0.7;
    for (var i = -5; i <= 5; i++) {
      canvas.drawLine(project(RoomPoint(origin.x + i, 0.0, origin.z - 5)),
          project(RoomPoint(origin.x + i, 0.0, origin.z + 5)), grid);
      canvas.drawLine(project(RoomPoint(origin.x - 5, 0.0, origin.z + i)),
          project(RoomPoint(origin.x + 5, 0.0, origin.z + i)), grid);
    }
    final paint = Paint()
      ..color = const Color(0xFF9AF8BE).withOpacity(0.6)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final vertices = Float32List(map.surfaces.length * 2);
    var index = 0;
    for (final p in map.surfaces.values) {
      final x = p.x - origin.x, y = p.y - origin.y, z = p.z - origin.z;
      vertices[index++] = size.width / 2 + (x * cy - z * sy) * zoom;
      vertices[index++] =
          size.height / 2 - (y * ct - (x * sy + z * cy) * st) * zoom;
    }
    canvas.drawRawPoints(ui.PointMode.points, vertices, paint);
    for (final p in map.readings) {
      if (sourceFilter != '*' && p.sourceKey != sourceFilter) continue;
      final strength = ((p.rssi + 100) / 60).clamp(0.0, 1.0);
      canvas.drawCircle(
          project(p),
          4,
          Paint()
            ..color = sourceFilter == '*'
                ? roomSourceColor(p.sourceKey)
                : Color.lerp(Colors.cyan, Colors.deepOrange, strength)!);
    }
    if (map.phone != null) {
      canvas.drawCircle(
          project(map.phone!), 6, Paint()..color = Colors.blueAccent);
    }
  }

  @override
  bool shouldRepaint(covariant _RoomPainter oldDelegate) => true;
}

Color roomSourceColor(String key) {
  final hue = key.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0xffff) % 360;
  return HSVColor.fromAHSV(1, hue.toDouble(), 0.7, 0.95).toColor();
}

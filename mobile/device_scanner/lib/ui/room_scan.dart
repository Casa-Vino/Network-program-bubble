import 'dart:async';
import 'dart:math' as math;
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
      required this.refreshSignals,
      required this.signalsActive,
      required this.signalStatus});
  final RadioDevice? source;
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
  String status =
      'Start the camera, then move slowly across textured surfaces in good light.';
  double yaw = 0.3, tilt = 0.45, zoom = 35;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    events = const EventChannel('bubble/room/events')
        .receiveBroadcastStream()
        .listen((dynamic value) {
      if (!mounted || value is! Map) return;
      setState(() {
        status = value['state'] as String? ?? status;
        map.frame(value, widget.source);
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
      setState(() => map.tracking = false);
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
                  '${widget.source == null ? 'Room geometry only · select a device in Nearby to map its signals' : 'Mapping readings for ${widget.source!.label}'}\nGreen: estimated surfaces · blue: phone · orange/red: stronger readings\nSignal markers are phone measurement positions, not transmitter locations.',
                  style: const TextStyle(color: Colors.white70, fontSize: 12))),
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
                            painter: _RoomPainter(map, yaw, tilt, zoom))))),
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
                onPressed: widget.source == null ||
                        refreshing ||
                        widget.signalsActive()
                    ? null
                    : refresh,
                child: Text(widget.signalsActive()
                    ? 'Signals scanning…'
                    : 'Scan signals'))
          ]),
          if (widget.source != null)
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
  _RoomPainter(this.map, this.yaw, this.tilt, this.zoom);
  final RoomMap map;
  final double yaw, tilt, zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final origin = map.phone ?? const RoomPoint(0, 0, 0);
    Offset project(RoomPoint p) {
      final x = p.x - origin.x, y = p.y - origin.y, z = p.z - origin.z;
      final rx = x * math.cos(yaw) - z * math.sin(yaw),
          rz = x * math.sin(yaw) + z * math.cos(yaw);
      return Offset(size.width / 2 + rx * zoom,
          size.height / 2 - (y * math.cos(tilt) - rz * math.sin(tilt)) * zoom);
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
    final paint = Paint()..color = const Color(0xFF9AF8BE).withOpacity(0.6);
    for (final p in map.surfaces.values) {
      canvas.drawCircle(project(p), 1, paint);
    }
    for (final p in map.readings) {
      final strength = ((p.rssi + 100) / 60).clamp(0.0, 1.0);
      canvas.drawCircle(
          project(p),
          4,
          Paint()
            ..color = Color.lerp(Colors.cyan, Colors.deepOrange, strength)!);
    }
    if (map.phone != null) {
      canvas.drawCircle(
          project(map.phone!), 6, Paint()..color = Colors.blueAccent);
    }
  }

  @override
  bool shouldRepaint(covariant _RoomPainter oldDelegate) => true;
}

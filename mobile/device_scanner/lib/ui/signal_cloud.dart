import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/radio_device.dart';

const _mint = Color(0xFF9AF8BE);
const _cyan = Color(0xFF6EDBFF);
const _amber = Color(0xFFFFCC85);
const _ink = Color(0xFF050B0C);

/// Abstract signal space. Radius encodes RSSI, angle identifies a source and
/// height encodes sample age. None of these coordinates is a physical location.
class CloudPoint {
  const CloudPoint(
      this.key, this.x, this.y, this.z, this.freshness, this.color);
  final String key;
  final double x, y, z, freshness;
  final Color color;
}

List<CloudPoint> signalPoints(List<RadioDevice> devices, DateTime now) {
  final points = <CloudPoint>[];
  for (final device in devices) {
    // Stable per-identity lanes, unrelated to compass heading or radio bearing.
    var hash = 2166136261;
    for (final c in device.key.codeUnits) {
      hash = ((hash ^ c) * 16777619) & 0x7fffffff;
    }
    final angle = (hash % 3600) / 3600 * math.pi * 2;
    final color = device.isWifi
        ? _mint
        : device.methods.contains('ble')
            ? _cyan
            : _amber;
    // A rendering budget keeps the view responsive in busy radio environments.
    final samples = device.history.length <= 60
        ? device.history
        : device.history.sublist(device.history.length - 60);
    for (final sample in samples) {
      final age = now.difference(sample.time).inMilliseconds / 1000;
      if (age > 120 || age < -1 || sample.rssi < -127 || sample.rssi > -1) {
        continue;
      }
      final radius = 0.22 + ((-sample.rssi - 30) / 80).clamp(0.0, 1.0) * 0.78;
      final freshness = (1 - age.clamp(0.0, 120.0) / 120).toDouble();
      points.add(CloudPoint(
          device.key,
          math.cos(angle) * radius,
          0.55 - age.clamp(0.0, 120.0) / 120,
          math.sin(angle) * radius,
          freshness,
          color));
      if (points.length >= 6000) return points;
    }
  }
  return points;
}

class SignalCloud extends StatefulWidget {
  const SignalCloud(
      {super.key,
      required this.devices,
      required this.scanning,
      required this.selected,
      required this.onSelect,
      required this.status});
  final List<RadioDevice> devices;
  final bool scanning;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final String status;
  @override
  State<SignalCloud> createState() => _SignalCloudState();
}

class _SignalCloudState extends State<SignalCloud>
    with SingleTickerProviderStateMixin {
  late final AnimationController sweep;
  double yaw = -0.35;
  double tilt = 0.42;
  bool singleSource = false;
  bool frozen = false;
  DateTime? frozenTime;
  List<CloudPoint>? frozenPoints;

  @override
  void initState() {
    super.initState();
    sweep =
        AnimationController(vsync: this, duration: const Duration(seconds: 5));
    updateAnimation();
  }

  @override
  void didUpdateWidget(covariant SignalCloud oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateAnimation();
    if (widget.selected == null) singleSource = false;
  }

  void updateAnimation() {
    if (widget.scanning &&
        !frozen &&
        !WidgetsBinding.instance.disableAnimations) {
      if (!sweep.isAnimating) sweep.repeat();
    } else {
      sweep.stop();
    }
  }

  void toggleFreeze() {
    setState(() {
      frozen = !frozen;
      if (frozen) {
        frozenTime = DateTime.now();
        frozenPoints = signalPoints(widget.devices, frozenTime!);
      } else {
        frozenTime = null;
        frozenPoints = null;
      }
      updateAnimation();
    });
  }

  @override
  void dispose() {
    sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).height < 600;
    final now = DateTime.now();
    final allPoints = frozenPoints ?? signalPoints(widget.devices, now);
    final points = singleSource && widget.selected != null
        ? allPoints.where((p) => p.key == widget.selected).toList()
        : allPoints;
    RadioDevice? target;
    for (final device in widget.devices) {
      if (device.key == widget.selected) target = device;
    }
    final chosen = target;
    return ColoredBox(
        color: _ink,
        child: SafeArea(
            top: false,
            child: Column(children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                  child: Row(children: [
                    const Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('SIGNAL CLOUD',
                              style: TextStyle(
                                  color: _mint,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 3)),
                          SizedBox(height: 4),
                          Text('OBSERVED RADIO SIGNALS / 120s TRAILS',
                              style: TextStyle(
                                  color: Color(0xFF91A8A3),
                                  fontSize: 10,
                                  letterSpacing: 1.3)),
                        ])),
                    IconButton(
                        tooltip: frozen ? 'Resume cloud' : 'Freeze cloud',
                        color: _mint,
                        onPressed: toggleFreeze,
                        icon: Icon(frozen ? Icons.play_arrow : Icons.pause)),
                    IconButton(
                        tooltip: 'Reset cloud view',
                        color: _mint,
                        onPressed: () => setState(() {
                              yaw = -0.35;
                              tilt = 0.42;
                            }),
                        icon: const Icon(Icons.center_focus_strong)),
                  ])),
              const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                      'Signal-space view · no physical positions or room geometry',
                      style:
                          TextStyle(color: Color(0xFFBECBC5), fontSize: 12))),
              Expanded(child: LayoutBuilder(builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  key: const ValueKey('signal-cloud-viewport'),
                  onPanUpdate: (d) => setState(() {
                    yaw += d.delta.dx * 0.009;
                    tilt = (tilt + d.delta.dy * 0.006).clamp(-0.9, 0.9);
                  }),
                  onTapUp: (event) {
                    CloudPoint? nearest;
                    var distance = 28.0;
                    for (final point in points) {
                      final screen =
                          _project(point.x, point.y, point.z, size, yaw, tilt);
                      final delta = (screen - event.localPosition).distance;
                      if (delta < distance) {
                        nearest = point;
                        distance = delta;
                      }
                    }
                    if (nearest != null) widget.onSelect(nearest.key);
                  },
                  child: Semantics(
                      label:
                          'Rotatable signal-strength point cloud. Angles are layout only. Select a device using the buttons below.',
                      child: Stack(fit: StackFit.expand, children: [
                        RepaintBoundary(
                            child: CustomPaint(
                                painter: _CloudPainter(
                                    points: points,
                                    yaw: yaw,
                                    tilt: tilt,
                                    selected: widget.selected,
                                    sweep: sweep,
                                    scanning: widget.scanning && !frozen))),
                        Positioned(
                            left: 18,
                            top: 14,
                            child: Text(
                                frozen
                                    ? 'FROZEN ${frozenTime!.hour.toString().padLeft(2, '0')}:${frozenTime!.minute.toString().padLeft(2, '0')}'
                                    : widget.scanning
                                        ? '● RECEIVING / SWEEP EFFECT'
                                        : 'SCAN IDLE / RECENT HISTORY',
                                style: const TextStyle(
                                    color: _mint,
                                    fontFamily: 'monospace',
                                    fontSize: 10))),
                        Positioned(
                            right: 18,
                            top: 14,
                            child: Text('${points.length} SAMPLES',
                                style: const TextStyle(
                                    color: Color(0xFF91A8A3),
                                    fontFamily: 'monospace',
                                    fontSize: 10))),
                        if (points.isEmpty)
                          const Center(
                              child: Padding(
                                  padding: EdgeInsets.all(30),
                                  child: Text(
                                      'The void is quiet.\nScan nearby to reveal real signal readings.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Color(0xFFBECBC5),
                                          height: 1.8)))),
                        const Positioned(
                            left: 18,
                            right: 18,
                            bottom: 12,
                            child: Text(
                                'Drag to orbit · tap points to select\nRadius = signal strength / height = age / angle = layout',
                                style: TextStyle(
                                    color: Color(0xFF91A8A3),
                                    fontSize: 10,
                                    height: 1.6))),
                      ])),
                );
              })),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(children: [
                    const _LegendDot(_mint, 'Wi-Fi'),
                    const SizedBox(width: 16),
                    const _LegendDot(_cyan, 'BLE'),
                    const SizedBox(width: 16),
                    const _LegendDot(_amber, 'Classic'),
                    const Spacer(),
                    Text('${widget.devices.length} identities',
                        style: const TextStyle(
                            color: Color(0xFF91A8A3), fontSize: 11)),
                  ])),
              if (chosen != null && !compact)
                Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                    child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: const Color(0xFF102020),
                            border: Border.all(color: const Color(0xFF29443C)),
                            borderRadius: BorderRadius.circular(12)),
                        child: Row(children: [
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(chosen.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: _mint,
                                        fontWeight: FontWeight.w600)),
                                Text(
                                    '${chosen.smoothed.toStringAsFixed(0)} dBm · ${now.difference(chosen.latest.time).inSeconds.clamp(0, 99999)}s ago',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                Text(
                                    now
                                                .difference(chosen.latest.time)
                                                .inSeconds >
                                            15
                                        ? 'Stale reading — scan for fresh evidence'
                                        : chosen.trend,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11)),
                              ])),
                          IconButton(
                              tooltip: singleSource
                                  ? 'Show all sources'
                                  : 'Isolate selected source',
                              color: _mint,
                              onPressed: () =>
                                  setState(() => singleSource = !singleSource),
                              icon: Icon(singleSource
                                  ? Icons.filter_center_focus
                                  : Icons.filter_alt_outlined)),
                          IconButton(
                              tooltip: 'Clear cloud selection',
                              color: Colors.white70,
                              onPressed: () => widget.onSelect(null),
                              icon: const Icon(Icons.close)),
                        ]))),
              if (widget.devices.isNotEmpty)
                SizedBox(
                    height: 54,
                    child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 8),
                        itemCount: widget.devices.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final d = widget.devices[i];
                          return OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: d.key == widget.selected
                                      ? _mint
                                      : Colors.white70,
                                  side: BorderSide(
                                      color: d.key == widget.selected
                                          ? _mint
                                          : const Color(0xFF29443C))),
                              onPressed: () => widget.onSelect(d.key),
                              child: Text(d.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis));
                        })),
              Padding(
                  padding: EdgeInsets.fromLTRB(18, 4, 18, compact ? 80 : 95),
                  child: Text(
                      widget.status.isEmpty
                          ? 'Signals build the cloud as observations arrive. No camera or LiDAR is active.'
                          : widget.status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFF91A8A3), fontSize: 10))),
            ])));
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot(this.color, this.text);
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ]);
}

Offset _project(
    double x, double y, double z, Size size, double yaw, double tilt) {
  final rx = x * math.cos(yaw) - z * math.sin(yaw);
  final rz = x * math.sin(yaw) + z * math.cos(yaw);
  final ry = y * math.cos(tilt) - rz * math.sin(tilt);
  final depth = y * math.sin(tilt) + rz * math.cos(tilt);
  final scale = math.min(size.width * 0.39, size.height * 0.52) *
      2.7 /
      (2.7 + depth * 0.4);
  return Offset(size.width / 2 + rx * scale, size.height * 0.49 - ry * scale);
}

class _CloudPainter extends CustomPainter {
  _CloudPainter(
      {required this.points,
      required this.yaw,
      required this.tilt,
      required this.selected,
      required this.sweep,
      required this.scanning})
      : super(repaint: sweep);
  final List<CloudPoint> points;
  final double yaw, tilt;
  final String? selected;
  final Animation<double> sweep;
  final bool scanning;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFF16342B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final radius in [0.22, 0.5, 0.75, 1.0]) {
      final path = Path();
      for (var i = 0; i <= 80; i++) {
        final a = i / 80 * math.pi * 2;
        final p = _project(
            math.cos(a) * radius, -0.5, math.sin(a) * radius, size, yaw, tilt);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, grid);
    }
    for (var i = 0; i < 12; i++) {
      final a = i / 12 * math.pi * 2;
      canvas.drawLine(_project(0, -0.5, 0, size, yaw, tilt),
          _project(math.cos(a), -0.5, math.sin(a), size, yaw, tilt), grid);
    }
    final beamAngle = sweep.value * math.pi * 2;
    if (scanning) {
      canvas.drawLine(
          _project(0, -0.5, 0, size, yaw, tilt),
          _project(
              math.cos(beamAngle), -0.5, math.sin(beamAngle), size, yaw, tilt),
          Paint()
            ..color = _mint.withOpacity(0.5)
            ..strokeWidth = 1.3);
    }
    // Every luminous dot corresponds to one observed RSSI sample.
    for (final p in points) {
      final screen = _project(p.x, p.y, p.z, size, yaw, tilt);
      final chosen = p.key == selected;
      final opacity =
          (0.15 + p.freshness * 0.75) * (selected == null || chosen ? 1 : 0.3);
      canvas.drawCircle(screen, chosen ? 6 : 3.5,
          Paint()..color = p.color.withOpacity(opacity * 0.1));
      canvas.drawCircle(screen, chosen ? 2 : 1.25,
          Paint()..color = p.color.withOpacity(opacity));
    }
    for (final entry in <double, String>{
      0.22: '−30',
      0.5125: '−60',
      1: '−110 dBm'
    }.entries) {
      final p = _project(entry.key, -0.5, 0, size, yaw, tilt);
      final text = TextPainter(
          text: TextSpan(
              text: entry.value,
              style: const TextStyle(
                  color: Color(0xFF6D9384),
                  fontSize: 9,
                  fontFamily: 'monospace')),
          textDirection: TextDirection.ltr)
        ..layout();
      text.paint(canvas, p + const Offset(3, 5));
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter oldDelegate) => true;
}

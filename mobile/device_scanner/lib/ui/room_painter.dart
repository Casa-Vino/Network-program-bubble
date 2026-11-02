import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/room_map.dart';
import '../models/wall_fit.dart';

class RoomPainter extends CustomPainter {
  RoomPainter(
      this.map,
      this.walls,
      this.center,
      this.yaw,
      this.tilt,
      this.zoom,
      this.sourceFilter,
      this.showPoints,
      this.showWalls,
      this.showSignals,
      this.opacity,
      this.pointSize);
  final RoomMap map;
  final List<WallPolygon> walls;
  final RoomPoint? center;
  final double yaw, tilt, zoom, opacity, pointSize;
  final String sourceFilter;
  final bool showPoints, showWalls, showSignals;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final origin = center ?? map.phone ?? const RoomPoint(0, 0, 0);
    final cy = math.cos(yaw),
        sy = math.sin(yaw),
        ct = math.cos(tilt),
        st = math.sin(tilt);
    Offset project(RoomPoint p) {
      final x = p.x - origin.x, y = p.y - origin.y, z = p.z - origin.z;
      return Offset(size.width / 2 + (x * cy - z * sy) * zoom,
          size.height / 2 - (y * ct - (x * sy + z * cy) * st) * zoom);
    }

    final grid = Paint()
      ..color = const Color(0xFF16342B)
      ..strokeWidth = .7;
    for (var i = -5; i <= 5; i++) {
      canvas.drawLine(project(RoomPoint(origin.x + i, 0, origin.z - 5)),
          project(RoomPoint(origin.x + i, 0, origin.z + 5)), grid);
      canvas.drawLine(project(RoomPoint(origin.x - 5, 0, origin.z + i)),
          project(RoomPoint(origin.x + 5, 0, origin.z + i)), grid);
    }
    if (showWalls) {
      double depth(WallPolygon w) =>
          w.vertices.fold<double>(
              0,
              (s, p) =>
                  s +
                  (p.y - origin.y) * st +
                  ((p.x - origin.x) * sy + (p.z - origin.z) * cy) * ct) /
          w.vertices.length;
      final sorted = List<WallPolygon>.of(walls)
        ..sort((a, b) => depth(b).compareTo(depth(a)));
      for (var i = 0; i < sorted.length; i++) {
        final wall = sorted[i];
        final first = project(wall.vertices.first),
            path = Path()..moveTo(first.dx, first.dy);
        for (final v in wall.vertices.skip(1)) {
          final p = project(v);
          path.lineTo(p.dx, p.dy);
        }
        path.close();
        canvas.drawPath(path, Paint()..color = Colors.amber.withOpacity(.18));
        canvas.drawPath(
            path,
            Paint()
              ..color = Colors.amberAccent
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6);
        final text = TextPainter(
            text: TextSpan(
                text:
                    'Candidate ${i + 1} · ${(wall.rms * 100).toStringAsFixed(1)} cm fit',
                style: const TextStyle(
                    color: Colors.amberAccent,
                    fontFamily: 'Roboto',
                    fontSize: 10,
                    backgroundColor: Colors.black)),
            textDirection: TextDirection.ltr)
          ..layout();
        final centroid = RoomPoint(
            wall.vertices.fold<double>(0, (s, p) => s + p.x) /
                wall.vertices.length,
            wall.vertices.fold<double>(0, (s, p) => s + p.y) /
                wall.vertices.length,
            wall.vertices.fold<double>(0, (s, p) => s + p.z) /
                wall.vertices.length);
        final label = project(centroid);
        text.paint(
            canvas,
            Offset(
                (label.dx - text.width / 2)
                    .clamp(0, math.max(0, size.width - text.width)),
                label.dy.clamp(0, math.max(0, size.height - text.height))));
      }
    }
    if (showPoints) {
      final vertices = Float32List(map.surfaces.length * 2);
      var index = 0;
      for (final p in map.surfaces.values) {
        final x = p.x - origin.x, y = p.y - origin.y, z = p.z - origin.z;
        vertices[index++] = size.width / 2 + (x * cy - z * sy) * zoom;
        vertices[index++] =
            size.height / 2 - (y * ct - (x * sy + z * cy) * st) * zoom;
      }
      canvas.drawRawPoints(
          ui.PointMode.points,
          vertices,
          Paint()
            ..color = const Color(0xFF9AF8BE).withOpacity(opacity)
            ..strokeWidth = pointSize
            ..strokeCap = StrokeCap.round);
    }
    if (showSignals) {
      final shown = <String, RoomReading>{};
      for (final p in map.readings) {
        if (sourceFilter != '*' && p.sourceKey != sourceFilter) continue;
        shown[p.sourceKey] = p;
        final strength = ((p.rssi + 100) / 60).clamp(0.0, 1.0), v = project(p);
        canvas.drawCircle(v, 4.5, Paint()..color = Colors.black);
        canvas.drawCircle(
            v,
            3,
            Paint()
              ..color = sourceFilter == '*'
                  ? roomSourceColor(p.sourceKey)
                  : Color.lerp(Colors.cyan, Colors.deepOrange, strength)!);
      }
      // Latest reading per identity, capped to avoid crowding the display.
      for (final p in shown.values.take(8)) {
        final suffix = p.sourceKey.length > 8
            ? p.sourceKey.substring(p.sourceKey.length - 8)
            : p.sourceKey;
        final text = TextPainter(
            text: TextSpan(
                text: '$suffix ${p.rssi} dBm',
                style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'Roboto',
                    color: Colors.white,
                    backgroundColor: Colors.black)),
            textDirection: TextDirection.ltr)
          ..layout();
        text.paint(canvas, project(p) + const Offset(6, -14));
      }
    }
    if (map.phone != null) {
      canvas.drawCircle(project(map.phone!), 7, Paint()..color = Colors.black);
      canvas.drawCircle(
          project(map.phone!), 5, Paint()..color = Colors.blueAccent);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant RoomPainter oldDelegate) => true;
}

Color roomSourceColor(String key) {
  final hue = key.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0xffff) % 360;
  return HSVColor.fromAHSV(1, hue.toDouble(), .7, .95).toColor();
}

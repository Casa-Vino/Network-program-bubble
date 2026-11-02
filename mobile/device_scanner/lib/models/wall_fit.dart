import 'dart:math' as math;
import 'room_map.dart';

/// A supported convex patch on a vertical plane, not a surveyed wall boundary.
class WallPolygon {
  const WallPolygon(this.vertices, this.support, this.rms);
  final List<RoomPoint> vertices;
  final int support;
  final double rms;
}

/// Bounded, deterministic RANSAC on a 12 cm fitting copy. ARCore uses Y up.
/// Raw points are never altered. Horizontal surfaces and small furniture-sized
/// patches are rejected. Connected support avoids bridging separate patches;
/// convex boundaries can still span openings, so these remain candidate walls.
List<WallPolygon> fitWalls(List<RoomPoint> raw) {
  final random = math.Random(73);
  final cells = <String>{};
  var points = <RoomPoint>[];
  var count = 0;
  for (final p in raw) {
    if (![p.x, p.y, p.z].every((v) => v.isFinite)) continue;
    final key =
        '${(p.x / .12).floor()}:${(p.y / .12).floor()}:${(p.z / .12).floor()}';
    if (!cells.add(key)) continue;
    count++;
    if (points.length < 16000) {
      points.add(p);
    } else {
      final index = random.nextInt(count);
      if (index < points.length) points[index] = p;
    }
  }
  final result = <WallPolygon>[];
  for (var plane = 0; plane < 10 && points.length >= 60; plane++) {
    var best = <RoomPoint>[];
    var nx = 0.0, nz = 0.0, offset = 0.0;
    for (var iteration = 0; iteration < 180; iteration++) {
      final a = points[random.nextInt(points.length)];
      final b = points[random.nextInt(points.length)];
      final dx = b.x - a.x, dz = b.z - a.z;
      final length = math.sqrt(dx * dx + dz * dz);
      if (length < .5) continue;
      final x = -dz / length, z = dx / length;
      final d = -(x * a.x + z * a.z);
      final inliers =
          points.where((p) => (x * p.x + z * p.z + d).abs() <= .06).toList();
      if (inliers.length > best.length) {
        best = inliers;
        nx = x;
        nz = z;
        offset = d;
      }
    }
    if (best.length < 60) break;
    // Refine the normal by total least squares in the horizontal XZ plane.
    final mx = best.fold<double>(0, (s, p) => s + p.x) / best.length;
    final mz = best.fold<double>(0, (s, p) => s + p.z) / best.length;
    var xx = 0.0, zz = 0.0, xz = 0.0;
    for (final p in best) {
      xx += (p.x - mx) * (p.x - mx);
      zz += (p.z - mz) * (p.z - mz);
      xz += (p.x - mx) * (p.z - mz);
    }
    final angle = .5 * math.atan2(2 * xz, xx - zz);
    nx = -math.sin(angle);
    nz = math.cos(angle);
    offset = -(nx * mx + nz * mz);
    best = points
        .where((p) => (nx * p.x + nz * p.z + offset).abs() <= .06)
        .toList();
    // Remove this plane even if rejected, allowing other orientations to fit.
    final matched = best.toSet();
    points = points.where((p) => !matched.contains(p)).toList();
    final tx = nz, tz = -nx;
    final buckets = <(int, int), List<RoomPoint>>{};
    for (final p in best) {
      final key = (((p.x * tx + p.z * tz) / .24).floor(), (p.y / .24).floor());
      (buckets[key] ??= []).add(p);
    }
    while (buckets.isNotEmpty) {
      final queue = [buckets.keys.first];
      final component = <RoomPoint>[];
      for (var index = 0; index < queue.length; index++) {
        final key = queue[index];
        final group = buckets.remove(key);
        if (group == null) continue;
        component.addAll(group);
        for (var du = -1; du <= 1; du++) {
          for (var dy = -1; dy <= 1; dy++) {
            final adjacent = (key.$1 + du, key.$2 + dy);
            if (buckets.containsKey(adjacent)) queue.add(adjacent);
          }
        }
      }
      if (component.length < 60) continue;
      final uv = component.map((p) => (p.x * tx + p.z * tz, p.y)).toList();
      final hull = _hull(uv);
      if (hull.length < 3) continue;
      final width = uv.map((p) => p.$1).reduce(math.max) -
          uv.map((p) => p.$1).reduce(math.min);
      final height = uv.map((p) => p.$2).reduce(math.max) -
          uv.map((p) => p.$2).reduce(math.min);
      var area = 0.0;
      for (var i = 0; i < hull.length; i++) {
        final a = hull[i], b = hull[(i + 1) % hull.length];
        area += a.$1 * b.$2 - b.$1 * a.$2;
      }
      if (width < .7 || height < 1.2 || area.abs() / 2 < .8) continue;
      final rms = math.sqrt(component.fold<double>(0, (s, p) {
            final d = nx * p.x + nz * p.z + offset;
            return s + d * d;
          }) /
          component.length);
      result.add(WallPolygon(
          hull
              .map((p) => RoomPoint(
                  tx * p.$1 - nx * offset, p.$2, tz * p.$1 - nz * offset))
              .toList(),
          component.length,
          rms));
      if (result.length >= 24) return result;
    }
  }
  return result;
}

List<(double, double)> _hull(List<(double, double)> input) {
  final p = input.toSet().toList()
    ..sort(
        (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  if (p.length < 3) return p;
  double cross((double, double) a, (double, double) b, (double, double) c) =>
      (b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1);
  final lower = <(double, double)>[], upper = <(double, double)>[];
  for (final v in p) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, v) <= 0) {
      lower.removeLast();
    }
    lower.add(v);
  }
  for (final v in p.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, v) <= 0) {
      upper.removeLast();
    }
    upper.add(v);
  }
  return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
}

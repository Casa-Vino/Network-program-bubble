import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/room_map.dart';
import 'package:device_scanner/models/wall_fit.dart';

void main() {
  test('fits two noisy perpendicular Y-up walls and ignores floor/outliers',
      () {
    final random = Random(2);
    double noise() => (random.nextDouble() - .5) * .025;
    final points = <RoomPoint>[];
    for (var u = 0; u <= 30; u++) {
      for (var v = 0; v <= 25; v++) {
        points.add(RoomPoint(u * .1, v * .1, noise()));
        points.add(RoomPoint(3 + noise(), v * .1, u * .1));
        points.add(RoomPoint(u * .1, noise(), v * .1));
      }
    }
    for (var i = 0; i < 100; i++) {
      points.add(RoomPoint(random.nextDouble() * 4, random.nextDouble() * 3,
          random.nextDouble() * 4));
    }
    final originalCount = points.length;
    final walls = fitWalls(points);
    expect(walls.length, greaterThanOrEqualTo(2));
    expect(walls.any((w) => w.vertices.every((p) => p.z.abs() < .06)), isTrue);
    expect(walls.any((w) => w.vertices.every((p) => (p.x - 3).abs() < .06)),
        isTrue);
    for (final w in walls) {
      expect(w.rms, lessThan(.06));
      expect(
          w.vertices.map((p) => p.y).reduce(max) -
              w.vertices.map((p) => p.y).reduce(min),
          greaterThanOrEqualTo(1.2));
    }
    expect(points.length, originalCount);
  });
  test('does not invent walls from floors, empty data or low furniture', () {
    expect(fitWalls([]), isEmpty);
    final floor = <RoomPoint>[], furniture = <RoomPoint>[];
    for (var x = 0; x < 35; x++) {
      for (var z = 0; z < 35; z++) {
        floor.add(RoomPoint(x * .1, 0, z * .1));
      }
      for (var y = 0; y < 9; y++) {
        furniture.add(RoomPoint(x * .1, y * .1, 0));
      }
    }
    expect(fitWalls(floor), isEmpty);
    expect(fitWalls(furniture), isEmpty);
  });
  test('separated coplanar patches remain separate polygons', () {
    final points = <RoomPoint>[];
    for (final offset in [0.0, 4.0]) {
      for (var x = 0; x <= 15; x++) {
        for (var y = 0; y <= 25; y++) {
          points.add(RoomPoint(offset + x * .1, y * .1, 0));
        }
      }
    }
    final walls = fitWalls(points);
    expect(walls.length, 2);
    for (final w in walls) {
      expect(
          w.vertices.map((p) => p.x).reduce(max) -
              w.vertices.map((p) => p.x).reduce(min),
          lessThan(2));
    }
  });
}

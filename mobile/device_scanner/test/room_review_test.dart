import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/room_map.dart';
import 'package:device_scanner/models/room_review.dart';

void main() {
  test(
      'display budget samples across the capture without discarding stored points',
      () {
    final points = List.generate(300000, (i) => RoomPoint(i.toDouble(), 0, 0));
    final sampled = sampleForDisplay(points, points.length, 60000);
    expect(sampled.length, 60000);
    expect(sampled.first.x, 0);
    expect(sampled.last.x, greaterThan(299990));
    expect(points.length, 300000);
    expect(sampleForDisplay([], 0, 30), isEmpty);
    expect(
        () => sampleForDisplay(points, points.length, 0), throwsArgumentError);
  });
  test('review filter removes isolated cells and retains a supported surface',
      () {
    final wall = <RoomPoint>[];
    for (var x = 0; x <= 20; x++) {
      for (var y = 0; y <= 20; y++) {
        wall.add(RoomPoint(x * .05, y * .05, 0));
      }
    }
    final points = [
      ...wall,
      const RoomPoint(50, 50, 50),
      const RoomPoint(-50, -50, -50)
    ];
    final filtered = supportedReviewPoints(points);
    expect(filtered.length, wall.length);
    expect(points.length, wall.length + 2);
    expect(supportedReviewPoints([]), isEmpty);
  });
  test(
      'strongest mapped reading is per-device and distinct from the latest reading',
      () {
    final time = DateTime(2026);
    final first = RoomReading(1, 0, 0, -45, time, sourceKey: 'keys');
    final latest = RoomReading(
        2, 0, 0, -75, time.add(const Duration(seconds: 1)),
        sourceKey: 'keys');
    final other = RoomReading(3, 0, 0, -30, time, sourceKey: 'other');
    final summary = RoomSignalSummary([other, latest, first], 'keys');
    expect(summary.count, 2);
    expect(summary.best, same(first));
    expect(summary.latest, same(latest));
    expect(RoomSignalSummary([first], 'missing').best, isNull);
  });
}

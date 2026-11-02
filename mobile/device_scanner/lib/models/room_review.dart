import 'room_map.dart';

/// Evenly thin only the display copy. Capture, fitting and exports stay intact.
List<RoomPoint> sampleForDisplay(
    Iterable<RoomPoint> points, int count, int budget) {
  if (budget < 1) throw ArgumentError.value(budget, 'budget');
  final step = (count / budget).ceil().clamp(1, 1 << 30);
  var index = 0;
  return [
    for (final p in points)
      if (index++ % step == 0) p
  ];
}

/// Optional review filter: retain clusters with support in three neighbouring
/// 20 cm cells and at least five points. Does not modify the saved geometry.
List<RoomPoint> supportedReviewPoints(List<RoomPoint> points) {
  final cells = <(int, int, int), List<RoomPoint>>{};
  for (final p in points) {
    final key = ((p.x / .2).floor(), (p.y / .2).floor(), (p.z / .2).floor());
    (cells[key] ??= []).add(p);
  }
  final result = <RoomPoint>[];
  for (final entry in cells.entries) {
    final key = entry.key;
    var neighbours = 0, support = 0;
    for (var x = -1; x <= 1; x++) {
      for (var y = -1; y <= 1; y++) {
        for (var z = -1; z <= 1; z++) {
          final cell = cells[(key.$1 + x, key.$2 + y, key.$3 + z)];
          if (cell != null) {
            neighbours++;
            support += cell.length;
          }
        }
      }
    }
    if (neighbours >= 3 && support >= 5) result.addAll(entry.value);
  }
  return result;
}

class RoomSignalSummary {
  RoomSignalSummary(Iterable<RoomReading> readings, String key) {
    for (final r in readings) {
      if (r.sourceKey != key) continue;
      count++;
      if (best == null || r.rssi > best!.rssi) best = r;
      if (latest == null || r.time.isAfter(latest!.time)) latest = r;
    }
  }
  int count = 0;
  RoomReading? best, latest;
}

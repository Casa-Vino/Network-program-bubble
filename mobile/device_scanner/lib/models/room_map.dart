import 'radio_device.dart';

class RoomPoint {
  const RoomPoint(this.x, this.y, this.z);
  final double x, y, z;
}

class RoomReading extends RoomPoint {
  const RoomReading(super.x, super.y, super.z, this.rssi, this.time,
      {this.sourceKey = '', this.sourceName = ''});
  final String sourceKey, sourceName;
  final int rssi;
  final DateTime time;
}

class RoomMap {
  RoomMap({this.maxSurfacePoints = 150000});
  final surfaces = <String, RoomPoint>{};
  final readings = <RoomReading>[];
  final readingCounts = <String, int>{};
  RoomPoint? phone;
  bool tracking = false;
  int surfaceRevision = 0;
  int maxSurfacePoints;
  void setSurfaceLimit(int limit) {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    maxSurfacePoints = limit;
    surfaceRevision++;
    while (surfaces.length > limit) {
      surfaces.remove(surfaces.keys.first);
    }
  }

  static const maxSignalReadings = 8000;
  final lastReadings = <String, DateTime>{};

  void frame(Map<dynamic, dynamic> event, RadioDevice? source,
      {Iterable<RadioDevice>? sources}) {
    tracking = event['tracking'] == true;
    if (!tracking) return;
    final coordinates = event['pose'];
    if (coordinates is! List || coordinates.length != 3) return;
    final p = coordinates.map((n) => (n as num).toDouble()).toList();
    if (p.any((n) => !n.isFinite)) return;
    phone = RoomPoint(p[0], p[1], p[2]);
    final points = event['points'];
    if (points is List) {
      surfaceRevision++;
      for (var i = 0; i + 2 < points.length; i += 3) {
        final x = (points[i] as num).toDouble(),
            y = (points[i + 1] as num).toDouble(),
            z = (points[i + 2] as num).toDouble();
        if (![x, y, z].every((n) => n.isFinite)) continue;
        final key =
            '${(x / 0.05).round()}:${(y / 0.05).round()}:${(z / 0.05).round()}';
        surfaces[key] = RoomPoint(x, y, z);
        if (surfaces.length > maxSurfacePoints) {
          surfaces.remove(surfaces.keys.first);
        }
      }
    }
    if (event['time'] is! num) {
      return;
    }
    final time =
        DateTime.fromMillisecondsSinceEpoch((event['time'] as num).toInt());
    for (final device
        in sources ?? (source == null ? <RadioDevice>[] : [source])) {
      if (device.history.isEmpty) continue;
      final sample = device.latest;
      final lastReading = lastReadings[device.key];
      // Never pin cached Wi-Fi data or the same radio sample to a new position.
      if (time.difference(sample.time).inMilliseconds.abs() > 500 ||
          lastReading != null && !sample.time.isAfter(lastReading)) continue;
      lastReadings[device.key] = sample.time;
      readings.add(RoomReading(p[0], p[1], p[2], sample.rssi, sample.time,
          sourceKey: device.key, sourceName: device.label));
      readingCounts.update(device.key, (count) => count + 1, ifAbsent: () => 1);
      if (readings.length > maxSignalReadings) {
        final old = readings.removeAt(0);
        final count = (readingCounts[old.sourceKey] ?? 1) - 1;
        if (count == 0) {
          readingCounts.remove(old.sourceKey);
        } else {
          readingCounts[old.sourceKey] = count;
        }
      }
    }
  }
}

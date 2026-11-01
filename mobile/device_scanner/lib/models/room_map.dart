import 'radio_device.dart';

class RoomPoint {
  const RoomPoint(this.x, this.y, this.z);
  final double x, y, z;
}

class RoomReading extends RoomPoint {
  const RoomReading(super.x, super.y, super.z, this.rssi, this.time);
  final int rssi;
  final DateTime time;
}

class RoomMap {
  final surfaces = <String, RoomPoint>{};
  final readings = <RoomReading>[];
  RoomPoint? phone;
  bool tracking = false;
  DateTime? lastReading;

  void frame(Map<dynamic, dynamic> event, RadioDevice? source) {
    tracking = event['tracking'] == true;
    if (!tracking) return;
    final coordinates = event['pose'];
    if (coordinates is! List || coordinates.length != 3) return;
    final p = coordinates.map((n) => (n as num).toDouble()).toList();
    if (p.any((n) => !n.isFinite)) return;
    phone = RoomPoint(p[0], p[1], p[2]);
    final points = event['points'];
    if (points is List) {
      for (var i = 0; i + 2 < points.length; i += 3) {
        final x = (points[i] as num).toDouble(),
            y = (points[i + 1] as num).toDouble(),
            z = (points[i + 2] as num).toDouble();
        if (![x, y, z].every((n) => n.isFinite)) continue;
        final key =
            '${(x / 0.05).round()}:${(y / 0.05).round()}:${(z / 0.05).round()}';
        surfaces[key] = RoomPoint(x, y, z);
        if (surfaces.length > 15000) surfaces.remove(surfaces.keys.first);
      }
    }
    if (source == null || source.history.isEmpty || event['time'] is! num) {
      return;
    }
    final time =
        DateTime.fromMillisecondsSinceEpoch((event['time'] as num).toInt());
    final sample = source.latest;
    // Never pin cached Wi-Fi data or the same radio sample to a new position.
    if (time.difference(sample.time).inMilliseconds.abs() > 500 ||
        lastReading != null && !sample.time.isAfter(lastReading!)) return;
    lastReading = sample.time;
    readings.add(RoomReading(p[0], p[1], p[2], sample.rssi, sample.time));
    if (readings.length > 2000) readings.removeAt(0);
  }
}

import 'dart:convert';
import 'room_map.dart';
import 'wall_fit.dart';

class SavedRoom {
  SavedRoom(this.created, this.points, this.readings, this.phone,
      {this.walls = const []});
  final DateTime created;
  final List<RoomPoint> points;
  final List<RoomReading> readings;
  final RoomPoint? phone;
  final List<WallPolygon> walls;
  SavedRoom withWalls(List<WallPolygon> value) =>
      SavedRoom(created, points, readings, phone, walls: value);
  RoomMap toMap() {
    final map = RoomMap();
    for (var i = 0; i < points.length; i++) {
      map.surfaces['saved:$i'] = points[i];
    }
    map.phone = phone;
    map.readings.addAll(readings);
    for (final r in readings) {
      map.readingCounts.update(r.sourceKey, (n) => n + 1, ifAbsent: () => 1);
    }
    return map;
  }
}

String encodeRoom(SavedRoom room) {
  List<double> xyz(RoomPoint p) => [p.x, p.y, p.z];
  return jsonEncode({
    'version': 1,
    'units': 'm',
    'frame': 'anchor-y-up-v1',
    'created': room.created.toIso8601String(),
    'points': room.points.expand(xyz).toList(),
    'phone': room.phone == null ? null : xyz(room.phone!),
    'readings': room.readings
        .map((r) => {
              'p': xyz(r),
              'rssi': r.rssi,
              'time': r.time.toIso8601String(),
              'key': r.sourceKey,
              'name': r.sourceName
            })
        .toList(),
    'walls': room.walls
        .map((w) => {
              'vertices': w.vertices.map(xyz).toList(),
              'support': w.support,
              'rms': w.rms
            })
        .toList()
  });
}

SavedRoom decodeRoom(String text) {
  final j = jsonDecode(text) as Map<String, dynamic>;
  if (j['version'] != 1 ||
      j['units'] != 'm' ||
      j['frame'] != 'anchor-y-up-v1') {
    throw const FormatException('Unsupported room scan format');
  }
  double finite(dynamic n) {
    if (n is! num || !n.isFinite) {
      throw const FormatException('Invalid coordinate');
    }
    return n.toDouble();
  }

  RoomPoint xyz(dynamic p) {
    if (p is! List || p.length != 3) {
      throw const FormatException('Invalid XYZ point');
    }
    return RoomPoint(finite(p[0]), finite(p[1]), finite(p[2]));
  }

  final flat = j['points'] as List;
  final readings = j['readings'] as List;
  final walls = j['walls'] as List;
  if (flat.length % 3 != 0 ||
      flat.length > 900000 ||
      readings.length > 8000 ||
      walls.length > 24) {
    throw const FormatException('Invalid scan size');
  }
  return SavedRoom(
      DateTime.parse(j['created'] as String),
      [for (var i = 0; i < flat.length; i += 3) xyz(flat.sublist(i, i + 3))],
      readings.map((dynamic r) {
        final p = xyz(r['p']);
        final rssi = r['rssi'] as int;
        if (rssi < -127 || rssi > -1) {
          throw const FormatException('Invalid RSSI');
        }
        return RoomReading(
            p.x, p.y, p.z, rssi, DateTime.parse(r['time'] as String),
            sourceKey: r['key'] as String, sourceName: r['name'] as String);
      }).toList(),
      j['phone'] == null ? null : xyz(j['phone']),
      walls: walls.map((dynamic w) {
        final vertices = w['vertices'] as List;
        final support = w['support'] as int, rms = finite(w['rms']);
        if (vertices.length < 3 ||
            vertices.length > 10000 ||
            support < 3 ||
            rms < 0) {
          throw const FormatException('Invalid wall polygon');
        }
        return WallPolygon(vertices.map(xyz).toList(), support, rms);
      }).toList());
}

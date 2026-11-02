import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/room_map.dart';
import 'package:device_scanner/models/saved_room.dart';
import 'package:device_scanner/models/wall_fit.dart';
import 'package:device_scanner/services/room_store.dart';

void main() {
  final date = DateTime(2026, 11, 2, 13);
  SavedRoom sample() => SavedRoom(
      date,
      [const RoomPoint(1, 2, 3)],
      [
        RoomReading(1, 1, 1, -62, date,
            sourceKey: 'bluetooth:AB', sourceName: 'Keys')
      ],
      const RoomPoint(0, 0, 0),
      walls: [
        const WallPolygon(
            [RoomPoint(0, 0, 0), RoomPoint(2, 0, 0), RoomPoint(2, 2, 0)],
            85,
            .02)
      ]);
  test(
      'saved snapshot preserves geometry, identities, phone pose and wall polygons',
      () {
    final room = decodeRoom(encodeRoom(sample()));
    expect(room.points.single.z, 3);
    expect(room.readings.single.sourceKey, 'bluetooth:AB');
    expect(room.readings.single.time, date);
    expect(room.walls.single.vertices.length, 3);
    expect(room.walls.single.rms, .02);
    expect(room.toMap().readingCounts['bluetooth:AB'], 1);
    expect(room.toMap().tracking, isFalse);
  });
  test('rejects incompatible frames and malformed/nonfinite coordinates', () {
    final j = jsonDecode(encodeRoom(sample())) as Map<String, dynamic>;
    j['frame'] = 'unknown';
    expect(() => decodeRoom(jsonEncode(j)), throwsFormatException);
    j['frame'] = 'anchor-y-up-v1';
    j['points'] = [1, 2];
    expect(() => decodeRoom(jsonEncode(j)), throwsFormatException);
    j['points'] = [1, 'NaN', 3];
    expect(() => decodeRoom(jsonEncode(j)), throwsFormatException);
  });
  test('atomic save can replace a raw snapshot and reopen the fitted version',
      () async {
    final dir = await Directory.systemTemp.createTemp('bubble-room-test');
    addTearDown(() => dir.delete(recursive: true));
    final store = RoomStore(directory: dir), room = sample();
    await store.save(room.withWalls([]));
    await store.save(room);
    final files = await store.list();
    expect(files.length, 1);
    expect((await store.load(files.single)).walls.length, 1);
    expect(await dir.list().any((e) => e.path.endsWith('.tmp')), isFalse);
  });
}

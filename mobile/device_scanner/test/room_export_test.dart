import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/room_map.dart';
import 'package:device_scanner/models/saved_room.dart';
import 'package:device_scanner/models/wall_fit.dart';
import 'package:device_scanner/models/room_export.dart';

void main() {
  final time = DateTime.utc(2026, 11, 2);
  final room = SavedRoom(
      time,
      [const RoomPoint(1, 2, 3), const RoomPoint(4, 5, 6)],
      [
        RoomReading(1, 2, 3, -55, time,
            sourceKey: 'wifi:AB', sourceName: '=HYPERLINK("bad")')
      ],
      const RoomPoint(0, 0, 0),
      walls: [
        const WallPolygon(
            [RoomPoint(0, 0, 0), RoomPoint(1, 0, 0), RoomPoint(1, 2, 0)],
            70,
            .02),
        const WallPolygon(
            [RoomPoint(0, 0, 1), RoomPoint(1, 0, 1), RoomPoint(1, 2, 1)],
            80,
            .03)
      ]);
  test('full export round trips the complete snapshot', () {
    final text = exportRoomText(RoomExportRequest(room, RoomExport.snapshot));
    final restored = decodeRoom(text);
    expect(restored.points.length, 2);
    expect(restored.walls.length, 2);
    expect(
        restored.readings.single.sourceName, room.readings.single.sourceName);
  });
  test('PLY declares the exact raw vertex count and Y-up metre coordinates',
      () {
    final text = exportRoomText(RoomExportRequest(room, RoomExport.points));
    expect(text, startsWith('ply\nformat ascii 1.0\n'));
    expect(text, contains('element vertex 2\n'));
    expect(text.split('end_header\n').last.trim().split('\n'),
        ['1.0 2.0 3.0', '4.0 5.0 6.0']);
  });
  test('OBJ keeps face indices valid across multiple candidate polygons', () {
    final text = exportRoomText(RoomExportRequest(room, RoomExport.walls));
    final lines = text.split('\n');
    expect(lines.where((l) => l.startsWith('v ')).length, 6);
    expect(lines.where((l) => l.startsWith('f ')), ['f 1 2 3', 'f 4 5 6']);
    expect(text, contains('Not surveyed walls'));
  });
  test('CSV identifies measurement positions and escapes names as safe text',
      () {
    final text = exportRoomText(RoomExportRequest(room, RoomExport.signals));
    expect(text, contains('phone_x_m,phone_y_m,phone_z_m'));
    expect(text, contains('"\'=HYPERLINK(""bad"")"'));
    expect(text, contains(',-55,1.0,2.0,3.0\r\n'));
  });
}

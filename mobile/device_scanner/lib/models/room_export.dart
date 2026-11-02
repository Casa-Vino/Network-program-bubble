import 'dart:convert';
import 'dart:typed_data';
import 'saved_room.dart';

enum RoomExport {
  snapshot('json', 'Full scan JSON'),
  points('ply', 'Captured points PLY'),
  walls('obj', 'Candidate walls OBJ'),
  signals('csv', 'Signal measurements CSV');

  const RoomExport(this.extension, this.label);
  final String extension, label;
}

class RoomExportRequest {
  const RoomExportRequest(this.room, this.format);
  final SavedRoom room;
  final RoomExport format;
}

Uint8List exportRoom(RoomExportRequest request) =>
    Uint8List.fromList(utf8.encode(exportRoomText(request)));
String exportRoomText(RoomExportRequest request) {
  final room = request.room;
  switch (request.format) {
    case RoomExport.snapshot:
      return encodeRoom(room);
    case RoomExport.points:
      final out = StringBuffer(
          'ply\nformat ascii 1.0\ncomment Bubble captured points; metres; anchor-relative Y up\nelement vertex ${room.points.length}\nproperty double x\nproperty double y\nproperty double z\nend_header\n');
      for (final p in room.points) {
        out.writeln('${p.x} ${p.y} ${p.z}');
      }
      return out.toString();
    case RoomExport.walls:
      final out = StringBuffer(
          '# Bubble candidate vertical surfaces; metres; Y up\n# Estimates may include furniture and span openings. Not surveyed walls.\n');
      var index = 1;
      for (var i = 0; i < room.walls.length; i++) {
        final wall = room.walls[i];
        out.writeln('g candidate_wall_${i + 1}');
        out.writeln('# support ${wall.support}; fit_residual_m ${wall.rms}');
        for (final p in wall.vertices) {
          out.writeln('v ${p.x} ${p.y} ${p.z}');
        }
        out.writeln(
            'f ${List.generate(wall.vertices.length, (j) => index + j).join(' ')}');
        index += wall.vertices.length;
      }
      return out.toString();
    case RoomExport.signals:
      // Network-provided names are text, never spreadsheet formulas.
      String csv(String value) {
        final safe = RegExp(r'^\s*[=+@-]').hasMatch(value) ? "'$value" : value;
        return '"${safe.replaceAll('"', '""')}"';
      }
      final out = StringBuffer(
          'time,source_key,source_name,rssi_dbm,phone_x_m,phone_y_m,phone_z_m\r\n');
      for (final r in room.readings) {
        out.write(
            '${csv(r.time.toIso8601String())},${csv(r.sourceKey)},${csv(r.sourceName)},${r.rssi},${r.x},${r.y},${r.z}\r\n');
      }
      return out.toString();
  }
}

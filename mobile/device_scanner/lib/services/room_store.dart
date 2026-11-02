import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/saved_room.dart';

/// App-private snapshots. Write a flushed temporary file then atomically rename.
class RoomStore {
  RoomStore({this.directory});
  final Directory? directory;
  Future<Directory> _folder() async => (directory ??
          Directory(
              '${(await getApplicationDocumentsDirectory()).path}/room_scans'))
      .create(recursive: true);
  Future<List<File>> list() async {
    final folder = await _folder();
    final files = await folder
        .list()
        .where((e) => e is File && e.path.endsWith('.bubble.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> save(SavedRoom room) async {
    final folder = await _folder();
    final file = File(
        '${folder.path}/${room.created.microsecondsSinceEpoch}.bubble.json');
    final temp = File('${file.path}.tmp');
    final text = await compute(encodeRoom, room);
    try {
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<SavedRoom> load(File file) async =>
      compute(decodeRoom, await file.readAsString());
}

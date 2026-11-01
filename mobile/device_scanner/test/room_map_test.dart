import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/radio_device.dart';
import 'package:device_scanner/models/room_map.dart';

void main() {
  RadioDevice source(int time) => RadioDevice('Keys', false)
    ..update({
      'kind': 'ble',
      'name': 'Keys',
      'detail': '',
      'rssi': -60,
      'time': time,
    });
  Map<String, Object> frame(int time, {bool tracking = true}) => {
        'tracking': tracking,
        'time': time,
        'pose': [1.0, 2.0, 3.0],
        'points': [0.0, 0.0, -1.0, 0.001, 0.001, -1.001],
      };
  test('fresh signals attach to phone position once, never to the surface', () {
    final map = RoomMap();
    final device = source(1000);
    map.frame(frame(1100), device);
    expect(map.readings.length, 1);
    expect(map.readings.single.x, 1);
    expect(map.readings.single.z, 3);
    expect(map.surfaces.length, 1);
    map.frame(frame(1200), device);
    expect(map.readings.length, 1);
  });
  test('cached signals and tracking loss cannot create spatial readings', () {
    final map = RoomMap();
    final device = source(1000);
    map.frame(frame(2000), device);
    expect(map.readings, isEmpty);
    map.frame(frame(1000, tracking: false), device);
    expect(map.tracking, isFalse);
    expect(map.readings, isEmpty);
  });
  test('surface storage is voxel deduplicated and bounded', () {
    final map = RoomMap(maxSurfacePoints: 60000);
    final data = frame(1000);
    data['points'] = [
      for (var i = 0; i < 61000; i++) ...[i * 0.1, 0.0, 0.0]
    ];
    map.frame(data, null);
    expect(map.surfaces.length, 60000);
    expect(map.readings, isEmpty);
  });
  test('surface limit can increase and decrease without clearing signals', () {
    final map = RoomMap(maxSurfacePoints: 1);
    final data = frame(1000);
    data['points'] = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0];
    map.frame(data, source(1000));
    expect(map.surfaces.length, 1);
    map.setSurfaceLimit(3);
    map.frame(data, null);
    expect(map.surfaces.length, 2);
    map.setSurfaceLimit(1);
    expect(map.surfaces.length, 1);
    expect(map.readings.length, 1);
  });

  test('multiple sources retain separate identities and duplicate guards', () {
    final map = RoomMap();
    final first = source(1000);
    final second = RadioDevice('Other', false)
      ..update({
        'kind': 'ble',
        'name': 'Other',
        'detail': '',
        'rssi': -80,
        'time': 1000
      });
    map.frame(frame(1100), null, sources: [first, second]);
    expect(map.readings.length, 2);
    expect(map.readingCounts, {first.key: 1, second.key: 1});
    expect(
        map.readings.map((r) => r.sourceKey).toSet(), {first.key, second.key});
    map.frame(frame(1200), null, sources: [first, second]);
    expect(map.readings.length, 2);
  });
}

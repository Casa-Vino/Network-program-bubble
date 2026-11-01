import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/models/radio_device.dart';

Map<String, Object> observation(int time, int rssi, {String kind = 'ble'}) => {
      'kind': kind,
      'name': 'Keys',
      'detail': 'advertisement',
      'time': time,
      'rssi': rssi,
    };

void main() {
  test('cached or out-of-order readings cannot refresh last seen or trend', () {
    final device = RadioDevice('AA:BB', true);
    device.update(observation(1000, -70, kind: 'wifi'));
    device.update(observation(1000, -50, kind: 'wifi'));
    device.update(observation(900, -40, kind: 'wifi'));
    expect(device.history.length, 1);
    expect(device.latest.rssi, -70);
    expect(device.latest.time.millisecondsSinceEpoch, 1000);
  });
  test('same Bluetooth address can carry both discovery methods', () {
    final device = RadioDevice('AA:BB', false);
    device.update(observation(1000, -80));
    device.update(observation(2000, -75, kind: 'classic'));
    expect(device.methods, {'ble', 'classic'});
    expect(device.key, 'bluetooth:AA:BB');
    expect(RadioDevice('AA:BB', true).key, isNot(device.key));
  });
  test('trend requires enough evidence and distinguishes stronger and weaker',
      () {
    final device = RadioDevice('tag', false);
    for (var i = 0; i < 3; i++) {
      device.update(observation(i + 1, -85));
    }
    expect(device.trend, 'Collecting signal samples');
    for (var i = 0; i < 3; i++) {
      device.update(observation(i + 4, -65));
    }
    expect(device.trend, contains('warmer'));
    for (var i = 0; i < 3; i++) {
      device.update(observation(i + 7, -90));
    }
    expect(device.trend, contains('colder'));
  });
  test('history is bounded and invalid radio readings are excluded', () {
    final device = RadioDevice('tag', false);
    for (var i = 0; i < 140; i++) {
      device.update(observation(i, -70));
    }
    device.update(observation(200, 127));
    expect(device.history.length, 120);
    expect(device.history.first.time.millisecondsSinceEpoch, 20);
    expect(device.smoothed, -70);
  });
}

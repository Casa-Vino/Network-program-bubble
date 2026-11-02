class SignalSample {
  SignalSample(this.time, this.rssi);
  final DateTime time;
  final int rssi;
}

class RadioDevice {
  RadioDevice(this.address, this.isWifi);
  final String address;
  final bool isWifi;
  String name = '';
  String detail = '';
  final Set<String> methods = {};
  final List<SignalSample> history = [];

  String get key => '${isWifi ? 'wifi' : 'bluetooth'}:$address';
  String get label => name.isEmpty
      ? 'Unnamed ${isWifi ? 'access point' : 'Bluetooth device'}'
      : name;
  String get displayLabel =>
      '$label · ${address.length > 8 ? address.substring(address.length - 8) : address}';
  SignalSample get latest => history.last;
  double get smoothed =>
      history
          .skip(history.length > 5 ? history.length - 5 : 0)
          .map((s) => s.rssi)
          .reduce((a, b) => a + b) /
      (history.length > 5 ? 5 : history.length);

  void update(Map<dynamic, dynamic> event) {
    final kind = event['kind'] as String;
    methods.add(kind);
    final receivedName = event['name'] as String? ?? '';
    if (receivedName.isNotEmpty) name = receivedName;
    detail = event['detail'] as String? ?? '';
    final time =
        DateTime.fromMillisecondsSinceEpoch((event['time'] as num).toInt());
    final rssi = (event['rssi'] as num).toInt();
    if (rssi < -127 || rssi > -1) return;
    // Cached Wi-Fi results must not manufacture fresh samples or a false trend.
    if (history.isNotEmpty && !time.isAfter(latest.time)) return;
    history.add(SignalSample(time, rssi));
    if (history.length > 120) history.removeAt(0);
  }

  String get trend {
    if (history.length < 6) return 'Collecting signal samples';
    final recent = history.sublist(history.length - 3);
    final before = history.sublist(history.length - 6, history.length - 3);
    double average(List<SignalSample> s) =>
        s.map((v) => v.rssi).reduce((a, b) => a + b) / s.length;
    final change = average(recent) - average(before);
    if (change > 4) return 'Stronger signal · possibly warmer';
    if (change < -4) return 'Weaker signal · possibly colder';
    return 'Signal roughly steady';
  }
}

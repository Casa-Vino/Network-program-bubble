import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/radio_device.dart';

class NearbyPage extends StatefulWidget {
  const NearbyPage({super.key});
  @override
  State<NearbyPage> createState() => _NearbyPageState();
}

class _NearbyPageState extends State<NearbyPage> with WidgetsBindingObserver {
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const channel = MethodChannel('bubble/radio');
  static const events = EventChannel('bubble/radio/events');
  final devices = <String, RadioDevice>{};
  final messages = <String>[];
  StreamSubscription<dynamic>? subscription;
  Timer? clock;
  bool scanning = false;
  bool starting = false;
  String? selected;
  Map<dynamic, dynamic> capabilities = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_android) {
      subscription =
          events.receiveBroadcastStream().listen(onEvent, onError: (Object e) {
        if (mounted) {
          setState(() {
            scanning = false;
            addMessage('$e');
          });
        }
      });
      refreshCapabilities();
    }
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void addMessage(String text) {
    if (messages.isEmpty || messages.last != text) messages.add(text);
    if (messages.length > 12) messages.removeAt(0);
  }

  Future<void> refreshCapabilities() async {
    try {
      final value =
          await channel.invokeMapMethod<dynamic, dynamic>('capabilities');
      if (mounted) setState(() => capabilities = value ?? {});
    } catch (e) {
      if (mounted) setState(() => addMessage('Capability check: $e'));
    }
  }

  void onEvent(dynamic data) {
    if (!mounted || data is! Map) return;
    setState(() {
      if (data['type'] == 'stopped') {
        scanning = false;
        return;
      }
      if (data['type'] == 'status') {
        addMessage(data['message'] as String);
        return;
      }
      if (data['type'] != 'observation') return;
      final isWifi = data['kind'] == 'wifi';
      final address = data['address'] as String;
      final key = '${isWifi ? 'wifi' : 'bluetooth'}:$address';
      // BLE and Classic merge only when the observed address matches. Never guess
      // that a Wi-Fi address and a Bluetooth address belong to the same device.
      final device =
          devices.putIfAbsent(key, () => RadioDevice(address, isWifi));
      device.update(data);
    });
  }

  Future<void> start() async {
    if (starting || scanning) return;
    setState(() {
      starting = true;
      messages.clear();
    });
    try {
      final permissions = await [
        Permission.locationWhenInUse,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.nearbyWifiDevices
      ].request();
      if (!mounted) return;
      if (permissions.values.any((p) => !p.isGranted)) {
        setState(() => addMessage(
            'Some permissions are missing. Available methods will still be attempted; check capabilities.'));
      }
      setState(() => scanning = true);
      await channel.invokeMethod<void>('start');
    } catch (e) {
      if (mounted) {
        setState(() {
          scanning = false;
          addMessage('Could not start: $e');
        });
      }
    } finally {
      if (mounted) {
        setState(() => starting = false);
        await refreshCapabilities();
      }
    }
  }

  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } catch (e) {
      if (mounted) setState(() => addMessage('Stop: $e'));
    }
    if (mounted) setState(() => scanning = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _android) stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock?.cancel();
    subscription?.cancel();
    if (_android) channel.invokeMethod<void>('stop').catchError((Object _) {});
    super.dispose();
  }

  String age(RadioDevice d) =>
      '${DateTime.now().difference(d.latest.time).inSeconds.clamp(0, 99999)}s ago';

  @override
  Widget build(BuildContext context) {
    final list = devices.values.where((d) => d.history.isNotEmpty).toList()
      ..sort((a, b) => b.latest.rssi.compareTo(a.latest.rssi));
    final target = selected == null ? null : devices[selected];
    return Scaffold(
      appBar: AppBar(title: const Text('Bubble · Nearby'), actions: [
        IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Phone capabilities',
            onPressed: () async {
              if (_android) await refreshCapabilities();
              if (!context.mounted) return;
              showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                          title: const Text('Phone capabilities'),
                          content: SingleChildScrollView(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                const Text(
                                    'Hardware support does not guarantee access to compatible devices. RTT and UWB ranging are not active in this version.'),
                                const SizedBox(height: 12),
                                for (final entry in capabilities.entries)
                                  Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 10),
                                      child:
                                          Text('${entry.key}: ${entry.value}')),
                              ])),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'))
                          ]));
            }),
      ]),
      floatingActionButton: _android
          ? FloatingActionButton.extended(
              onPressed: starting
                  ? null
                  : scanning
                      ? stop
                      : start,
              icon: Icon(scanning ? Icons.stop : Icons.radar),
              label: Text(starting
                  ? 'Permissions…'
                  : scanning
                      ? 'Stop scan'
                      : 'Scan nearby'))
          : null,
      body: !_android
          ? const Center(
              child: Text(
                  'Wireless discovery currently requires Android.\nUse the Network screen for desktop LAN scanning.',
                  textAlign: TextAlign.center))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
              children: [
                  const Text(
                      'Scan nearby Wi-Fi access points and discoverable Bluetooth devices. Tap a result to follow its signal. Each scan lasts 30 seconds.'),
                  const SizedBox(height: 8),
                  const Text(
                      'Signal strength is not a distance or bearing. Walls, movement and transmit power affect it. Devices can rotate addresses; names do not prove identity.'),
                  if (scanning)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator()),
                  if (target != null && target.history.isNotEmpty)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Following ${target.label}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  Text(
                                      '${target.smoothed.toStringAsFixed(0)} dBm smoothed · last seen ${age(target)}'),
                                  Text(DateTime.now()
                                              .difference(target.latest.time)
                                              .inSeconds >
                                          15
                                      ? 'Signal is stale; scan again or wait for another advertisement.'
                                      : target.trend),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                      height: 90,
                                      width: double.infinity,
                                      child: CustomPaint(
                                          painter: _SignalPainter(
                                              target.history
                                                  .map((s) => s.rssi)
                                                  .toList(),
                                              Theme.of(context)
                                                  .colorScheme
                                                  .primary))),
                                  const Text(
                                      'Last 120 observations · signal strength, not metres'),
                                  TextButton(
                                      onPressed: () =>
                                          setState(() => selected = null),
                                      child: const Text('Stop following')),
                                ]))),
                  for (final message in messages)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(message)),
                  const SizedBox(height: 12),
                  Text('${list.length} wireless identities observed',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (list.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                            'Tap Scan nearby. Enable Bluetooth and Location services for the widest discovery.')),
                  for (final d in list)
                    Card(
                        child: ListTile(
                            leading:
                                Icon(d.isWifi ? Icons.wifi : Icons.bluetooth),
                            title: Text(d.label),
                            subtitle: Text(
                                '${d.methods.join(' + ')} · ${d.address}\n${d.latest.rssi} dBm · last seen ${age(d)}\n${d.detail}'),
                            isThreeLine: true,
                            trailing: Icon(selected == d.key
                                ? Icons.track_changes
                                : Icons.chevron_right),
                            onTap: () => setState(() => selected = d.key))),
                ]),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter(this.values, this.color);
  final List<int> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = color.withOpacity(0.2)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : size.width * i / (values.length - 1);
      final y = size.height * (1 - (values[i] + 110).clamp(0, 90) / 90);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      if (values.length == 1) {
        canvas.drawCircle(Offset(x, y), 3, Paint()..color = color);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _SignalPainter oldDelegate) => true;
}

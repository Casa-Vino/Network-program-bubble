import 'package:flutter/material.dart';
import '../models/radio_device.dart';
import '../models/room_map.dart';
import '../models/room_review.dart';

class RoomSignalPanel extends StatelessWidget {
  const RoomSignalPanel(
      {super.key,
      required this.sourceKey,
      required this.map,
      required this.devices,
      required this.ended});
  final String sourceKey;
  final RoomMap map;
  final List<RadioDevice> devices;
  final bool ended;
  @override
  Widget build(BuildContext context) {
    if (sourceKey == '*') return const SizedBox.shrink();
    final summary = RoomSignalSummary(map.readings, sourceKey);
    RadioDevice? live;
    for (final device in devices) {
      if (device.key == sourceKey) live = device;
    }
    final age = live == null || live.history.isEmpty
        ? null
        : DateTime.now().difference(live.latest.time).inSeconds;
    final feedback = ended
        ? 'Saved measurements'
        : age == null || age > 15
            ? 'Reading stale · scan for fresh signals'
            : '${live!.latest.rssi} dBm · ${live.trend}';
    final best = summary.best;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Text(
            '$feedback\n${best == null ? 'No mapped readings for this device yet' : 'Best mapped ${best.rssi} dBm · ${summary.count} readings · ring = phone position'}',
            key: const ValueKey('room-signal-feedback'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11)));
  }
}

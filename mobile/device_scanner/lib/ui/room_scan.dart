import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_identity.dart';
import '../models/radio_device.dart';
import '../models/room_map.dart';
import '../models/saved_room.dart';
import '../models/wall_fit.dart';
import '../services/room_store.dart';
import 'room_painter.dart';

class RoomScanPage extends StatefulWidget {
  const RoomScanPage(
      {super.key,
      this.source,
      this.sources,
      required this.refreshSignals,
      required this.signalsActive,
      required this.signalStatus,
      this.stopSignals,
      this.store});
  final RadioDevice? source;
  final Iterable<RadioDevice> Function()? sources;
  final Future<void> Function() refreshSignals;
  final Future<void> Function()? stopSignals;
  final bool Function() signalsActive;
  final String Function() signalStatus;
  final RoomStore? store;
  @override
  State<RoomScanPage> createState() => _RoomScanPageState();
}

class _RoomScanPageState extends State<RoomScanPage>
    with WidgetsBindingObserver {
  RoomMap map = RoomMap();
  late final RoomStore store = widget.store ?? RoomStore();
  SavedRoom? capture;
  List<WallPolygon> walls = [];
  StreamSubscription<dynamic>? events;
  bool camera = false, requesting = false, refreshing = false;
  bool ended = false, busy = false, saved = false;
  bool processingFailed = false;
  bool torch = false,
      torchAvailable = false,
      cameraActive = false,
      torchPending = false;
  bool showPoints = true, showWalls = true, showSignals = true;
  double opacity = .22, pointSize = 1.2, yaw = .3, tilt = .45, zoom = 35;
  String status =
      'Start the camera, then move slowly across textured surfaces in good light.';
  RoomPoint? center;
  final viewport = GlobalKey();
  late String sourceFilter;
  List<RadioDevice> get availableSources => (widget.sources?.call() ??
          (widget.source == null ? <RadioDevice>[] : [widget.source!]))
      .where((d) => d.history.isNotEmpty)
      .toList();
  Map<String, String> get labels => {
        for (final r in map.readings)
          r.sourceKey:
              '${r.sourceName} · ${r.sourceKey.length > 8 ? r.sourceKey.substring(r.sourceKey.length - 8) : r.sourceKey}',
        for (final d in availableSources) d.key: d.displayLabel,
      };
  @override
  void initState() {
    super.initState();
    sourceFilter = widget.source?.key ?? '*';
    WidgetsBinding.instance.addObserver(this);
    events = const EventChannel('bubble/room/events')
        .receiveBroadcastStream()
        .listen((dynamic value) {
      if (!mounted || value is! Map || ended) return;
      setState(() {
        status = value['state'] as String? ?? status;
        if (value.containsKey('tracking')) {
          map.frame(value, widget.source, sources: availableSources);
        }
        if (value['torch'] is bool) torch = value['torch'] as bool;
        if (value['torchAvailable'] is bool) {
          torchAvailable = value['torchAvailable'] as bool;
        }
        if (value['cameraActive'] is bool) {
          cameraActive = value['cameraActive'] as bool;
        }
      });
    }, onError: (Object e) {
      if (mounted && !ended) {
        setState(() {
          status = 'Room scan error: $e';
          map.tracking = false;
        });
      }
    });
  }

  Future<void> startCamera() async {
    if (requesting || ended) return;
    setState(() => requesting = true);
    final result = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      requesting = false;
      camera = result.isGranted;
      if (!camera) {
        status =
            'Camera permission is needed for room scanning. Nearby still works without it.';
      }
    });
  }

  Future<void> toggleTorch() async {
    if (torchPending || ended) return;
    setState(() => torchPending = true);
    try {
      final enabled = await const MethodChannel('bubble/room')
          .invokeMethod<bool>('setTorch', {'enabled': !torch});
      if (mounted && cameraActive && !ended) {
        setState(() => torch = enabled ?? false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not change flashlight: $e')));
      }
    } finally {
      if (mounted) setState(() => torchPending = false);
    }
  }

  Future<void> refresh() async {
    if (refreshing || ended) return;
    setState(() => refreshing = true);
    try {
      await widget.refreshSignals();
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> finishScan() async {
    if (busy || ended) return;
    // Freeze first: queued native frames must not change the snapshot during IO.
    setState(() {
      ended = true;
      busy = true;
      camera = false;
      cameraActive = false;
      torch = false;
      map.tracking = false;
      status = 'Scan ended · saving captured points…';
    });
    capture = SavedRoom(DateTime.now(), map.surfaces.values.toList(),
        List.of(map.readings), map.phone);
    try {
      await const MethodChannel('bubble/room').invokeMethod<void>('endScan');
    } catch (_) {/* Removing AndroidView also disposes the camera session. */}
    try {
      await widget.stopSignals?.call();
    } catch (_) {/* Snapshot stays frozen. */}
    await processCapture();
  }

  Future<void> processCapture() async {
    processingFailed = false;
    final original = capture;
    if (original == null) return;
    try {
      await store.save(original);
      saved = true;
      if (mounted) {
        setState(() => status = 'Scan saved · interpreting candidate walls…');
      }
      final fitted = await compute(fitWalls, original.points);
      capture = original.withWalls(fitted);
      await store.save(capture!);
      if (!mounted) return;
      setState(() {
        walls = fitted;
        status = fitted.isEmpty
            ? 'Scan saved · no sufficiently large vertical patches found. Captured points remain available.'
            : 'Scan saved · ${walls.length} candidate wall polygons. These may include furniture or span openings.';
      });
      fitView();
    } catch (e) {
      processingFailed = true;
      if (mounted) {
        setState(() => status = saved
            ? 'Raw scan saved; wall processing or its save failed: $e. Retry is available.'
            : 'Scan ended but NOT saved: $e. Retry before leaving this screen.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> retry() async {
    setState(() => busy = true);
    await processCapture();
  }

  Future<void> openSaved() async {
    try {
      final files = await store.list();
      if (!mounted) return;
      final file = await showDialog<dynamic>(
          context: context,
          builder: (context) => SimpleDialog(
              title: const Text('Saved room scans'),
              children: files.isEmpty
                  ? [
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                              'No saved scans yet. Use End scan to save a capture.'))
                    ]
                  : [
                      for (final f in files)
                        SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, f),
                            child: Text(DateTime.fromMicrosecondsSinceEpoch(
                                    int.parse(f.uri.pathSegments.last
                                        .split('.')
                                        .first))
                                .toLocal()
                                .toString()
                                .split('.')
                                .first))
                    ]));
      if (file == null || !mounted) return;
      setState(() {
        busy = true;
        status = 'Opening saved scan…';
      });
      final room = await store.load(file);
      if (!mounted) return;
      setState(() {
        capture = room;
        map = room.toMap();
        walls = room.walls;
        ended = true;
        saved = true;
        sourceFilter = '*';
        status = 'Saved scan · ${walls.length} candidate walls · camera off';
      });
      fitView();
    } catch (e) {
      if (mounted) setState(() => status = 'Could not open scan: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void newScan() => setState(() {
        map = RoomMap();
        capture = null;
        walls = [];
        center = null;
        ended = false;
        saved = false;
        sourceFilter = '*';
        status =
            'Ready for a new scan. Saved captures are available in the folder.';
      });
  void fitView() {
    if (map.surfaces.isEmpty) return;
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (final p in map.surfaces.values) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
      minZ = math.min(minZ, p.z);
      maxZ = math.max(maxZ, p.z);
    }
    final size = viewport.currentContext?.size ?? const Size(300, 300);
    final radius = math.sqrt(math.pow(maxX - minX, 2) +
            math.pow(maxY - minY, 2) +
            math.pow(maxZ - minZ, 2)) /
        2;
    setState(() {
      center =
          RoomPoint((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
      zoom = (math.min(size.width, size.height) * .42 / math.max(radius, .1))
          .clamp(3, 100);
    });
  }

  void settings() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, updateSheet) {
            void update(VoidCallback f) {
              setState(f);
              updateSheet(() {});
            }

            return SafeArea(
                child: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('Room display and capture'),
                          SwitchListTile(
                              title: const Text('Captured surface points'),
                              value: showPoints,
                              onChanged: (v) => update(() => showPoints = v)),
                          SwitchListTile(
                              title: const Text('Candidate wall polygons'),
                              value: showWalls,
                              onChanged: (v) => update(() => showWalls = v)),
                          SwitchListTile(
                              title: const Text('Device signal markers'),
                              value: showSignals,
                              onChanged: (v) => update(() => showSignals = v)),
                          Text('Surface opacity ${(opacity * 100).round()}%'),
                          Slider(
                              value: opacity,
                              min: .03,
                              max: .8,
                              onChanged: (v) => update(() => opacity = v)),
                          Text('Point size ${pointSize.toStringAsFixed(1)}'),
                          Slider(
                              value: pointSize,
                              min: .5,
                              max: 3,
                              onChanged: (v) => update(() => pointSize = v)),
                          Text('Zoom ${zoom.round()}'),
                          Slider(
                              value: zoom,
                              min: 3,
                              max: 100,
                              onChanged: (v) => update(() => zoom = v)),
                          DropdownButton<int>(
                              value: map.maxSurfacePoints,
                              items: [
                                for (final n in [60000, 150000, 300000])
                                  DropdownMenuItem(
                                      value: n,
                                      child:
                                          Text('${n ~/ 1000},000 point limit'))
                              ],
                              onChanged: ended
                                  ? null
                                  : (n) {
                                      if (n != null) {
                                        update(() => map.setSurfaceLimit(n));
                                      }
                                    }),
                          const Text(
                              'Walls are fitted vertical patches, not surveyed boundaries. Openings and wall identity are not inferred.'),
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Done')),
                        ]))));
          }));
  @override
  void didChangeMetrics() {
    if (ended && center != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fitView();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() {
        map.tracking = false;
        torch = false;
        cameraActive = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = labels;
    if (sourceFilter != '*' && !sources.containsKey(sourceFilter)) {
      sourceFilter = '*';
    }
    return PopScope(
        canPop: !busy,
        child: Scaffold(
          backgroundColor: const Color(0xFF050B0C),
          appBar: AppBar(
              title: const Text('$appName · Room',
                  overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                    tooltip: 'Saved scans',
                    onPressed: busy || camera ? null : openSaved,
                    icon: const Icon(Icons.folder_open)),
                IconButton(
                    tooltip: 'Room display settings',
                    onPressed: settings,
                    icon: const Icon(Icons.tune)),
                IconButton(
                    tooltip:
                        torch ? 'Turn flashlight off' : 'Turn flashlight on',
                    onPressed: !ended &&
                            cameraActive &&
                            torchAvailable &&
                            !torchPending
                        ? toggleTorch
                        : null,
                    color: torch ? Colors.amber : null,
                    icon: Icon(
                        torch ? Icons.flashlight_on : Icons.flashlight_off)),
                IconButton(
                    tooltip: 'Fit room in view',
                    onPressed: fitView,
                    icon: const Icon(Icons.center_focus_strong)),
              ]),
          body: SafeArea(
              top: false,
              child: Column(children: [
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DropdownButton<String>(
                        key: const ValueKey('room-source-filter'),
                        isExpanded: true,
                        value: sourceFilter,
                        dropdownColor: const Color(0xFF102020),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'Roboto'),
                        items: [
                          const DropdownMenuItem(
                              value: '*',
                              child: Text('All device signal layers')),
                          for (final entry in sources.entries)
                            DropdownMenuItem(
                                value: entry.key,
                                child: Row(children: [
                                  Icon(Icons.circle,
                                      color: roomSourceColor(entry.key),
                                      size: 9),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(
                                          '${entry.value} · ${map.readingCounts[entry.key] ?? 0} mapped',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis))
                                ]))
                        ],
                        onChanged: (key) {
                          if (key != null) setState(() => sourceFilter = key);
                        })),
                Text(
                    '${ended ? 'ENDED' : map.tracking ? 'TRACKING' : 'NO POSITION FIX'} · ${map.surfaces.length} points · ${map.readings.length} signals · ${walls.length} walls',
                    style: const TextStyle(
                        color: Color(0xFF9AF8BE), fontSize: 11)),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                        sourceFilter == '*'
                            ? 'Signals: colour identifies device · markers are phone reading positions'
                            : 'Selected device: cyan = weaker, orange = stronger',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 10))),
                Expanded(
                    child: ClipRect(
                        key: viewport,
                        child: Stack(fit: StackFit.expand, children: [
                          if (camera && !ended)
                            const AndroidView(viewType: 'bubble/room'),
                          GestureDetector(
                              key: const ValueKey('room-viewport'),
                              onPanUpdate: (d) => setState(() {
                                    yaw += d.delta.dx * .008;
                                    tilt = (tilt + d.delta.dy * .006)
                                        .clamp(-1.2, 1.2);
                                  }),
                              child: ColoredBox(
                                  color: const Color(0xFF050B0C),
                                  child: CustomPaint(
                                      painter: RoomPainter(
                                          map,
                                          walls,
                                          center,
                                          yaw,
                                          tilt,
                                          zoom,
                                          sourceFilter,
                                          showPoints,
                                          showWalls,
                                          showSignals,
                                          opacity,
                                          pointSize)))),
                          if (!camera && !ended)
                            Center(
                                child: SingleChildScrollView(
                                    child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Text(
                                                  'This application runs on Google Play Services for AR (ARCore), provided by Google and governed by the Google Privacy Policy.',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 11)),
                                              TextButton(
                                                  onPressed: () => launchUrl(
                                                      Uri.parse(
                                                          'https://policies.google.com/privacy')),
                                                  child: const Text(
                                                      'Google Privacy Policy')),
                                              FilledButton(
                                                  onPressed: requesting
                                                      ? null
                                                      : startCamera,
                                                  child: Text(requesting
                                                      ? 'Requesting camera…'
                                                      : 'Start room camera')),
                                            ])))),
                          if (busy)
                            const Center(child: CircularProgressIndicator()),
                        ]))),
                const Text(
                    'Drag to orbit · 1 m reference grid · not a detected floor',
                    style: TextStyle(color: Colors.white54, fontSize: 10)),
                Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Text(status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11))),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      if (!ended)
                        Expanded(
                            child: FilledButton.icon(
                                key: const ValueKey('end-room-scan'),
                                onPressed: camera ||
                                        cameraActive ||
                                        map.surfaces.isNotEmpty
                                    ? finishScan
                                    : null,
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text('End scan')))
                      else
                        Expanded(
                            child: FilledButton(
                                onPressed: busy || !saved ? null : newScan,
                                child: const Text('New scan'))),
                      const SizedBox(width: 8),
                      if (ended)
                        TextButton(
                            onPressed: busy ? null : retry,
                            child: Text(processingFailed
                                ? 'Retry wall fit / save'
                                : 'Refit walls'))
                      else
                        TextButton(
                            onPressed: availableSources.isEmpty ||
                                    refreshing ||
                                    widget.signalsActive()
                                ? null
                                : refresh,
                            child: Text(widget.signalsActive()
                                ? 'Signals scanning…'
                                : 'Scan signals')),
                    ])),
              ])),
        ));
  }
}

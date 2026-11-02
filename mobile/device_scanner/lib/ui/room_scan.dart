import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_identity.dart';
import '../models/radio_device.dart';
import '../models/room_map.dart';
import '../models/room_review.dart';
import '../models/room_export.dart';
import '../models/saved_room.dart';
import '../models/wall_fit.dart';
import '../services/room_store.dart';
import 'room_painter.dart';
import 'room_signal_panel.dart';

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
  bool smoothDisplay = true,
      interacting = false,
      cleanReview = false,
      autoSignals = false;
  Timer? repeatSignals;
  List<RoomPoint>? reviewPoints;
  List<RoomPoint> _displayPoints = [];
  RoomMap? _displayMap;
  List<RoomPoint>? _displayReview;
  int _displayRevision = -1, _displayBudget = -1;
  Offset pan = Offset.zero;
  double gestureZoom = 35;
  List<RoomPoint> get displayPoints {
    final budget = smoothDisplay ? (interacting ? 30000 : 60000) : 300000;
    final filtered = cleanReview ? reviewPoints : null;
    if (_displayMap != map ||
        _displayRevision != map.surfaceRevision ||
        _displayReview != filtered ||
        _displayBudget != budget) {
      final source = filtered ?? map.surfaces.values;
      _displayPoints = sampleForDisplay(
          source, filtered?.length ?? map.surfaces.length, budget);
      _displayMap = map;
      _displayRevision = map.surfaceRevision;
      _displayReview = filtered;
      _displayBudget = budget;
    }
    return _displayPoints;
  }

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
        for (final d in availableSources)
          if (!ended || map.readingCounts.containsKey(d.key))
            d.key: d.displayLabel,
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
      if (ended) {
        try {
          await widget.stopSignals?.call();
        } catch (_) {}
      }
    }
  }

  Future<void> toggleAutoSignals(bool enabled) async {
    repeatSignals?.cancel();
    setState(() => autoSignals = enabled);
    if (!enabled) return;
    Future<void> tick() async {
      if (!mounted ||
          !autoSignals ||
          ended ||
          !cameraActive ||
          refreshing ||
          widget.signalsActive()) return;
      try {
        await refresh();
        if (!mounted || !autoSignals || ended) return;
        if (!widget.signalsActive()) {
          repeatSignals?.cancel();
          setState(() => autoSignals = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Repeat scanning stopped: a signal scan could not start. Check radio permissions and settings.')));
        }
      } catch (e) {
        if (mounted) {
          repeatSignals?.cancel();
          setState(() {
            autoSignals = false;
            status = 'Signal scan failed: $e';
          });
        }
      }
    }

    await tick();
    if (mounted && autoSignals && !ended) {
      repeatSignals =
          Timer.periodic(const Duration(seconds: 32), (_) => tick());
    }
  }

  Future<void> filterReview(bool enabled) async {
    if (!ended || capture == null || busy) return;
    if (!enabled) {
      setState(() => cleanReview = false);
      return;
    }
    setState(() {
      busy = true;
      status = 'Filtering isolated clusters for review…';
    });
    try {
      final List<RoomPoint> filtered = reviewPoints ??
          await compute<List<RoomPoint>, List<RoomPoint>>(
              supportedReviewPoints, capture!.points);
      if (mounted) {
        setState(() {
          reviewPoints = filtered;
          cleanReview = true;
          status =
              'Review filter: ${filtered.length} supported points; ${capture!.points.length} captured points retained for saving and export.';
        });
      }
      if (mounted) fitView();
    } catch (e) {
      if (mounted) setState(() => status = 'Review filter failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> exportScan(RoomExport format) async {
    final room = capture;
    if (!ended || room == null || busy) return;
    setState(() {
      busy = true;
      status = 'Preparing ${format.label}…';
    });
    try {
      final bytes = await compute(exportRoom, RoomExportRequest(room, format));
      final path = await FilePicker.platform.saveFile(
          dialogTitle: format.label,
          fileName:
              'bubble-${room.created.microsecondsSinceEpoch}.${format.extension}',
          type: FileType.custom,
          allowedExtensions: [format.extension],
          bytes: bytes);
      if (path != null && !Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (mounted) {
        setState(() => status = path == null
            ? 'Export cancelled.'
            : '${format.label} exported. Coordinates are metres in this scan frame.');
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finishScan() async {
    if (busy || ended) return;
    repeatSignals?.cancel();
    // Freeze first: queued native frames must not change the snapshot during IO.
    setState(() {
      ended = true;
      autoSignals = false;
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
        cleanReview = false;
        reviewPoints = null;
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
        cleanReview = false;
        reviewPoints = null;
        pan = Offset.zero;
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
    final points = cleanReview && reviewPoints != null
        ? reviewPoints!
        : map.surfaces.values;
    if (points.isEmpty) return;
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (final p in points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
      minZ = math.min(minZ, p.z);
      maxZ = math.max(maxZ, p.z);
    }
    final size = viewport.currentContext?.size ?? const Size(300, 300);
    final origin =
        RoomPoint((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
    var halfX = .01, halfY = .01;
    final cy = math.cos(yaw),
        sy = math.sin(yaw),
        ct = math.cos(tilt),
        st = math.sin(tilt);
    for (final p in points) {
      final x = p.x - origin.x, y = p.y - origin.y, z = p.z - origin.z;
      halfX = math.max(halfX, (x * cy - z * sy).abs());
      halfY = math.max(halfY, (y * ct - (x * sy + z * cy) * st).abs());
    }
    setState(() {
      pan = Offset.zero;
      center = origin;
      zoom = (math.min((size.width - 24) / (2 * halfX),
                  (size.height - 24) / (2 * halfY)) *
              .9)
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
                          Wrap(spacing: 12, children: [
                            TextButton(
                                onPressed: () {
                                  update(() {
                                    yaw = 0;
                                    tilt = math.pi / 2;
                                  });
                                  fitView();
                                },
                                child: const Text('Top-down view')),
                            TextButton(
                                onPressed: () {
                                  update(() {
                                    yaw = .3;
                                    tilt = .45;
                                  });
                                  fitView();
                                },
                                child: const Text('Perspective view')),
                          ]),
                          SwitchListTile(
                              title: const Text('Smoother point display'),
                              subtitle: const Text(
                                  'Draw fewer points while keeping the full capture'),
                              value: smoothDisplay,
                              onChanged: (v) =>
                                  update(() => smoothDisplay = v)),
                          SwitchListTile(
                              title: const Text(
                                  'Hide isolated clusters (review only)'),
                              value: cleanReview,
                              onChanged: !ended || busy
                                  ? null
                                  : (v) async {
                                      await filterReview(v);
                                      if (context.mounted) updateSheet(() {});
                                    }),
                          SwitchListTile(
                              title: const Text('Repeat signal scans'),
                              subtitle: const Text(
                                  'While the room camera is active; stops on pause or End scan'),
                              value: autoSignals,
                              onChanged: !cameraActive || ended || busy
                                  ? null
                                  : (v) async {
                                      await toggleAutoSignals(v);
                                      if (context.mounted) updateSheet(() {});
                                    }),
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
      repeatSignals?.cancel();
      setState(() {
        autoSignals = false;
        map.tracking = false;
        torch = false;
        cameraActive = false;
      });
    }
  }

  @override
  void dispose() {
    repeatSignals?.cancel();
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
                PopupMenuButton<String>(
                    tooltip: 'Room tools',
                    onSelected: (value) {
                      if (value == 'fit') {
                        fitView();
                      } else if (value == 'top' || value == 'orbit') {
                        setState(() {
                          yaw = value == 'top' ? 0 : .3;
                          tilt = value == 'top' ? math.pi / 2 : .45;
                        });
                        fitView();
                      } else if (value.startsWith('export:')) {
                        exportScan(RoomExport
                            .values[int.parse(value.split(':').last)]);
                      }
                    },
                    itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'fit', child: Text('Fit room in view')),
                          const PopupMenuItem(
                              value: 'top', child: Text('Top-down view')),
                          const PopupMenuItem(
                              value: 'orbit', child: Text('Perspective view')),
                          const PopupMenuDivider(),
                          for (final format in RoomExport.values)
                            PopupMenuItem(
                                value: 'export:${format.index}',
                                enabled: ended && capture != null && !busy,
                                child: Text('Export ${format.label}')),
                        ]),
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
                RoomSignalPanel(
                    sourceKey: sourceFilter,
                    map: map,
                    devices: availableSources,
                    ended: ended),
                Expanded(
                    child: ClipRect(
                        key: viewport,
                        child: Stack(fit: StackFit.expand, children: [
                          if (camera && !ended)
                            const AndroidView(viewType: 'bubble/room'),
                          GestureDetector(
                              key: const ValueKey('room-viewport'),
                              onDoubleTap: fitView,
                              onTapUp: (d) {
                                final size = viewport.currentContext?.size;
                                if (size == null || !showSignals) return;
                                final origin = center ??
                                    map.phone ??
                                    const RoomPoint(0, 0, 0);
                                var distance = 24.0;
                                String? key;
                                for (final r in map.readings.reversed) {
                                  if (sourceFilter != '*' &&
                                      r.sourceKey != sourceFilter) continue;
                                  final delta = (projectRoomPoint(r, origin,
                                              size, yaw, tilt, zoom, pan) -
                                          d.localPosition)
                                      .distance;
                                  if (delta < distance) {
                                    distance = delta;
                                    key = r.sourceKey;
                                  }
                                }
                                if (key != null) {
                                  setState(() => sourceFilter = key!);
                                }
                              },
                              onScaleStart: (_) => setState(() {
                                    gestureZoom = zoom;
                                    interacting = true;
                                  }),
                              onScaleUpdate: (d) => setState(() {
                                    if (d.pointerCount >= 2) {
                                      zoom =
                                          (gestureZoom * d.scale).clamp(3, 100);
                                      pan += d.focalPointDelta;
                                    } else {
                                      yaw += d.focalPointDelta.dx * .008;
                                      tilt =
                                          (tilt + d.focalPointDelta.dy * .006)
                                              .clamp(-1.45, math.pi / 2);
                                    }
                                  }),
                              onScaleEnd: (_) =>
                                  setState(() => interacting = false),
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
                                          pointSize,
                                          pan: pan,
                                          displayPoints: displayPoints)))),
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
                Text(
                    'Drag: orbit · 2 fingers: zoom/pan · tap a signal to follow\n1 m reference grid (not a floor) · ${showPoints ? displayPoints.length : 0} points drawn',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 10)),
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
                            onPressed: refreshing || widget.signalsActive()
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

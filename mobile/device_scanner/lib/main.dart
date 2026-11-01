import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'fingerprint/default_logins.dart';
import 'models/device.dart';
import 'services/admin_audit.dart';
import 'services/discovery.dart';
import 'services/updater.dart';
import 'ui/receive_files.dart';
import 'ui/nearby.dart';
import 'ui/send_files.dart';
import 'ui/smb_browser.dart';

void main() => runApp(const DeviceScannerApp());

class DeviceScannerApp extends StatelessWidget {
  const DeviceScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF0E8388);
    return MaterialApp(
      title: 'Bubble',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(
          colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.dark),
      home: const ScanPage(),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _scanning = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  List<Device> _devices = [];

  Future<void> _scan() async {
    // Wi-Fi details (and mDNS) need location/nearby-devices permission on
    // modern Android. Desktop has no such runtime permission.
    if (Platform.isAndroid) {
      await [Permission.locationWhenInUse, Permission.nearbyWifiDevices]
          .request();
    }

    setState(() {
      _scanning = true;
      _error = null;
      _devices = [];
      _progress = 0;
      _status = 'Starting…';
    });

    try {
      final scanner = NetworkScanner();
      final result = await scanner.scan(onProgress: (s, p) {
        if (mounted) setState(() {
          _status = s;
          _progress = p;
        });
      });
      if (mounted) setState(() => _devices = result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _checkUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!Platform.isAndroid) {
      messenger.showSnackBar(const SnackBar(
          content: Text('On desktop, download updates from the Releases page.')));
      return;
    }
    messenger.showSnackBar(
        const SnackBar(content: Text('Checking for updates…')));
    final info = await Updater.check();
    if (!mounted) return;
    if (info == null) {
      final build = await Updater.currentBuild();
      if (mounted) {
        messenger.showSnackBar(SnackBar(
            content: Text('You are on the latest version (build $build).')));
      }
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Text('Version ${info.versionName} is available. '
            'Download and install it now?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Downloading update'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v == 0 ? null : v),
              const SizedBox(height: 8),
              Text('${(v * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );
    try {
      await Updater.downloadAndInstall(info, onProgress: (v) {
        progress.value = v;
      });
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        messenger.showSnackBar(SnackBar(content: Text('Update failed: $e')));
      }
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bubble · Network'),
        actions: [
          IconButton(icon: const Icon(Icons.radar), tooltip: 'Nearby wireless devices',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NearbyPage()))),
          IconButton(
            icon: const Icon(Icons.download_for_offline),
            tooltip: 'Receive from a nearby device',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReceiveFilesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.drive_folder_upload),
            tooltip: 'Send files',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SendFilesScreen()),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'update') _checkUpdate();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'update', child: Text('Check for updates')),
            ],
          ),
        ],
        bottom: _scanning
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _scan,
        icon: Icon(_scanning ? Icons.hourglass_top : Icons.wifi_find),
        label: Text(_scanning ? 'Scanning…' : 'Scan'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return _Centered(
          icon: Icons.error_outline,
          title: 'Scan failed',
          subtitle: _error!);
    }
    if (_scanning && _devices.isEmpty) {
      return _Centered(
          icon: Icons.radar, title: _status, subtitle: 'Probing the local subnet…');
    }
    if (_devices.isEmpty) {
      return const _Centered(
        icon: Icons.wifi_tethering,
        title: 'Tap Scan to discover devices',
        subtitle: 'Scans only the Wi-Fi you are connected to. '
            'Use on networks you own or are authorized to manage.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: _devices.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('${_devices.length} device(s) found',
                style: Theme.of(context).textTheme.labelLarge),
          );
        }
        return _DeviceTile(device: _devices[i - 1]);
      },
    );
  }
}

class _DeviceTile extends StatefulWidget {
  const _DeviceTile({required this.device});
  final Device device;

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> {
  bool _auditing = false;
  AuditResult? _audit;

  Device get device => widget.device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ports = (device.openPorts.toList()..sort()).join(', ');
    final confidencePct = (device.confidence * 100).round();
    final login = lookupDefaultLogin(device);

    return ExpansionTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(_iconFor(device.category),
            color: theme.colorScheme.onSecondaryContainer),
      ),
      title: Row(
        children: [
          Expanded(
              child: Text(device.role,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis)),
          if (device.confidence > 0)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Chip(
                label: Text('$confidencePct%'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
      subtitle: Text(
        [device.ip, if (device.hostname != null) device.hostname!].join('  •  '),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(72, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ports.isNotEmpty) _kv('Open ports', ports),
        if (device.services.isNotEmpty)
          _kv('mDNS services', device.services.join(', ')),
        if (device.reasons.isNotEmpty)
          _kv('Why', device.reasons.join(', ')),
        if (device.notes != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(device.notes!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic)),
          ),
        if (login != null) _loginHint(theme, login),
        if (device.openPorts.contains(445) || device.openPorts.contains(139))
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.folder_shared, size: 18),
                label: const Text('Browse shared folders'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SmbBrowserScreen(
                        host: device.ip,
                        label: device.hostname ?? device.ip),
                  ),
                ),
              ),
            ),
          ),
        if (device.webUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: Text('Open ${device.webUrl}'),
                  onPressed: () => _openUrl(context, device.webUrl!),
                ),
                OutlinedButton.icon(
                  icon: _auditing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.vpn_key, size: 18),
                  label: Text(_auditing ? 'Checking…' : 'Check default login'),
                  onPressed: _auditing ? null : _confirmAndAudit,
                ),
              ],
            ),
          ),
        if (_audit != null) _auditCard(theme, _audit!),
      ],
    );
  }

  Widget _loginHint(ThemeData theme, DefaultLogin login) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Likely default login (${login.vendor})', login.credLabel),
              const SizedBox(height: 4),
              Text(login.note,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontStyle: FontStyle.italic)),
            ],
          ),
        ),
      );

  Widget _auditCard(ThemeData theme, AuditResult r) {
    final color = r.alert
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final onColor = r.alert
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(8)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(r.alert ? Icons.warning_amber : Icons.info_outline,
                size: 18, color: onColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(r.message,
                  style: theme.textTheme.bodySmall?.copyWith(color: onColor)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndAudit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Authorized check'),
        content: Text(
          'Only do this on devices you own or are authorized to manage.\n\n'
          'This reads ${device.webUrl} and, if it uses HTTP Basic auth, tries '
          'a short list of well-known default logins. It is read-only — nothing '
          'is changed, and login forms are not submitted.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("I'm authorized")),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _auditing = true;
      _audit = null;
    });
    final result = await AdminAudit.run(device);
    if (mounted) {
      setState(() {
        _auditing = false;
        _audit = result;
      });
    }
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 13, height: 1.3),
            children: [
              TextSpan(
                  text: '$k: ',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: v),
            ],
          ),
        ),
      );

  IconData _iconFor(String? category) {
    switch (category) {
      case 'gateway / router':
        return Icons.router;
      case 'printer':
        return Icons.print;
      case 'file server / nas':
        return Icons.storage;
      case 'media / airplay':
      case 'media renderer':
        return Icons.cast;
      case 'speaker':
        return Icons.speaker;
      case 'homekit accessory':
      case 'iot hub':
      case 'unidentified device':
        return Icons.sensors;
      case 'camera':
        return Icons.videocam;
      case 'host':
      case 'host (windows)':
        return Icons.computer;
      case 'mobile (apple)':
        return Icons.smartphone;
      case 'web device':
        return Icons.language;
      default:
        return Icons.devices_other;
    }
  }
}

class _Centered extends StatelessWidget {
  const _Centered(
      {required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

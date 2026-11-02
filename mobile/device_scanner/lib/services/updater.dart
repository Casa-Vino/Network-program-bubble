import 'dart:convert';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../app_identity.dart';

/// In-app updater for the sideloaded APK.
///
/// A sideloaded app can't update itself silently (that needs system
/// privileges), but it can download the new APK and hand it to Android's
/// package installer, which — because every build is signed with the same
/// committed debug keystore — updates in place with one tap.
///
/// CI publishes `version.json` next to the APK on the rolling release. We
/// compare its versionCode to this build's and offer the update when newer.
class UpdateInfo {
  UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.sha,
    required this.apkUrl,
  });
  final int versionCode;
  final String versionName;
  final String sha;
  final String apkUrl;
}

class Updater {
  static const String versionUrl = appVersionUrl;

  static Future<int> currentBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  /// Returns update info when a newer build is available, else null.
  static Future<UpdateInfo?> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(versionUrl));
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final info = UpdateInfo(
        versionCode: (j['versionCode'] as num).toInt(),
        versionName: j['versionName']?.toString() ?? '',
        sha: j['sha']?.toString() ?? '',
        apkUrl: j['apk'].toString(),
      );
      final current = await currentBuild();
      return info.versionCode > current ? info : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Download the APK (reporting 0..1 progress) and launch the installer.
  static Future<void> downloadAndInstall(UpdateInfo info,
      {void Function(double)? onProgress}) async {
    final client = HttpClient();
    try {
      final dir = await getExternalStorageDirectory() ??
          await getTemporaryDirectory();
      final path = '${dir.path}/update.apk';

      final req = await client.getUrl(Uri.parse(info.apkUrl));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'Download failed (HTTP ${resp.statusCode}).';
      }
      final total = resp.contentLength;
      final out = File(path).openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          out.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
        await out.flush();
      } finally {
        await out.close();
      }

      final result = await OpenFilex.open(path,
          type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done) {
        throw 'Could not open the installer: ${result.message}';
      }
    } finally {
      client.close(force: true);
    }
  }
}

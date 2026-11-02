import 'package:flutter_test/flutter_test.dart';
import 'package:device_scanner/app_identity.dart';
import 'package:device_scanner/services/updater.dart';

void main() {
  test('the app label and updater use the same build channel', () {
    const development = bool.fromEnvironment('BUBBLE_DEV');
    expect(appName, development ? 'Bubble Dev' : 'Bubble');
    expect(Uri.parse(Updater.versionUrl).pathSegments,
        contains(development ? 'bubble-dev-latest' : 'mobile-latest'));
  });
}

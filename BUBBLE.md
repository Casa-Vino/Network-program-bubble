# Bubble

Bubble is an independent continuation of Device Scanner, targeting Android first.
The original MIT licence is retained. The Android package is `com.casavino.bubble`,
so it installs alongside `com.casavino.device_scanner`. Updates come from
`Casa-Vino/Network-program-bubble`, not the original repository.

## First version

The Network screen retains the existing TCP/mDNS scanner and file-transfer tools.
Tap the radar icon to open Nearby. Grant Nearby devices and precise Location
permissions, enable Bluetooth and Location services, then tap Scan nearby.

Each foreground session lasts 30 seconds: Wi-Fi refresh and Classic Bluetooth
inquiry, followed after 13 seconds by Bluetooth LE scanning. Scans stop when the
app leaves the foreground or the screen closes. Every method reports failures
independently, so a denied Bluetooth permission does not discard Wi-Fi results.

Tap an observation to follow its signal history. Scan again to gather more
samples. History is kept in memory for this screen only, bounded to 120 samples
per identity. The graph plots observations, not elapsed time. Stale readings are
labelled, and cached Wi-Fi timestamps do not create fresh history entries.
Android limits Wi-Fi scan frequency, so rapid repeated scans may return old data.

BLE and Classic observations merge only for an identical Bluetooth address.
Wi-Fi access points are separate identities, even if their names match Bluetooth
devices. Random/private addresses may change. An observed name is not verified
ownership or identity. Wi-Fi scans list access points, not every Wi-Fi client.

Capabilities reports actual platform feature flags, radio state and permissions.
Wi-Fi RTT, Wi-Fi Aware and UWB are capability checks only; this version does not
range with them. No radar bearings, metre estimates, room geometry or universal
ring commands are invented. Signal trends can suggest warmer/colder but walls,
body shielding and transmitter power can change readings without any movement.

## Signal Cloud view

On Nearby, tap the cloud icon to switch between the device list and a dark,
LiDAR-inspired point-cloud display. Every dot represents an observed RSSI sample.
Radius encodes received signal strength, height encodes sample age, and each
identity gets a stable angular lane for readability. These coordinates are
abstract: they do not locate the transmitter or map a room. The animated sweep
is a visual effect, not a directional radio measurement. No camera is used.

Drag to orbit. Tap a point or source button to select a source; isolate it with
the filter button. Freeze holds the displayed cloud while discovery continues;
resume returns to current observations. Trails expire after 120 seconds, with
up to 60 displayed samples per identity and 6,000 points overall. Wi-Fi is mint,
BLE cyan and Classic Bluetooth amber. Switching views keeps the active scan and
selected source. Existing 30-second foreground scan limits still apply.

## Experimental Room scan

Room scan has a flashlight toggle in the top bar. After starting the camera,
tap the flashlight icon to keep the active camera's LED on while mapping.
It uses ARCore's torch configuration, checks that camera's flash capability,
and turns off on pause/exit. Returning to the app starts with the light off;
tap it again when needed. Unsupported cameras leave the toggle disabled.

Nearby > select a device > Room scan (cube icon). Review the Google ARCore notice,
start the camera and grant permission. If prompted, install/update Google Play
Services for AR and reopen Room scan. Move slowly around textured, well-lit
surfaces. Green points are camera-derived depth estimates, blue is the phone,
and coloured signal dots mark where the phone took fresh readings. Use Scan
signals to run another bounded discovery session. Rotate the map by dragging;
adjust zoom with the slider. The reference grid is not a detected floor.

This is an AR Optional feature. Unsupported devices retain normal discovery.
Depth is explicitly checked at runtime; no synthetic room is substituted.
There are no Cloud Anchors or geospatial features. The map stays in memory for
this screen and is discarded on exit. Backgrounding pauses camera capture.
Radio samples must be within 500 ms of a tracked pose and are recorded only
once; cached Wi-Fi observations will normally be rejected. Geometry uses 5 cm
voxel deduplication and a 15,000-point limit; signal history is capped at 2,000
spatial samples. Depth is estimated, limited to 0.2–5 m, and may drift or miss
dark, reflective or featureless surfaces. The display does not estimate the
transmitter's position. Physical acceptance testing on the S21 Ultra is needed.

Google ARCore processes camera/sensor data under Google's policies. The app
shows Google's ARCore disclosure before requesting camera access, with a link
to the Google Privacy Policy. ARCore SDK dependency is pinned to 1.46.0.

## Build steps

Use Flutter 3.24.0 (matching CI). Generate the platform scaffold before building:

```sh
cd mobile/device_scanner
flutter create --platforms=android --org com.casavino --project-name bubble .
# Preserve/restore the repository's lib and pubspec.yaml if Flutter rewrites them.
bash tool/prepare_android.sh
flutter pub get
flutter analyze lib/models/radio_device.dart lib/ui/nearby.dart test
flutter test
flutter build apk --debug
```

The GitHub Actions Android workflow preserves sources, generates the scaffold,
installs native overlays, tests, builds and publishes the `mobile-latest` release.
Its APK is at:
https://github.com/Casa-Vino/Network-program-bubble/releases/download/mobile-latest/app-debug.apk

## S21 Ultra acceptance checks

1. Install alongside the original Device Scanner; both must remain available.
2. Deny permissions initially: no crash; capabilities and status explain missing access.
3. Grant permissions, turn on radios and Location services. Scan near a router,
   a BLE advertiser and a Classic device explicitly placed in discoverable mode.
4. Verify each method produces results or an actionable status; unnamed BLE
   advertisements must still appear. Capability flags must reflect the phone.
5. Follow a BLE device, move closer/further and compare repeated signal samples.
   Stop advertising: last-seen age increases and stale guidance replaces trend.
6. Repeat Wi-Fi scans quickly: cached results retain their original observation age.
7. Background or close Nearby during scanning; Bluetooth discovery must stop.
8. Open Network and confirm existing LAN discovery and transfer screens still work.

## Platform references

- https://developer.android.com/develop/connectivity/wifi/wifi-scan
- https://developer.android.com/develop/connectivity/bluetooth/bt-permissions

Future work: persistent user labels, SSDP enrichment, a proximity visualization,
compatible companion-device ringing, and hardware-supported ranging.

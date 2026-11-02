# Bubble Dev

Bubble Dev installs alongside Bubble with application ID
`com.casavino.bubble.dev`, the launcher name **Bubble Dev**, and a spanner badge
over the existing launcher icon. Its app data and permissions are separate.

The `bubble-dev` branch builds through `build-dev-apk.yml` and publishes
`bubble-dev.apk` and `version.json` to the `bubble-dev-latest` prerelease. Its
in-app updater reads only that release; Bubble continues using `mobile-latest`.
No merge into main is required for testing.

This initial development build contains the existing wireless discovery,
signal layers, ARCore room scan, torch controls and 60k/150k/300k point limits.
Scans remain session-only. Scan saving, reopening and surface reconstruction
are planned subsequent changes; the separate Python prototype is not included.

To reproduce in a generated Android scaffold: run `bash tool/prepare_android.sh`,
then `python3 tool/prepare_dev.py`, and build with
`flutter build apk --debug --dart-define=BUBBLE_DEV=true`. Both the native
preparation and Dart build flag are required. The Actions workflow performs
these steps together, runs the test suite, and retains a consistent signing key
for successive development updates.

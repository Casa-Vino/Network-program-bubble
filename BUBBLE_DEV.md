# Bubble Dev

Bubble Dev installs alongside Bubble with application ID
`com.casavino.bubble.dev`, the launcher name **Bubble Dev**, and a spanner badge
over the existing launcher icon. Its app data and permissions are separate.

The `bubble-dev` branch builds through `build-dev-apk.yml` and publishes
`bubble-dev.apk` and `version.json` to the `bubble-dev-latest` prerelease. Its
in-app updater reads only that release; Bubble continues using `mobile-latest`.
No merge into main is required for testing.

The development build includes wireless discovery, signal layers, ARCore room
scan, torch controls and 60k/150k/300k point limits. Room painting is clipped to
its viewport. Display settings independently control captured points, candidate
walls, signal markers, surface opacity, point size and zoom. Device labels include
an address suffix, and idle discovery no longer displays a stale listening status.

Press **End scan** to freeze observations, release the camera/torch, stop radio
discovery, save the captured points and radio measurements, and interpret walls
on a background isolate. Raw points are saved before fitting. The folder button
reopens saved scans for viewing; **New scan** creates a separate capture. Reopened
scans do not resume tracking or merge coordinate frames. Saves are app-private
versioned JSON snapshots, written through a flushed temporary file and rename.
Storage errors are shown with a retry action. Uninstalling the app removes its
private scans. Capture is only saved after End scan, not automatically on exit.

New captures use an ARCore anchor-relative, Y-up metre frame. This follows
[ARCore's guidance for persisting positions across frames](https://developers.google.com/ar/reference/java/com/google/ar/core/Pose#world-coordinate-space).
It reduces one source of registration problems; it does not eliminate tracking
drift or depth noise, particularly across larger areas.

Wall interpretation uses a 12 cm fitting copy with a 16,000-point reservoir cap,
deterministic vertical-plane RANSAC and least-squares refinement. Connected
support yields convex polygons. Patches must have at least 60 sampled inliers,
0.7 m width, 1.2 m height and 0.8 square metres area. The residual threshold is
6 cm; up to ten planes and 24 polygons are retained. Original captured points
are unchanged. Amber polygons are **candidate vertical surfaces**: tall furniture
may qualify, sloped walls may be missed, and convex patches can cover openings.
Fit residual labels describe agreement with sampled points, not survey accuracy.
No complete room, corners, doorways or missing geometry are inferred. Raw, wall
and signal layers can be compared independently. Signal markers remain phone
measurement positions, not transmitter locations.

To reproduce in a generated Android scaffold: run `bash tool/prepare_android.sh`,
then `python3 tool/prepare_dev.py`, and build with
`flutter build apk --debug --dart-define=BUBBLE_DEV=true`. Both the native
preparation and Dart build flag are required. The Actions workflow performs
these steps together, runs the test suite, and retains a consistent signing key
for successive development updates.

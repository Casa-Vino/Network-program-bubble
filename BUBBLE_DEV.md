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

Room navigation supports one-finger orbit, two-finger pinch zoom and pan, and
double-tap to fit. **Room tools** (three dots) provides top-down, perspective and
fit views. Fit uses the current projected bounds. The smoother display caches
an evenly sampled copy, drawing up to 60,000 points normally or 30,000 during
gestures; disable it to draw all captured points. Capture limits remain separate.
**Hide isolated clusters** is an optional ended-scan review filter: 20 cm cells
need five nearby points spanning at least three neighbouring cells. It can hide
real sparse features, so it starts off. It changes the display only; saved points,
wall fitting and exports retain the original capture. Drawn counts are visible.

Tap a signal marker or choose a device to follow it. The selected device panel
shows fresh RSSI/trend feedback, stale-reading guidance, and its strongest mapped
measurement. A white ring marks that measurement's **phone position**, not the
transmitter. Saved scans show historical measurements, not live tracking.
**Repeat signal scans** is optional in display settings while the room camera is
active. It starts a new foreground discovery session every 32 seconds when the
previous session has ended, and switches off on app pause or End scan. Failed
starts switch repeat scanning off. The Scan signals button also works before
any devices have been discovered.

After ending or reopening a scan, **Room tools** exports full scan JSON, raw
captured points as ASCII PLY, candidate wall polygons as OBJ, or signal
measurements as CSV through the system save dialog. Exports use metres and the
scan's Y-up anchor frame. PLY contains every retained captured point, including
points hidden by display sampling or review filtering. OBJ contains supported
candidate patches, with no invented thickness or missing walls. CSV records
phone measurement coordinates and escapes network-provided names as spreadsheet
text. JSON preserves all snapshot fields; it does not enable resuming an old
ARCore session. No export is created until a save location is chosen.

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

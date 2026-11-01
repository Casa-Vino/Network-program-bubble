#!/usr/bin/env bash
# Prepare a freshly `flutter create`d Android scaffold for this app:
#   1. inject the network permissions + web-intent <queries> into the manifest
#   2. install the MainActivity.kt overlay (multicast-lock method channel)
# Idempotent: safe to run more than once. Run from anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."  # -> mobile/device_scanner
MANIFEST="android/app/src/main/AndroidManifest.xml"
KOTLIN_DST="android/app/src/main/kotlin/com/casavino/bubble/MainActivity.kt"
OVERLAY="android_overlay/MainActivity.kt"

[[ -f "$MANIFEST" ]] || {
  echo "No $MANIFEST — run 'flutter create .' first." >&2
  exit 1
}

# 1) Manifest: permissions + queries (web admin links need package visibility
#    on Android 11+).
if grep -q "ACCESS_WIFI_STATE" "$MANIFEST"; then
  echo "Manifest already prepared."
else
  read -r -d '' BLOCK <<'XML' || true
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-feature android:name="android.hardware.bluetooth" android:required="false" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
    <queries>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="https" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="http" />
        </intent>
    </queries>
XML
  awk -v block="$BLOCK" '
    /<manifest/ && !ins { print; print block; ins=1; next }
    { print }
  ' "$MANIFEST" > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  echo "Injected permissions + queries into $MANIFEST"
fi

# Upgrade previously generated scaffolds as well as preparing fresh ones.
# Location inference is part of Bubble, so neverForLocation is inappropriate.
sed -i 's/ android:usesPermissionFlags="neverForLocation"//g' "$MANIFEST"
for permission in ACCESS_COARSE_LOCATION CHANGE_WIFI_STATE BLUETOOTH_SCAN BLUETOOTH_CONNECT; do
  if ! grep -q "android.permission.$permission\"" "$MANIFEST"; then
    sed -i "/<application/i\\    <uses-permission android:name=\"android.permission.$permission\" />" "$MANIFEST"
  fi
done
if ! grep -q 'android.permission.BLUETOOTH_ADMIN' "$MANIFEST"; then
  sed -i '/<application/i\    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />\n    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />' "$MANIFEST"
fi

# 2) Native MainActivity with the multicast-lock channel.
if [[ -f "$OVERLAY" ]]; then
  mkdir -p "$(dirname "$KOTLIN_DST")"
  cp "$OVERLAY" "$KOTLIN_DST"
  cp android_overlay/BubbleRadio.kt "$(dirname "$KOTLIN_DST")/BubbleRadio.kt"
  echo "Installed MainActivity overlay at $KOTLIN_DST"
else
  echo "WARNING: $OVERLAY missing; mDNS multicast lock will be unavailable." >&2
fi

# Distinct launcher name; package identity comes from flutter create --project-name bubble.
sed -i -E 's/android:label="[^"]*"/android:label="Bubble"/' "$MANIFEST"

# 3) Align the Kotlin Gradle plugin with the kotlin-stdlib that plugins such as
#    url_launcher pull in (1.9.x); the scaffold's default is older and fails
#    with "incompatible version of Kotlin".
KOTLIN_VER="1.9.24"
for f in android/settings.gradle android/settings.gradle.kts; do
  if [[ -f "$f" ]] && grep -q "org.jetbrains.kotlin.android" "$f"; then
    sed -i -E "s/(org\.jetbrains\.kotlin\.android\"[[:space:]]+version[[:space:]]+\")[^\"]+(\")/\1${KOTLIN_VER}\2/" "$f"
    echo "Set kotlin.android version to $KOTLIN_VER in $f"
  fi
done
for f in android/build.gradle android/build.gradle.kts; do
  if [[ -f "$f" ]] && grep -q "ext.kotlin_version" "$f"; then
    sed -i -E "s/(ext\.kotlin_version[[:space:]]*=[[:space:]]*['\"])[^'\"]+(['\"])/\1${KOTLIN_VER}\2/" "$f"
    echo "Set ext.kotlin_version to $KOTLIN_VER in $f"
  fi
done

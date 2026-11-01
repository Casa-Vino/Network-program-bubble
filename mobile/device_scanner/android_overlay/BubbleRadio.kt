package com.casavino.bubble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Foreground, bounded discovery. No pairing, login attempts or fabricated bearings. */
@SuppressLint("MissingPermission")
class BubbleRadio(private val context: Context, messenger: BinaryMessenger) {
    private val handler = Handler(Looper.getMainLooper())
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val adapter get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private var sink: EventChannel.EventSink? = null
    private var active = false
    private var registered = false
    private var bleStarted = false
    private val finish = Runnable { stop() }
    private val beginBle = Runnable { startBle() }

    init {
        EventChannel(messenger, "bubble/radio/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
            override fun onCancel(arguments: Any?) { stop(); sink = null }
        })
        MethodChannel(messenger, "bubble/radio").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(capabilities())
                    "start" -> { start(); result.success(null) }
                    "stop" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("radio", e.message, null) }
        }
    }

    private fun permitted(permission: String) = Build.VERSION.SDK_INT < 23 ||
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun capabilities(): Map<String, Any> {
        val pm = context.packageManager
        val connect = Build.VERSION.SDK_INT < 31 || permitted(Manifest.permission.BLUETOOTH_CONNECT)
        val location = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val locationOn = if (Build.VERSION.SDK_INT >= 28) location.isLocationEnabled
            else location.isProviderEnabled(LocationManager.GPS_PROVIDER) || location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        return linkedMapOf(
            "Phone" to "${Build.MANUFACTURER} ${Build.MODEL} / Android ${Build.VERSION.RELEASE}",
            "Wi-Fi radio" to wifi.isWifiEnabled,
            "Bluetooth hardware" to pm.hasSystemFeature("android.hardware.bluetooth"),
            "Bluetooth LE hardware" to pm.hasSystemFeature("android.hardware.bluetooth_le"),
            "Bluetooth enabled" to (connect && adapter?.isEnabled == true),
            "Precise location permission" to permitted(Manifest.permission.ACCESS_FINE_LOCATION),
            "Bluetooth scan permission" to (Build.VERSION.SDK_INT < 31 || permitted(Manifest.permission.BLUETOOTH_SCAN)),
            "Bluetooth connect permission" to connect,
            "Location services" to locationOn,
            "Wi-Fi RTT hardware (ranging not implemented)" to pm.hasSystemFeature("android.hardware.wifi.rtt"),
            "Wi-Fi Aware hardware (discovery not implemented)" to pm.hasSystemFeature("android.hardware.wifi.aware"),
            "UWB hardware (ranging not implemented)" to pm.hasSystemFeature("android.hardware.uwb"),
            "NFC hardware (tap range only)" to pm.hasSystemFeature("android.hardware.nfc")
        )
    }

    private fun status(message: String) { sink?.success(mapOf("type" to "status", "message" to message)) }

    private fun observation(kind: String, address: String, name: String?, rssi: Int, detail: String, time: Long = System.currentTimeMillis()) {
        if (!active || address.isBlank() || rssi !in -127..-1) return
        sink?.success(mapOf("type" to "observation", "kind" to kind, "address" to address,
            "name" to (name ?: ""), "rssi" to rssi, "detail" to detail, "time" to time))
    }

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) { reportBle(result) }
        override fun onBatchScanResults(results: MutableList<ScanResult>) { results.forEach { reportBle(it) } }
        override fun onScanFailed(errorCode: Int) { status("Bluetooth LE scan failed (code $errorCode). Stop and retry.") }
    }

    private fun reportBle(result: ScanResult) {
        try {
            val record = result.scanRecord
            val services = record?.serviceUuids?.joinToString() ?: "No service UUID advertised"
            observation("ble", result.device.address, record?.deviceName ?: result.device.name,
                result.rssi, services)
        } catch (e: SecurityException) { status("Bluetooth permission changed: ${e.message}") }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!active) return
            try {
                when (intent.action) {
                    WifiManager.SCAN_RESULTS_AVAILABLE_ACTION -> {
                        if (intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false)) readWifi()
                        else status("Wi-Fi refresh unavailable; previously seen results remain labelled with their age.")
                    }
                    BluetoothDevice.ACTION_FOUND -> {
                        @Suppress("DEPRECATION")
                        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                        if (device != null) observation("classic", device.address, device.name,
                            intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt(), "Discoverable Bluetooth device")
                    }
                }
            } catch (e: Exception) { status("Discovery: ${e.message}") }
        }
    }

    private fun readWifi() {
        @Suppress("DEPRECATION")
        for (ap in wifi.scanResults) {
            val ageMs = (SystemClock.elapsedRealtime() - ap.timestamp / 1000).coerceAtLeast(0)
            val rtt = Build.VERSION.SDK_INT >= 23 && ap.is80211mcResponder
            observation("wifi", ap.BSSID, ap.SSID, ap.level,
                "${ap.frequency} MHz · ${ap.capabilities}" + if (rtt) " · RTT responder" else "",
                System.currentTimeMillis() - ageMs)
        }
    }

    private fun start() {
        stop()
        active = true
        val filter = IntentFilter().apply {
            addAction(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            addAction(BluetoothDevice.ACTION_FOUND)
        }
        // Bluetooth broadcasts may originate from the privileged Bluetooth app.
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else context.registerReceiver(receiver, filter)
        registered = true
        handler.postDelayed(finish, 30000)
        try {
            readWifi()
            @Suppress("DEPRECATION")
            val accepted = wifi.startScan()
            if (!accepted) status("Wi-Fi refresh throttled or unavailable; showing timestamped cached observations.")
        } catch (e: Exception) { status("Wi-Fi scan unavailable: ${e.message}") }
        // Classic inquiry first, BLE afterwards to reduce contention on the shared radio.
        try {
            if (adapter?.isEnabled == true) {
                if (adapter?.startDiscovery() != true) status("Classic Bluetooth discovery could not start.")
                status("Classic Bluetooth discovery, then Bluetooth LE; 30 seconds total.")
                handler.postDelayed(beginBle, 13000)
            } else status("Bluetooth is off or unavailable. Enable it and scan again.")
        } catch (e: Exception) {
            status("Classic Bluetooth unavailable: ${e.message}")
            startBle()
        }
    }

    private fun startBle() {
        if (!active) return
        try {
            adapter?.cancelDiscovery()
            val scanner = adapter?.bluetoothLeScanner
            if (scanner == null) { status("Bluetooth LE scanner unavailable."); return }
            scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
            bleStarted = true
            status("Listening for Bluetooth LE advertisements…")
        } catch (e: Exception) { status("Bluetooth LE unavailable: ${e.message}") }
    }

    fun stop() {
        val wasActive = active
        active = false
        handler.removeCallbacks(finish)
        handler.removeCallbacks(beginBle)
        try { if (bleStarted) adapter?.bluetoothLeScanner?.stopScan(callback) } catch (_: Exception) {}
        bleStarted = false
        try { adapter?.cancelDiscovery() } catch (_: Exception) {}
        if (registered) { context.unregisterReceiver(receiver); registered = false }
        if (wasActive) sink?.success(mapOf("type" to "stopped"))
    }
}

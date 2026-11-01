package com.casavino.bubble

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Adds a method channel so the Dart side can hold a Wi-Fi MulticastLock while
/// it runs mDNS/DNS-SD discovery. Without the lock, Android drops inbound
/// multicast and Bonjour comes back empty.
///
/// Note: the lock helpers are named *Lock to avoid clashing with FlutterActivity's
/// own public release() method.
class MainActivity : FlutterActivity() {
    private val channelName = "device_scanner/multicast"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var radio: BubbleRadio? = null
    private var room: BubbleRoom? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        radio = BubbleRadio(this, flutterEngine.dartExecutor.binaryMessenger)
        room = BubbleRoom(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry.registerViewFactory("bubble/room", room!!)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireLock()
                        result.success(true)
                    }
                    "release" -> {
                        releaseLock()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun acquireLock() {
        if (multicastLock == null) {
            val wifi =
                applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = wifi.createMulticastLock("device_scanner")
            lock.setReferenceCounted(true)
            multicastLock = lock
        }
        multicastLock?.acquire()
    }

    private fun releaseLock() {
        val lock = multicastLock
        if (lock != null && lock.isHeld) {
            lock.release()
        }
    }

    override fun onDestroy() {
        room?.close()
        radio?.stop()
        releaseLock()
        super.onDestroy()
    }

    override fun onPause() {
        room?.pause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        room?.resume()
    }

    override fun onStop() {
        radio?.stop()
        super.onStop()
    }
}

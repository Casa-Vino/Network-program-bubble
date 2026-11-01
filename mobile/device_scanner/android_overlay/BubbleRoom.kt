package com.casavino.bubble

import android.app.Activity
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.View
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** Camera runs only while this optional platform view exists. No Cloud Anchors. */
class BubbleRoom(private val activity: Activity, messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var active: RoomView? = null
    init {
        EventChannel(messenger, "bubble/room/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null }
        })
    }
    private fun emit(data: Map<String, Any>) { main.post { sink?.success(data) } }
    override fun create(context: android.content.Context, viewId: Int, args: Any?): PlatformView {
        active?.dispose()
        return RoomView().also { active = it }
    }
    fun pause() { active?.pause() }
    fun resume() { active?.resume() }
    fun close() { active?.dispose(); active = null }

    private inner class RoomView : PlatformView, GLSurfaceView.Renderer {
        private val surface = GLSurfaceView(activity)
        private var session: Session? = null
        @Volatile private var running = false
        @Volatile private var disposed = false
        private var texture = 0
        private var lastFrame = 0L
        private var lastDepth = 0L
        init {
            surface.setEGLContextClientVersion(2)
            surface.preserveEGLContextOnPause = true
            surface.setRenderer(this)
            try {
                if (ArCoreApk.getInstance().requestInstall(activity, true) == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
                    emit(mapOf("state" to "AR installation requested. Complete it, then reopen Room scan."))
                } else {
                    val s = Session(activity)
                    if (!s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                        s.close()
                        emit(mapOf("state" to "Depth is unavailable on this device. Nearby discovery remains available."))
                    } else {
                        val config = Config(s).apply { depthMode = Config.DepthMode.AUTOMATIC }
                        s.configure(config)
                        session = s
                        resume()
                    }
                }
            } catch (e: Exception) { emit(mapOf("state" to "AR unavailable: ${e.message}. Check camera permission and Google Play Services for AR.")) }
        }
        override fun getView(): View = surface
        fun resume() {
            if (disposed || running) return
            try {
                session?.resume() ?: return
                running = true
                surface.onResume()
            } catch (e: Exception) { emit(mapOf("state" to "Camera unavailable: ${e.message}. Reopen Room scan to retry.")) }
        }
        fun pause() {
            if (!running) return
            running = false
            surface.onPause()
            session?.pause()
            emit(mapOf("state" to "Room scan paused", "tracking" to false))
        }
        override fun dispose() {
            if (disposed) return
            pause()
            disposed = true
            session?.close()
            session = null
            if (active === this) active = null
        }
        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            texture = textures[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        }
        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            GLES20.glViewport(0, 0, width, height)
            @Suppress("DEPRECATION")
            val rotation = activity.windowManager.defaultDisplay.rotation
            session?.setDisplayGeometry(rotation, width, height)
        }
        override fun onDrawFrame(gl: GL10?) {
            GLES20.glClearColor(0.02f, 0.04f, 0.04f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            val s = session ?: return
            if (!running || disposed) return
            val now = System.currentTimeMillis()
            if (now - lastFrame < 200) return
            lastFrame = now
            try {
                @Suppress("DEPRECATION")
                val rotation = activity.windowManager.defaultDisplay.rotation
                s.setDisplayGeometry(rotation, surface.width.coerceAtLeast(1), surface.height.coerceAtLeast(1))
                s.setCameraTextureName(texture)
                val frame = s.update()
                val camera = frame.camera
                if (camera.trackingState != TrackingState.TRACKING) {
                    emit(mapOf("state" to "Tracking paused: ${camera.trackingFailureReason}. Move slowly in good light.", "tracking" to false))
                    return
                }
                val pose = camera.pose
                val data = mutableMapOf<String, Any>("state" to "Tracking · move slowly to reveal surfaces", "tracking" to true,
                    "time" to now, "pose" to listOf(pose.tx(), pose.ty(), pose.tz()))
                try {
                    frame.acquireDepthImage16Bits().use { depth ->
                        if (depth.timestamp != lastDepth) {
                            lastDepth = depth.timestamp
                            val plane = depth.planes[0]
                            val buffer = plane.buffer.order(ByteOrder.LITTLE_ENDIAN)
                            val intrinsics = camera.imageIntrinsics
                            val dimensions = intrinsics.imageDimensions
                            val fx = intrinsics.focalLength[0] * depth.width / dimensions[0]
                            val fy = intrinsics.focalLength[1] * depth.height / dimensions[1]
                            val cx = intrinsics.principalPoint[0] * depth.width / dimensions[0]
                            val cy = intrinsics.principalPoint[1] * depth.height / dimensions[1]
                            val points = ArrayList<Double>()
                            val step = maxOf(4, depth.width / 24)
                            for (y in 0 until depth.height step step) {
                                for (x in 0 until depth.width step step) {
                                    val mm = buffer.getShort(y * plane.rowStride + x * plane.pixelStride).toInt() and 0xffff
                                    if (mm !in 200..5000) continue
                                    val z = mm / 1000f
                                    val world = pose.transformPoint(floatArrayOf((x-cx)*z/fx, -(y-cy)*z/fy, -z))
                                    points.add(world[0].toDouble()); points.add(world[1].toDouble()); points.add(world[2].toDouble())
                                }
                            }
                            data["points"] = points
                        }
                    }
                } catch (_: NotYetAvailableException) { data["state"] = "Tracking · waiting for depth; move across textured surfaces" }
                emit(data)
            } catch (e: Exception) { emit(mapOf("state" to "AR frame unavailable: ${e.message}", "tracking" to false)) }
        }
    }
}

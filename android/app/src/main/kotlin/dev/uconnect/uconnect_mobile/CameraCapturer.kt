package dev.uconnect.uconnect_mobile

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Captures a device camera through Camera2 and encodes it to H.264 for a peer
// to watch (the host side of protocol 7.4, cam.*). The camera feeds frames
// straight into the encoder's input Surface; encoded Annex-B access units are
// sent to Dart (screen_host.dart via camera_capture.dart), which fragments
// them into kind-3 video datagrams. SPS/PPS are prepended to each keyframe.
//
// Driven over "uconnect/camera":
//   requestPermission()              -> { granted }
//   cameras()                        -> [ { id, facing } ]
//   start(width,height,fps,bitrate,cameraId?) -> { width, height }
//   requestKeyframe(); setBitrate(bitrate); stop()
// Access units stream over the "uconnect/camera/au" EventChannel.
class CameraCapturer(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "uconnect/camera")
    private val events = EventChannel(messenger, "uconnect/camera/au")
    private val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var sink: EventChannel.EventSink? = null
    private var permission: MethodChannel.Result? = null

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var codecConfig: ByteArray? = null // SPS/PPS, prepended to keyframes
    private var capFps = 30
    private var capBitrate = 2_000_000

    companion object {
        const val PERMISSION_REQUEST = 7101
    }

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, s: EventChannel.EventSink?) { sink = s }
            override fun onCancel(arguments: Any?) { sink = null }
        })
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "requestPermission" -> requestPermission(result)
            "cameras" -> result.success(listCameras())
            "start" -> {
                val w = call.argument<Int>("width") ?: 1280
                val h = call.argument<Int>("height") ?: 720
                val fps = call.argument<Int>("fps") ?: 30
                val bitrate = call.argument<Int>("bitrate") ?: 2_000_000
                val id = call.argument<String>("cameraId")
                start(w, h, fps, bitrate, id, result)
            }
            "requestKeyframe" -> { requestKeyframe(); result.success(null) }
            "setBitrate" -> { setBitrate(call.argument<Int>("bitrate") ?: 2_000_000); result.success(null) }
            "stop" -> { stop(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun granted() =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (granted()) { result.success(mapOf("granted" to true)); return }
        permission = result
        ActivityCompat.requestPermissions(
            activity, arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST)
    }

    // Called by MainActivity when the camera permission dialog returns.
    fun onPermissionResult(grantResults: IntArray) {
        val ok = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permission?.success(mapOf("granted" to ok))
        permission = null
    }

    private fun listCameras(): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        for (id in manager.cameraIdList) {
            val facing = when (manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                else -> "external"
            }
            out.add(mapOf("id" to id, "facing" to facing))
        }
        return out
    }

    // The first back-facing camera, or just the first one.
    private fun pickCamera(requested: String?): String? {
        if (requested != null && manager.cameraIdList.contains(requested)) return requested
        for (id in manager.cameraIdList) {
            if (manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK) return id
        }
        return manager.cameraIdList.firstOrNull()
    }

    // The camera output size closest to (but not above) the requested width,
    // keeping the camera's own aspect; H.264 wants even dimensions.
    private fun pickSize(characteristics: CameraCharacteristics, maxWidth: Int): Size {
        val map = characteristics.get(
            CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty()
        if (sizes.isEmpty()) return Size(1280, 720)
        val fit = sizes.filter { it.width <= maxWidth }.maxByOrNull { it.width.toLong() * it.height }
        val chosen = fit ?: sizes.minByOrNull { it.width.toLong() * it.height }!!
        return Size(chosen.width and 1.inv(), chosen.height and 1.inv())
    }

    private fun start(
        reqW: Int, reqH: Int, fps: Int, bitrate: Int, cameraId: String?,
        result: MethodChannel.Result,
    ) {
        stop()
        if (!granted()) { result.success(mapOf("width" to 0, "height" to 0)); return }
        val id = pickCamera(cameraId)
        if (id == null) { result.success(mapOf("width" to 0, "height" to 0)); return }
        capFps = fps.coerceIn(1, 60)
        capBitrate = bitrate

        val characteristics = manager.getCameraCharacteristics(id)
        val size = pickSize(characteristics, reqW)
        val fpsRange = pickFpsRange(characteristics, capFps)

        val t = HandlerThread("uconnect-camera").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        handler = h

        try {
            buildEncoder(size)
        } catch (e: Throwable) {
            report(e.message ?: "camera encoder failed")
            stop(); result.success(mapOf("width" to 0, "height" to 0)); return
        }

        // The camera's callbacks run on its own thread; Flutter takes replies
        // and messages on the main thread only.
        var answered = false
        fun answer(w: Int, hgt: Int) {
            activity.runOnUiThread {
                if (!answered) { answered = true; result.success(mapOf("width" to w, "height" to hgt)) }
            }
        }

        try {
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    device = cam
                    val surface = inputSurface
                    if (surface == null) { answer(0, 0); return }
                    try {
                        @Suppress("DEPRECATION")
                        cam.createCaptureSession(listOf(surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    captureSession = session
                                    try {
                                        val builder = cam.createCaptureRequest(
                                            CameraDevice.TEMPLATE_RECORD)
                                        builder.addTarget(surface)
                                        builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
                                        session.setRepeatingRequest(builder.build(), null, h)
                                        answer(size.width, size.height)
                                    } catch (e: Throwable) {
                                        report(e.message ?: "camera request failed")
                                        answer(0, 0)
                                    }
                                }
                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    report("camera session failed")
                                    answer(0, 0)
                                }
                            }, h)
                    } catch (e: Throwable) {
                        report(e.message ?: "camera session error")
                        answer(0, 0)
                    }
                }
                override fun onDisconnected(cam: CameraDevice) { cam.close(); if (device == cam) device = null }
                override fun onError(cam: CameraDevice, error: Int) {
                    report("camera error $error")
                    cam.close(); answer(0, 0)
                }
            }, h)
        } catch (e: SecurityException) {
            answer(0, 0)
        } catch (e: Throwable) {
            report(e.message ?: "openCamera failed")
            answer(0, 0)
        }
    }

    private fun pickFpsRange(c: CameraCharacteristics, fps: Int): Range<Int> {
        val ranges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.toList().orEmpty()
        // Among the ranges that reach the target fps, prefer the one with the
        // highest lower bound so the camera holds that rate (e.g. [30,30] over
        // [5,30]). Picking only by the upper bound could land on a variable
        // range whose auto-exposure then drops to a handful of fps in dim light.
        return ranges.filter { it.upper <= fps }
            .maxWithOrNull(compareBy({ it.upper }, { it.lower }))
            ?: ranges.minByOrNull { it.upper } ?: Range(fps, fps)
    }

    private fun buildEncoder(size: Size) {
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height
        ).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, capBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, capFps)
            // No keyframe on a schedule: each costs several frames' worth of bytes
            // and on a thin uplink is what gets lost. The viewer asks for one
            // when it needs one (requestKeyframe); between, intra refresh
            // repairs the picture a few rows at a time, within the bitrate.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1 shl 20)
            setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, capFps * 2)
            // A still picture: the last frame again once a second, so the
            // viewer and the rate estimate keep hearing from the encoder.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L)
            setInteger(MediaFormat.KEY_LATENCY, 1)
            // Constant bitrate: the sender paces to the estimate, and a burst
                // over it (as VBR allows) only queues or is lost.
                setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }
        val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.setCallback(encoderCallback, handler)
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = c.createInputSurface()
        c.start()
        codec = c
    }

    private val encoderCallback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {}
        override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            try {
                val buf = mc.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size); buf.get(bytes)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        codecConfig = bytes
                    } else {
                        val keyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        val au = if (keyframe && codecConfig != null) codecConfig!! + bytes else bytes
                        emit(au, keyframe, info.presentationTimeUs)
                    }
                }
                mc.releaseOutputBuffer(index, false)
            } catch (_: IllegalStateException) {}
        }
        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            activity.runOnUiThread { sink?.error("encoder", e.message, null) }
        }
        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {}
    }

    // Tells Dart about a failure, from whichever thread it happened on.
    private fun report(message: String) {
        android.util.Log.w("uconnect-camera", message)
        activity.runOnUiThread { channel.invokeMethod("error", message) }
    }

    private fun emit(au: ByteArray, keyframe: Boolean, ptsUs: Long) {
        activity.runOnUiThread {
            sink?.success(mapOf("bytes" to au, "keyframe" to keyframe, "ptsUs" to ptsUs))
        }
    }

    private fun requestKeyframe() {
        val c = codec ?: return
        val b = Bundle(); b.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
        try { c.setParameters(b) } catch (_: IllegalStateException) {}
    }

    private fun setBitrate(bitrate: Int) {
        val c = codec ?: return
        val b = Bundle(); b.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
        try { c.setParameters(b) } catch (_: IllegalStateException) {}
    }

    private fun stop() {
        try { captureSession?.close() } catch (_: Throwable) {}
        captureSession = null
        try { device?.close() } catch (_: Throwable) {}
        device = null
        try { codec?.stop(); codec?.release() } catch (_: Throwable) {}
        codec = null
        inputSurface?.release(); inputSurface = null
        codecConfig = null
        thread?.quitSafely(); thread = null; handler = null
    }
}

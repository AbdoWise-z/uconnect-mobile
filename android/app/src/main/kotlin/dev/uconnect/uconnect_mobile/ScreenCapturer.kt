package dev.uconnect.uconnect_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Captures the phone's screen and encodes it to H.264 for a peer to watch
// (the host side of protocol section 7). The pixels are mirrored into an
// encoder input Surface by a VirtualDisplay; encoded Annex-B access units are
// sent to Dart (screen_host.dart), which fragments them into video datagrams.
// SPS/PPS are prepended to each keyframe so the viewer can configure from it.
//
// Driven over "uconnect/capture":
//   requestConsent()               -> { granted }   (shows Android's dialog)
//   start(width,height,fps,bitrate)-> { width, height }
//   requestKeyframe()
//   setBitrate(bitrate)
//   stop()
// Access units stream to Dart over the "uconnect/capture/au" EventChannel.
class ScreenCapturer(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "uconnect/capture")
    private val events = EventChannel(messenger, "uconnect/capture/au")
    private val main = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var consent: MethodChannel.Result? = null
    private var resultCode = 0
    private var resultData: Intent? = null

    private var projection: MediaProjection? = null
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var codecConfig: ByteArray? = null // SPS/PPS, prepended to keyframes

    companion object {
        const val CONSENT_REQUEST = 7001
    }

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, s: EventChannel.EventSink?) {
                sink = s
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "requestConsent" -> {
                consent = result
                val mgr = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                        as MediaProjectionManager
                activity.startActivityForResult(
                    mgr.createScreenCaptureIntent(), CONSENT_REQUEST
                )
            }
            "start" -> {
                val w = call.argument<Int>("width") ?: 1280
                val h = call.argument<Int>("height") ?: 720
                val fps = call.argument<Int>("fps") ?: 30
                val bitrate = call.argument<Int>("bitrate") ?: 4_000_000
                start(w, h, fps, bitrate, result)
            }
            "requestKeyframe" -> {
                requestKeyframe(); result.success(null)
            }
            "setBitrate" -> {
                setBitrate(call.argument<Int>("bitrate") ?: 2_000_000)
                result.success(null)
            }
            "stop" -> {
                stop(); result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Called by MainActivity when the capture-consent dialog returns.
    fun onConsentResult(code: Int, data: Intent?) {
        resultCode = code
        resultData = data
        val granted = code == Activity.RESULT_OK && data != null
        consent?.success(mapOf("granted" to granted))
        consent = null
    }

    // Remembered so the capture can be rebuilt at the new size on rotation.
    private var capReqW = 1280
    private var capReqH = 720
    private var capFps = 30
    private var capBitrate = 4_000_000

    private fun start(reqW: Int, reqH: Int, fps: Int, bitrate: Int, result: MethodChannel.Result) {
        stop()
        val data = resultData
        if (data == null) {
            result.success(mapOf("width" to 0, "height" to 0))
            return
        }
        capReqW = reqW; capReqH = reqH; capFps = fps; capBitrate = bitrate

        // Android 14+: the mediaProjection foreground service must be *running*
        // before getMediaProjection is called, and startForegroundService is
        // asynchronous -- so finish setup only once the service reports it is
        // in the foreground.
        ScreenCaptureService.start(activity.applicationContext) {
            main.post { result.success(finishStart(data)) }
        }
    }

    // Fits the current screen within the requested bounds, keeping aspect and
    // even dimensions (H.264 requires even width/height).
    private data class Dim(val width: Int, val height: Int, val dpi: Int)

    private fun currentDim(): Dim {
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        activity.windowManager.defaultDisplay.getRealMetrics(m)
        val scale = minOf(capReqW.toFloat() / m.widthPixels, capReqH.toFloat() / m.heightPixels, 1f)
        val w = (m.widthPixels * scale).toInt() and 0xFFFFFFFE.toInt()
        val h = (m.heightPixels * scale).toInt() and 0xFFFFFFFE.toInt()
        return Dim(w, h, m.densityDpi)
    }

    private fun finishStart(data: Intent): Map<String, Any> {
        try {
            val mgr = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                    as MediaProjectionManager
            val proj = mgr.getMediaProjection(resultCode, data)
                ?: run {
                    ScreenCaptureService.stop(activity.applicationContext)
                    return mapOf("width" to 0, "height" to 0)
                }
            projection = proj
            proj.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    main.post { this@ScreenCapturer.stop() }
                }
            }, main)
            val dim = currentDim()
            buildEncoderAndDisplay(dim)
            return mapOf("width" to dim.width, "height" to dim.height)
        } catch (t: Throwable) {
            channel.invokeMethod("error", t.message ?: "capture failed")
            stop()
            return mapOf("width" to 0, "height" to 0)
        }
    }

    // (Re)creates the encoder, its input surface and the mirroring virtual
    // display at the given size, keeping the existing MediaProjection.
    private fun buildEncoderAndDisplay(dim: Dim) {
        virtualDisplay?.release()
        virtualDisplay = null
        try {
            codec?.stop(); codec?.release()
        } catch (_: Throwable) {
        }
        inputSurface?.release()
        codecConfig = null

        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, dim.width, dim.height
        ).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
            )
            setInteger(MediaFormat.KEY_BIT_RATE, capBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, capFps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            setInteger(MediaFormat.KEY_LATENCY, 1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setInteger(
                    MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
                )
            }
        }
        val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.setCallback(encoderCallback)
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = c.createInputSurface()
        c.start()
        codec = c

        virtualDisplay = projection?.createVirtualDisplay(
            "uconnect-screen", dim.width, dim.height, dim.dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface, null, main
        )
    }

    // The screen rotated (or its size changed): rebuild at the new dimensions
    // and tell Dart the new size so the viewer can follow it.
    fun onRotation() {
        if (projection == null || codec == null) return
        main.post {
            try {
                buildEncoderAndDisplay(currentDim())
            } catch (t: Throwable) {
                channel.invokeMethod("error", t.message ?: "re-capture failed")
            }
        }
    }

    private val encoderCallback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {}

        override fun onOutputBufferAvailable(
            mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo
        ) {
            try {
                val buf = mc.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buf.get(bytes)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        // SPS/PPS: keep it to prepend to keyframes.
                        codecConfig = bytes
                    } else {
                        val keyframe =
                            info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        val au = if (keyframe && codecConfig != null) {
                            codecConfig!! + bytes
                        } else {
                            bytes
                        }
                        emit(au, keyframe, info.presentationTimeUs)
                    }
                }
                mc.releaseOutputBuffer(index, false)
            } catch (_: IllegalStateException) {
            }
        }

        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            main.post { sink?.error("encoder", e.message, null) }
        }

        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {}
    }

    private fun emit(au: ByteArray, keyframe: Boolean, ptsUs: Long) {
        main.post {
            sink?.success(
                mapOf(
                    "bytes" to au,
                    "keyframe" to keyframe,
                    "ptsUs" to ptsUs
                )
            )
        }
    }

    private fun requestKeyframe() {
        val c = codec ?: return
        val b = Bundle()
        b.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
        try {
            c.setParameters(b)
        } catch (_: IllegalStateException) {
        }
    }

    private fun setBitrate(bitrate: Int) {
        val c = codec ?: return
        val b = Bundle()
        b.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
        try {
            c.setParameters(b)
        } catch (_: IllegalStateException) {
        }
    }

    private fun stop() {
        try {
            virtualDisplay?.release()
        } catch (_: Throwable) {
        }
        virtualDisplay = null
        try {
            codec?.stop()
            codec?.release()
        } catch (_: Throwable) {
        }
        codec = null
        inputSurface?.release()
        inputSurface = null
        try {
            projection?.stop()
        } catch (_: Throwable) {
        }
        projection = null
        codecConfig = null
        ScreenCaptureService.stop(activity.applicationContext)
    }
}

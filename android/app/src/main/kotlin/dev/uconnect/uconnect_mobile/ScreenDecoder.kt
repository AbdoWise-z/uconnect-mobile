package dev.uconnect.uconnect_mobile

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.ArrayDeque

// Decodes the H.264 access units the screen viewer reassembles (see
// lib/core/screen/screen_viewer.dart) and renders them into a Flutter texture,
// so a shared desktop screen shows inside a Flutter widget. One decoder per
// live view session; driven over the "uconnect/screen" MethodChannel:
//
//   create()                 -> { textureId }
//   decode(bytes, keyframe, ptsUs)   feed one Annex-B access unit
//   dispose()
//
// The stream carries SPS/PPS inside each keyframe (protocol 7.3), so the codec
// is configured from the first keyframe and frames flow after that.
class ScreenDecoder(
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "uconnect/screen")

    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var configured = false
    private var sawKeyframe = false

    // Access units waiting for a free input buffer.
    private data class Unit(val bytes: ByteArray, val ptsUs: Long, val keyframe: Boolean)
    private val pending = ArrayDeque<Unit>()
    private val freeInputs = ArrayDeque<Int>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "create" -> result.success(create())
            "decode" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val keyframe = call.argument<Boolean>("keyframe") ?: false
                val ptsUs = (call.argument<Number>("ptsUs") ?: 0).toLong()
                if (bytes != null) feed(bytes, keyframe, ptsUs)
                result.success(null)
            }
            "dispose" -> {
                disposeDecoder()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun create(): Map<String, Any> {
        disposeDecoder()
        val e = textures.createSurfaceTexture()
        entry = e
        surface = Surface(e.surfaceTexture())
        configured = false
        sawKeyframe = false
        return mapOf("textureId" to e.id())
    }

    @Synchronized
    private fun feed(bytes: ByteArray, keyframe: Boolean, ptsUs: Long) {
        val s = surface ?: return
        if (!configured) {
            if (!keyframe) return // wait for the first keyframe (holds SPS/PPS)
            val (sps, pps) = extractParameterSets(bytes) ?: return
            val fmt = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC, widthOf(sps), heightOf(sps)
            )
            fmt.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
            fmt.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
            try {
                val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                c.setCallback(callback)
                c.configure(fmt, s, null, 0)
                c.start()
                codec = c
                configured = true
            } catch (t: Throwable) {
                channel.invokeMethod("error", t.message ?: "decoder failed")
                return
            }
        }
        if (keyframe) sawKeyframe = true
        if (!sawKeyframe) return
        pending.add(Unit(bytes, ptsUs, keyframe))
        drain()
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
            synchronized(this@ScreenDecoder) {
                freeInputs.add(index)
                drain()
            }
        }

        override fun onOutputBufferAvailable(
            mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo
        ) {
            // true = render this frame to the output Surface (the texture).
            try {
                mc.releaseOutputBuffer(index, info.size != 0)
            } catch (_: IllegalStateException) {
            }
        }

        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            channel.invokeMethod("error", e.message ?: "decoder error")
        }

        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
            val w = format.getInteger(MediaFormat.KEY_WIDTH)
            val h = format.getInteger(MediaFormat.KEY_HEIGHT)
            entry?.surfaceTexture()?.setDefaultBufferSize(w, h)
            channel.invokeMethod("size", mapOf("width" to w, "height" to h))
        }
    }

    private fun drain() {
        val c = codec ?: return
        while (freeInputs.isNotEmpty() && pending.isNotEmpty()) {
            val index = freeInputs.poll()
            val unit = pending.poll()
            val buf = try {
                c.getInputBuffer(index)
            } catch (_: IllegalStateException) {
                null
            } ?: return
            buf.clear()
            buf.put(unit.bytes)
            val flags = if (unit.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            c.queueInputBuffer(index, 0, unit.bytes.size, unit.ptsUs, flags)
        }
    }

    @Synchronized
    private fun disposeDecoder() {
        try {
            codec?.stop()
        } catch (_: Throwable) {
        }
        try {
            codec?.release()
        } catch (_: Throwable) {
        }
        codec = null
        configured = false
        sawKeyframe = false
        pending.clear()
        freeInputs.clear()
        surface?.release()
        surface = null
        entry?.release()
        entry = null
    }

    // --- Annex-B parameter-set parsing -----------------------------------------

    // Splits an Annex-B access unit into NAL units and returns the SPS (type 7)
    // and PPS (type 8), each with a 4-byte start code, as MediaCodec wants.
    private fun extractParameterSets(au: ByteArray): Pair<ByteArray, ByteArray>? {
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        val starts = nalStarts(au)
        for (i in starts.indices) {
            val begin = starts[i]
            val end = if (i + 1 < starts.size) starts[i + 1] else au.size
            val nalType = au[begin].toInt() and 0x1F
            if (nalType == 7 || nalType == 8) {
                val withCode = ByteArray(4 + (end - begin))
                withCode[3] = 1
                System.arraycopy(au, begin, withCode, 4, end - begin)
                if (nalType == 7) sps = withCode else pps = withCode
            }
        }
        return if (sps != null && pps != null) Pair(sps, pps) else null
    }

    // Byte offsets just after each start code (00 00 01 or 00 00 00 01).
    private fun nalStarts(b: ByteArray): List<Int> {
        val out = ArrayList<Int>()
        var i = 0
        while (i + 3 < b.size) {
            if (b[i].toInt() == 0 && b[i + 1].toInt() == 0) {
                if (b[i + 2].toInt() == 1) {
                    out.add(i + 3); i += 3; continue
                }
                if (b[i + 2].toInt() == 0 && b[i + 3].toInt() == 1) {
                    out.add(i + 4); i += 4; continue
                }
            }
            i++
        }
        return out
    }

    // Minimal SPS parse for coded width/height. Falls back to 1280x720 if the
    // bitstream is not understood; onOutputFormatChanged corrects it anyway.
    private fun widthOf(sps: ByteArray) = spsDims(sps)?.first ?: 1280
    private fun heightOf(sps: ByteArray) = spsDims(sps)?.second ?: 720

    private fun spsDims(spsWithCode: ByteArray): Pair<Int, Int>? {
        return try {
            // Skip the 4-byte start code and the 1-byte NAL header.
            val rbsp = stripEmulation(spsWithCode, 5)
            val r = BitReader(rbsp)
            r.u(8) // profile_idc
            r.u(8) // constraint flags + reserved
            r.u(8) // level_idc
            r.ue() // seq_parameter_set_id
            // High profiles carry chroma info before the frame dimensions.
            // We only support the common 8-bit 4:2:0 path; bail otherwise.
            val profile = rbsp[0].toInt() and 0xFF
            if (profile in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128)) {
                val chroma = r.ue()
                if (chroma == 3) r.u(1)
                r.ue(); r.ue(); r.u(1)
                if (r.u(1) == 1) return null // scaling lists: give up, use fallback
            }
            r.ue() // log2_max_frame_num
            val poc = r.ue()
            if (poc == 0) r.ue() else if (poc == 1) {
                r.u(1); r.se(); r.se(); val n = r.ue(); repeat(n) { r.se() }
            }
            r.ue() // max_num_ref_frames
            r.u(1) // gaps_in_frame_num
            val widthMbs = r.ue() + 1
            val heightMapUnits = r.ue() + 1
            val frameMbsOnly = r.u(1)
            val width = widthMbs * 16
            val height = (2 - frameMbsOnly) * heightMapUnits * 16
            Pair(width, height)
        } catch (_: Throwable) {
            null
        }
    }

    private fun stripEmulation(data: ByteArray, from: Int): ByteArray {
        val out = ArrayList<Byte>(data.size - from)
        var zeros = 0
        var i = from
        while (i < data.size) {
            val b = data[i]
            if (zeros >= 2 && b.toInt() == 3) {
                zeros = 0; i++; continue
            }
            out.add(b)
            zeros = if (b.toInt() == 0) zeros + 1 else 0
            i++
        }
        return out.toByteArray()
    }

    private class BitReader(val d: ByteArray) {
        var pos = 0
        fun bit(): Int {
            val b = (d[pos ushr 3].toInt() ushr (7 - (pos and 7))) and 1
            pos++
            return b
        }

        fun u(n: Int): Int {
            var v = 0
            repeat(n) { v = (v shl 1) or bit() }
            return v
        }

        fun ue(): Int {
            var zeros = 0
            while (bit() == 0) zeros++
            var v = 1 shl zeros
            repeat(zeros) { v = v or (bit() shl (it)) }
            return v - 1
        }

        fun se(): Int {
            val k = ue()
            return if (k and 1 == 1) (k + 1) / 2 else -(k / 2)
        }
    }
}

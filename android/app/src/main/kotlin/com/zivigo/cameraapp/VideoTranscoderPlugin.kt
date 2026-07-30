package com.zivigo.cameraapp

import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.round

/// Native AVI (MJPEG) → MP4 (H.264) transcoder — Android equivalent of iOS VideoTranscoder.
///
/// Method channel: "com.cameraapp/video" (same channel name, same API)
///
/// Pipeline:
///   AVI bytes → RIFF parse → per-frame JPEG → BitmapFactory decode →
///   MediaCodec (H.264, hardware) → MediaMuxer (MP4)
class VideoTranscoderPlugin : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "VideoTranscoder"
        private const val CHANNEL = "com.cameraapp/video"

        fun register(activity: MainActivity, engine: io.flutter.embedding.engine.FlutterEngine) {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(VideoTranscoderPlugin())
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "transcodeAviToMp4" -> {
                val inputPath = call.argument<String>("inputPath")
                if (inputPath == null) {
                    result.error("INVALID_ARGS", "Missing inputPath", null)
                    return
                }
                val outputName = call.argument<String>("outputName") ?: "VID_transcoded"
                Thread {
                    try {
                        val out = transcode(inputPath, outputName)
                        result.success(out)
                    } catch (e: TranscodeError) {
                        result.error(e.code, e.message, null)
                    } catch (e: Exception) {
                        Log.e(TAG, "transcode failed", e)
                        result.error("TRANSCODE_FAILED", e.message, null)
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun transcode(inputPath: String, outputName: String): Map<String, Any> {
        val inputBytes = File(inputPath).readBytes()

        // 1. Parse AVI container → JPEG frames + fps
        val parsed = AviParser.parse(inputBytes)
        if (parsed.frames.isEmpty()) {
            throw TranscodeError("NO_FRAMES", "No MJPEG frames found in AVI")
        }

        // 2. Output path
        val outName = outputName.replace(".avi", "")
        val outFile = File.createTempFile("$outName", ".mp4")
        outFile.delete()

        // 3. Decode first frame to get dimensions
        val firstBmp = BitmapFactory.decodeByteArray(parsed.frames[0], 0, parsed.frames[0].size)
            ?: throw TranscodeError("DECODE_FAILED", "Cannot decode first MJPEG frame")
        val width = firstBmp.width
        val height = firstBmp.height
        firstBmp.recycle()

        // 4. Encode H.264 → MP4
        encodeMp4(parsed.frames, width, height, parsed.fps, outFile)

        Log.i(TAG, "Transcoded: ${width}x${height}, ${parsed.frames.size} frames, ${parsed.fps} fps")
        return mapOf(
            "path" to outFile.absolutePath,
            "width" to width,
            "height" to height,
            "frameCount" to parsed.frames.size,
            "fps" to parsed.fps
        )
    }

    /// Encode JPEG frames into H.264 MP4 via MediaCodec + MediaMuxer.
    private fun encodeMp4(
        frames: List<ByteArray>, width: Int, height: Int, fps: Int, outFile: File
    ) {
        val mimeType = MediaFormat.MIMETYPE_VIDEO_AVC
        val format = MediaFormat.createVideoFormat(mimeType, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, maxOf(width * height * fps, 200_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }

        val codec = MediaCodec.createEncoderByType(mimeType)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val muxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val bufferInfo = MediaCodec.BufferInfo()
        var trackIndex = -1
        var muxerStarted = false
        var frameIdx = 0
        val timeoutUs = 10_000L

        try {
            while (true) {
                // Feed input frames
                if (frameIdx < frames.size) {
                    val inputBufIdx = codec.dequeueInputBuffer(timeoutUs)
                    if (inputBufIdx >= 0) {
                        val inputBuf = codec.getInputBuffer(inputBufIdx)!!
                        inputBuf.clear()
                        // Decode JPEG → YUV420 is complex; instead decode to ARGB then
                        // convert to NV12 for the encoder.
                        val bmp = BitmapFactory.decodeByteArray(frames[frameIdx], 0, frames[frameIdx].size)
                        val nv12 = bitmapToNv12(bmp, width, height)
                        bmp.recycle()
                        inputBuf.put(nv12)

                        val pts = (frameIdx * 1_000_000L / fps)
                        val flags = if (frameIdx % fps == 0) {
                            MediaCodec.BUFFER_FLAG_KEY_FRAME
                        } else 0
                        codec.queueInputBuffer(inputBufIdx, 0, nv12.size, pts, flags)
                        frameIdx++
                    }
                }

                // Drain output
                val outBufIdx = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                when {
                    outBufIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = codec.outputFormat
                        trackIndex = muxer.addTrack(newFormat)
                        muxer.start()
                        muxerStarted = true
                        Log.i(TAG, "Muxer started, track=$trackIndex")
                    }
                    outBufIdx >= 0 -> {
                        val outBuf = codec.getOutputBuffer(outBufIdx)!!
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            outBuf.position(bufferInfo.offset)
                            outBuf.limit(bufferInfo.offset + bufferInfo.size)
                            muxer.writeSampleData(trackIndex, outBuf, bufferInfo)
                        }
                        codec.releaseOutputBuffer(outBufIdx, false)
                    }
                }

                // Done condition: all frames fed + output EOS
                if (frameIdx >= frames.size) {
                    val inputBufIdx = codec.dequeueInputBuffer(timeoutUs)
                    if (inputBufIdx >= 0) {
                        codec.queueInputBuffer(inputBufIdx, 0, 0,
                            (frames.size * 1_000_000L / fps),
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    }
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        break
                    }
                }
            }
        } finally {
            if (muxerStarted) {
                muxer.stop()
            }
            muxer.release()
            codec.stop()
            codec.release()
        }
    }

    /// Convert a Bitmap to NV12 (YUV420 semi-planar) byte array for MediaCodec.
    /// MediaCodec's COLOR_FormatYUV420Flexible accepts various layouts; NV12 is
    /// the most widely supported.
    private fun bitmapToNv12(bitmap: android.graphics.Bitmap, width: Int, height: Int): ByteArray {
        val argb = IntArray(width * height)
        bitmap.getPixels(argb, 0, width, 0, 0, width, height)
        val ySize = width * height
        val nv12 = ByteArray(ySize + ySize / 2)

        // Y plane
        var i = 0
        for (row in 0 until height) {
            for (col in 0 until width) {
                val px = argb[row * width + col]
                val r = (px shr 16) and 0xFF
                val g = (px shr 8) and 0xFF
                val b = px and 0xFF
                val y = ((66 * r + 129 * g + 25 * b + 128) shr 8).coerceIn(0, 255)
                nv12[i++] = y.toByte()
            }
        }

        // UV plane (interleaved, half resolution)
        var uvIdx = ySize
        val halfH = height / 2
        val halfW = width / 2
        for (row in 0 until halfH) {
            for (col in 0 until halfW) {
                val px1 = argb[(row * 2) * width + (col * 2)]
                val px2 = argb[(row * 2) * width + (col * 2 + 1)]
                val px3 = argb[(row * 2 + 1) * width + (col * 2)]
                val px4 = argb[(row * 2 + 1) * width + (col * 2 + 1)]
                val r = ((px1 shr 16 and 0xFF) + (px2 shr 16 and 0xFF) +
                        (px3 shr 16 and 0xFF) + (px4 shr 16 and 0xFF)) / 4
                val g = ((px1 shr 8 and 0xFF) + (px2 shr 8 and 0xFF) +
                        (px3 shr 8 and 0xFF) + (px4 shr 8 and 0xFF)) / 4
                val b = ((px1 and 0xFF) + (px2 and 0xFF) +
                        (px3 and 0xFF) + (px4 and 0xFF)) / 4
                val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8).coerceIn(0, 255)
                val v = ((112 * r - 94 * g - 18 * b + 128) shr 8).coerceIn(0, 255)
                nv12[uvIdx++] = v.toByte() // NV12 = Y, then interleaved UV... actually NV12 is UV
                nv12[uvIdx++] = u.toByte()
            }
        }
        return nv12
    }
}

/// Transcode-specific error.
class TranscodeError(val code: String, override val message: String) : Exception(message)

/// Minimal AVI/RIFF parser for MJPEG video.
/// Port of iOS VideoTranscoder.AVIParser.
object AviParser {
    data class Result(val frames: List<ByteArray>, val fps: Int)

    fun parse(data: ByteArray): Result {
        val r = Reader(data)

        // RIFF header
        val riff = r.readFourCC()
        if (riff != "RIFF") {
            throw TranscodeError("NOT_RIFF", "Not a RIFF/AVI file (got '$riff')")
        }
        r.readInt32() // file size, ignore
        val aviType = r.readFourCC()
        if (aviType != "AVI ") {
            throw TranscodeError("NOT_AVI", "RIFF type is not 'AVI ' (got '$aviType')")
        }

        var fps = 15
        val frames = mutableListOf<ByteArray>()

        while (r.remaining > 8) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()

            if (ckID == "LIST") {
                val listType = r.readFourCC()
                val listEnd = r.position + (ckSize - 4)
                when (listType) {
                    "movi" -> {
                        frames.addAll(parseMovi(r, listEnd))
                        r.position = listEnd
                    }
                    "hdrl" -> {
                        val maybeFps = parseHdrl(r, listEnd)
                        if (maybeFps != null) fps = maybeFps
                        r.position = listEnd
                    }
                    else -> r.position = listEnd
                }
            } else {
                r.skip(ckSize)
                if (ckSize % 2 != 0) r.skip(1)
            }
        }
        return Result(frames, fps)
    }

    private fun parseMovi(r: Reader, end: Int): List<ByteArray> {
        val frames = mutableListOf<ByteArray>()
        while (r.position + 8 <= end) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()
            if (r.position + ckSize > end) break

            if (ckID.endsWith("dc") || ckID.endsWith("db")) {
                val frame = r.readData(ckSize)
                if (frame.size > 2 && frame[0] == 0xFF.toByte() && frame[1] == 0xD8.toByte()) {
                    frames.add(frame)
                }
            } else {
                r.skip(ckSize)
            }
            if (ckSize % 2 != 0) r.skip(1)
        }
        return frames
    }

    private fun parseHdrl(r: Reader, end: Int): Int? {
        while (r.position + 8 <= end) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()
            if (r.position + ckSize > end) break

            if (ckID == "avih") {
                val usPerFrame = r.readUInt32()
                r.position = end
                if (usPerFrame > 0) {
                    val fps = round(1_000_000.0 / usPerFrame).toInt()
                    return maxOf(1, minOf(60, fps))
                }
                return null
            } else if (ckID == "LIST") {
                val listType = r.readFourCC()
                val listEnd = r.position + (ckSize - 4)
                r.position = listEnd
                if ((ckSize - 4) % 2 != 0) r.skip(1)
            } else {
                r.skip(ckSize)
                if (ckSize % 2 != 0) r.skip(1)
            }
        }
        r.position = end
        return null
    }
}

/// Binary reader over a ByteArray.
class Reader(private val data: ByteArray) {
    var position: Int = 0
        set(v) { field = v.coerceIn(0, data.size) }

    val remaining: Int get() = data.size - position

    fun readFourCC(): String {
        if (position + 4 > data.size) return "????"
        val s = String(data, position, 4, Charsets.US_ASCII)
        position += 4
        return s
    }

    fun readUInt32(): Long {
        if (position + 4 > data.size) return 0
        var v = 0L
        v = v or (data[position].toLong() and 0xFF)
        v = v or ((data[position + 1].toLong() and 0xFF) shl 8)
        v = v or ((data[position + 2].toLong() and 0xFF) shl 16)
        v = v or ((data[position + 3].toLong() and 0xFF) shl 24)
        position += 4
        return v
    }

    fun readInt32(): Int = readUInt32().toInt()

    fun readData(count: Int): ByteArray {
        val n = minOf(count, data.size - position)
        val d = data.copyOfRange(position, position + n)
        position += n
        return d
    }

    fun skip(n: Int) {
        position += n
    }
}

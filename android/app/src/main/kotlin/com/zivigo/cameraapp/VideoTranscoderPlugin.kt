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

        // 4. Encode H.264 → MP4 (with audio if present)
        encodeMp4(parsed.frames, width, height, parsed.fps, parsed.audio, outFile)

        // Report audio info back to Dart (parity with iOS) for diagnostics.
        val audioInfo = HashMap<String, Any>()
        val audio = parsed.audio
        if (audio == null) {
            audioInfo["hasAudio"] = false
        } else {
            audioInfo["hasAudio"] = true
            audioInfo["formatTag"] = audio.formatTag
            audioInfo["channels"] = audio.channels
            audioInfo["sampleRate"] = audio.sampleRate
            audioInfo["bitsPerSample"] = audio.bitsPerSample
            audioInfo["bytes"] = audio.samples.size
            val codec = when (audio.formatTag) {
                1 -> "PCM"
                2 -> "ADPCM"
                else -> "tag=${audio.formatTag}"
            }
            val written = if (audio.formatTag == 1) " (written to MP4)"
                          else " (skipped — unsupported codec)"
            Log.i(TAG, "Audio: $codec, ch=${audio.channels}, rate=${audio.sampleRate}, "
                    + "bits=${audio.bitsPerSample}, ${audio.samples.size} bytes$written")
        }

        Log.i(TAG, "Transcoded: ${width}x${height}, ${parsed.frames.size} frames, ${parsed.fps} fps")
        val out = HashMap<String, Any>()
        out["path"] = outFile.absolutePath
        out["width"] = width
        out["height"] = height
        out["frameCount"] = parsed.frames.size
        out["fps"] = parsed.fps
        out["audio"] = audioInfo
        return out
    }

    /// Encode JPEG frames into H.264 MP4 via MediaCodec + MediaMuxer.
    /// If the AVI has a PCM (formatTag == 1) audio stream, it is encoded to AAC
    /// (MediaMuxer's MP4 output doesn't support raw PCM tracks) and written as
    /// a second track, sliced to align with each video frame's PTS.
    private fun encodeMp4(
        frames: List<ByteArray>, width: Int, height: Int, fps: Int,
        audio: AviParser.AudioInfo?, outFile: File
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

        // Audio AAC encoder (only set up if there's PCM audio). Non-PCM codecs
        // are skipped (would need a decoder we don't have).
        val aacEncoder: MediaCodec? = if (audio != null && audio.formatTag == 1) {
            createAacEncoder(audio)
        } else null

        // Mutable state carried across the loop.
        val s = EncodeState(
            videoCodec = codec, aacCodec = aacEncoder, muxer = muxer,
            bufferInfo = MediaCodec.BufferInfo(), fps = fps
        )

        try {
            while (true) {
                // Feed input frames
                if (s.frameIdx < frames.size) {
                    val inputBufIdx = codec.dequeueInputBuffer(s.timeoutUs)
                    if (inputBufIdx >= 0) {
                        val inputBuf = codec.getInputBuffer(inputBufIdx)!!
                        inputBuf.clear()
                        val bmp = BitmapFactory.decodeByteArray(
                            frames[s.frameIdx], 0, frames[s.frameIdx].size)
                        val nv12 = bitmapToNv12(bmp, width, height)
                        bmp.recycle()
                        inputBuf.put(nv12)

                        val pts = (s.frameIdx * 1_000_000L / fps)
                        val flags = if (s.frameIdx % fps == 0) {
                            MediaCodec.BUFFER_FLAG_KEY_FRAME
                        } else 0
                        codec.queueInputBuffer(inputBufIdx, 0, nv12.size, pts, flags)

                        if (aacEncoder != null && audio != null) {
                            feedAudioFrame(aacEncoder, audio, s.frameIdx, fps, pts, s)
                        }
                        s.frameIdx++
                    }
                }

                // Drain video output
                drainCodec(codec, s, isVideo = true)

                // Drain AAC audio output (if encoder present).
                if (aacEncoder != null) {
                    drainCodec(aacEncoder, s, isVideo = false)
                }

                // Done: all frames fed + both outputs EOS
                val videoDone = s.videoEos
                val audioDone = (aacEncoder == null) || s.audioEos
                if (s.frameIdx >= frames.size) {
                    val inputBufIdx = codec.dequeueInputBuffer(s.timeoutUs)
                    if (inputBufIdx >= 0 && !s.videoInputEosSent) {
                        codec.queueInputBuffer(inputBufIdx, 0, 0,
                            (frames.size * 1_000_000L / fps),
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        s.videoInputEosSent = true
                    }
                    if (aacEncoder != null && !s.audioInputEosSent) {
                        aacEncoder.signalEndOfInputStream()
                        s.audioInputEosSent = true
                    }
                    if (videoDone && audioDone) break
                }
            }
        } finally {
            if (s.muxerStarted) muxer.stop()
            muxer.release()
            codec.stop()
            codec.release()
            aacEncoder?.stop()
            aacEncoder?.release()
        }
    }

    /// Mutable encode-loop state, passed around instead of instance fields.
    private class EncodeState(
        val videoCodec: MediaCodec,
        val aacCodec: MediaCodec?,
        val muxer: MediaMuxer,
        val bufferInfo: MediaCodec.BufferInfo,
        val fps: Int
    ) {
        val timeoutUs = 10_000L
        var frameIdx = 0
        var videoTrack = -1
        var audioTrack = -1
        var muxerStarted = false
        var videoFormatAdded = false
        var audioFormatAdded = false
        var videoInputEosSent = false
        var audioInputEosSent = false
        var videoEos = false
        var audioEos = false
        var audioOffsetBytes = 0
    }

    /// Drain one MediaCodec's output. Handles format-change (addTrack),
    /// sample data (writeSampleData), and EOS. Starts the muxer once both
    /// video+audio formats are known (or just video if no audio).
    private fun drainCodec(c: MediaCodec, s: EncodeState, isVideo: Boolean) {
        while (true) {
            val idx = c.dequeueOutputBuffer(s.bufferInfo, s.timeoutUs)
            when {
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (isVideo) {
                        s.videoTrack = s.muxer.addTrack(c.outputFormat)
                        s.videoFormatAdded = true
                    } else {
                        s.audioTrack = s.muxer.addTrack(c.outputFormat)
                        s.audioFormatAdded = true
                    }
                    tryStartMuxer(s)
                }
                idx >= 0 -> {
                    if ((s.bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                        && s.muxerStarted) {
                        val buf = c.getOutputBuffer(idx)!!
                        buf.position(s.bufferInfo.offset)
                        buf.limit(s.bufferInfo.offset + s.bufferInfo.size)
                        val track = if (isVideo) s.videoTrack else s.audioTrack
                        if (track >= 0) {
                            s.muxer.writeSampleData(track, buf, s.bufferInfo)
                        }
                    }
                    c.releaseOutputBuffer(idx, false)
                    if (s.bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        if (isVideo) s.videoEos = true else s.audioEos = true
                        return
                    }
                }
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                else -> return
            }
        }
    }

    /// Start the muxer only after all available tracks have been added:
    /// both video+audio formats when audio is present, else video only.
    private fun tryStartMuxer(s: EncodeState) {
        if (s.muxerStarted) return
        val audioReady = (s.aacCodec == null) || s.audioFormatAdded
        if (s.videoFormatAdded && audioReady) {
            s.muxer.start()
            s.muxerStarted = true
            Log.i(TAG, "Muxer started: video=${s.videoTrack} audio=${s.audioTrack}")
        }
    }

    /// Create an AAC LC encoder configured for the AVI's PCM audio.
    private fun createAacEncoder(audio: AviParser.AudioInfo): MediaCodec {
        val fmt = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            audio.sampleRate,
            audio.channels
        ).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            // AAC bitrate: ~96kbps stereo, ~64kbps mono is plenty for voice.
            val kbps = if (audio.channels >= 2) 96_000 else 64_000
            setInteger(MediaFormat.KEY_BIT_RATE, kbps)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()
        return enc
    }

    /// Feed one video-frame's worth of PCM into the AAC encoder. Each video
    /// frame lasts 1/fps seconds; we consume the matching slice of PCM bytes,
    /// aligned to whole sample frames, and tag it with the video PTS so audio
    /// and video stay in sync.
    private fun feedAudioFrame(
        enc: MediaCodec, audio: AviParser.AudioInfo,
        frameIdx: Int, fps: Int, videoPtsUs: Long, s: EncodeState
    ) {
        val bytesPerSample = audio.bitsPerSample / 8
        val bytesPerFrame = bytesPerSample * audio.channels
        if (bytesPerFrame <= 0) return
        val bytesPerVideoFrame =
            (audio.sampleRate.toLong() * bytesPerFrame / fps).toInt()
        if (bytesPerVideoFrame <= 0) return
        val chunkBytes = (bytesPerVideoFrame / bytesPerFrame) * bytesPerFrame
        if (chunkBytes <= 0) return

        val total = audio.samples.size
        if (s.audioOffsetBytes >= total) return
        val take = minOf(chunkBytes, total - s.audioOffsetBytes)
        val aligned = (take / bytesPerFrame) * bytesPerFrame
        if (aligned <= 0) return

        val inIdx = enc.dequeueInputBuffer(s.timeoutUs)
        if (inIdx >= 0) {
            val buf = enc.getInputBuffer(inIdx)!!
            buf.clear()
            buf.put(audio.samples, s.audioOffsetBytes, aligned)
            enc.queueInputBuffer(inIdx, 0, aligned, videoPtsUs, 0)
            s.audioOffsetBytes += aligned
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

/// Minimal AVI/RIFF parser for MJPEG video + PCM audio.
/// Port of iOS VideoTranscoder.AVIParser.
object AviParser {
    data class AudioInfo(
        val formatTag: Int,   // 1 = PCM, 2 = ADPCM, ...
        val channels: Int,    // 1 mono, 2 stereo
        val sampleRate: Int,  // e.g. 48000
        val bitsPerSample: Int, // 8 or 16
        val samples: ByteArray // concatenated raw audio payload from all '01wb' chunks
    )

    data class Result(val frames: List<ByteArray>, val fps: Int, val audio: AudioInfo?)

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
        val audioChunks = mutableListOf<ByteArray>()
        // Audio format discovered in hdrl/strl (stream index 1).
        var audioFmt: AudioFmt? = null

        while (r.remaining > 8) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()

            if (ckID == "LIST") {
                val listType = r.readFourCC()
                val listEnd = r.position + (ckSize - 4)
                when (listType) {
                    "movi" -> {
                        val movi = parseMovi(r, listEnd)
                        frames.addAll(movi.frames)
                        audioChunks.addAll(movi.audio)
                        r.position = listEnd
                    }
                    "hdrl" -> {
                        val hdrl = parseHdrl(r, listEnd)
                        if (hdrl.fps != null) fps = hdrl.fps
                        audioFmt = hdrl.audioFmt
                        r.position = listEnd
                    }
                    else -> r.position = listEnd
                }
            } else {
                r.skip(ckSize)
                if (ckSize % 2 != 0) r.skip(1)
            }
        }

        var audio: AudioInfo? = null
        if (audioFmt != null && audioChunks.isNotEmpty()) {
            val merged = ByteArray(audioChunks.sumOf { it.size })
            var off = 0
            for (c in audioChunks) {
                System.arraycopy(c, 0, merged, off, c.size)
                off += c.size
            }
            audio = AudioInfo(audioFmt.formatTag, audioFmt.channels,
                audioFmt.sampleRate, audioFmt.bitsPerSample, merged)
        }
        return Result(frames, fps, audio)
    }

    private data class AudioFmt(
        val formatTag: Int, val channels: Int,
        val sampleRate: Int, val bitsPerSample: Int
    )

    private data class MoviResult(val frames: List<ByteArray>, val audio: List<ByteArray>)

    private fun parseMovi(r: Reader, end: Int): MoviResult {
        val frames = mutableListOf<ByteArray>()
        val audio = mutableListOf<ByteArray>()
        while (r.position + 8 <= end) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()
            if (r.position + ckSize > end) break

            if (ckID.endsWith("dc") || ckID.endsWith("db")) {
                // Video frame (compressed JPEG).
                val frame = r.readData(ckSize)
                if (frame.size > 2 && frame[0] == 0xFF.toByte() && frame[1] == 0xD8.toByte()) {
                    frames.add(frame)
                }
            } else if (ckID.endsWith("wb")) {
                // Audio (wave) payload — keep raw bytes; format comes from strf.
                audio.add(r.readData(ckSize))
            } else {
                r.skip(ckSize)
            }
            if (ckSize % 2 != 0) r.skip(1)
        }
        return MoviResult(frames, audio)
    }

    private data class HdrlResult(val fps: Int?, val audioFmt: AudioFmt?)

    private fun parseHdrl(r: Reader, end: Int): HdrlResult {
        var fps: Int? = null
        var audioFmt: AudioFmt? = null

        while (r.position + 8 <= end) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()
            if (r.position + ckSize > end) break

            if (ckID == "avih") {
                val usPerFrame = r.readUInt32()
                r.skip(ckSize - 4)
                if (usPerFrame > 0) {
                    fps = maxOf(1, minOf(60, round(1_000_000.0 / usPerFrame).toInt()))
                }
                if (ckSize % 2 != 0) r.skip(1)
            } else if (ckID == "LIST") {
                val listType = r.readFourCC()
                val listEnd = r.position + (ckSize - 4)
                if (listType == "strl") {
                    val strl = parseStrl(r, listEnd)
                    if (strl.isAudio && strl.audioFmt != null) {
                        audioFmt = strl.audioFmt
                    }
                    r.position = listEnd
                } else {
                    r.position = listEnd
                }
                if ((ckSize - 4) % 2 != 0) r.skip(1)
            } else {
                r.skip(ckSize)
                if (ckSize % 2 != 0) r.skip(1)
            }
        }
        r.position = end
        return HdrlResult(fps, audioFmt)
    }

    private data class StrlResult(val isAudio: Boolean, val audioFmt: AudioFmt?)

    /// Parse a single 'strl' (stream header list): determine if it's audio
    /// ('auds') and read the WAVEFORMATEX from 'strf'.
    private fun parseStrl(r: Reader, end: Int): StrlResult {
        var isAudio = false
        var fccType = ""
        var audioFmt: AudioFmt? = null

        while (r.position + 8 <= end) {
            val ckID = r.readFourCC()
            val ckSize = r.readUInt32().toInt()
            if (r.position + ckSize > end) break

            when {
                ckID == "strh" -> {
                    fccType = r.readFourCC() // 'vids' or 'auds'
                    isAudio = (fccType == "auds")
                    r.skip(ckSize - 4)
                }
                ckID == "strf" && isAudio -> {
                    // WAVEFORMATEX: wFormatTag(2), nChannels(2), nSamplesPerSec(4),
                    // nAvgBytesPerSec(4), nBlockAlign(2), wBitsPerSample(2), ...
                    val formatTag = r.readUInt16()
                    val channels = r.readUInt16()
                    val sampleRate = r.readUInt32().toInt()
                    r.readUInt32() // nAvgBytesPerSec
                    r.readUInt16() // nBlockAlign
                    val bitsPerSample = r.readUInt16()
                    audioFmt = AudioFmt(formatTag, channels, sampleRate, bitsPerSample)
                    r.skip(ckSize - 16)
                }
                else -> r.skip(ckSize)
            }
            if (ckSize % 2 != 0) r.skip(1)
        }
        r.position = end
        return StrlResult(isAudio, audioFmt)
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

    fun readUInt16(): Int {
        if (position + 2 > data.size) return 0
        val v = (data[position].toInt() and 0xFF) or
                ((data[position + 1].toInt() and 0xFF) shl 8)
        position += 2
        return v
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

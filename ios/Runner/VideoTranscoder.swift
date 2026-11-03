import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics
import ImageIO
import Flutter

/// Native AVI (MJPEG) → MP4 (H.264) transcoder.
///
/// iOS cannot open AVI containers via AVFoundation, so we parse the RIFF
/// structure ourselves, extract each MJPEG frame (each frame is an
/// independent JPEG), decode it, then feed the decoded frames into a
/// VideoToolbox H.264 hardware encoder and write an MP4 container via
/// AVAssetWriter.
///
/// Pipeline:
///   AVI bytes → RIFF parse → per-frame JPEG → CGImage decode →
///   CVPixelBuffer (BGRA) → VTCompressionSession (H.264, hw) →
///   AVAssetWriter (MP4)
///
/// Communicates with Flutter via MethodChannel "com.cameraapp/video".
@objc(VideoTranscoderPlugin)
public class VideoTranscoderPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: any FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.cameraapp/video",
            binaryMessenger: registrar.messenger()
        )
        let instance = VideoTranscoderPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "transcodeAviToMp4":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing inputPath", details: nil))
                return
            }
            let outputName = args["outputName"] as? String
            transcode(inputPath: inputPath, outputName: outputName, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Entry point

    private func transcode(inputPath: String,
                           outputName: String?,
                           result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let inputURL = URL(fileURLWithPath: inputPath)
                let input = try Data(contentsOf: inputURL, options: [.mappedIfSafe])

                // 1. Parse AVI container → list of JPEG frames + fps
                let parsed = try AVIParser.parse(data: input)
                guard !parsed.frames.isEmpty else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "NO_FRAMES",
                                            message: "No MJPEG frames found in AVI", details: nil))
                    }
                    return
                }

                // 2. Determine output path
                let outName = (outputName ?? "VID_transcoded")
                    .replacingOccurrences(of: ".avi", with: "")
                let outDir = FileManager.default.temporaryDirectory
                let outURL = outDir.appendingPathComponent("\(outName).mp4")
                try? FileManager.default.removeItem(at: outURL)

                // 3. Decode first frame to learn dimensions
                guard let firstCG = CGImageDecode.decode(jpeg: parsed.frames[0]) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DECODE_FAILED",
                                            message: "Cannot decode first MJPEG frame", details: nil))
                    }
                    return
                }
                let width = firstCG.width
                let height = firstCG.height

                // 4. Encode
                let encoder = H264Encoder(width: width, height: height, fps: parsed.fps)
                try encoder.writeMP4(frames: parsed.frames, audio: parsed.audio, to: outURL)

                // Report audio info back to Dart for logging/diagnostics.
                var audioInfo: [String: Any] = ["hasAudio": parsed.audio != nil]
                if let a = parsed.audio {
                    audioInfo["formatTag"] = Int(a.formatTag)
                    audioInfo["channels"] = Int(a.channels)
                    audioInfo["sampleRate"] = Int(a.sampleRate)
                    audioInfo["bitsPerSample"] = Int(a.bitsPerSample)
                    audioInfo["bytes"] = a.samples.count
                }

                DispatchQueue.main.async {
                    result([
                        "path": outURL.path,
                        "width": width,
                        "height": height,
                        "frameCount": parsed.frames.count,
                        "fps": parsed.fps,
                        "audio": audioInfo,
                    ] as [String: Any])
                }
            } catch let e as TranscodeError {
                DispatchQueue.main.async {
                    result(FlutterError(code: e.code, message: e.message, details: nil))
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "TRANSCODE_FAILED",
                                        message: error.localizedDescription, details: nil))
                }
            }
        }
    }
}

// MARK: - Errors

struct TranscodeError: Error {
    let code: String
    let message: String
}

// MARK: - AVI (RIFF) Parser

/// Minimal AVI/RIFF parser for MJPEG video.
///
/// AVI is a RIFF container. For MJPEG video the structure is:
///   RIFF('AVI ')
///     LIST('hdrl')  → avih (MainHeader: dwMicroSecPerFrame, frame count...)
///       LIST('strl') → strh (StreamHeader: fccType='vids', fccHandler='MJPG')
///                      strf (BitMapInfo: biWidth, biHeight)
///     LIST('movi')
///       '00dc' chunk → JPEG frame #1
///       '00dc' chunk → JPEG frame #2
///       ...
///     idx1 (optional index)
///
/// We only need: fps (from MainHeader) and the '00dc' frames.
struct AVIParser {
    /// Parsed audio stream info (if the AVI has one).
    struct AudioInfo {
        let formatTag: UInt16   // 1 = PCM, 2 = ADPCM, ...
        let channels: UInt16    // 1 mono, 2 stereo
        let sampleRate: UInt32  // e.g. 8000, 11025, 22050, 44100
        let bitsPerSample: UInt16 // 8 or 16
        /// Concatenated raw audio payload bytes from all '01wb' chunks.
        let samples: Data
    }

    struct Result {
        let frames: [Data]   // raw JPEG bytes per frame
        let fps: Int
        let audio: AudioInfo?
    }

    static func parse(data: Data) throws -> Result {
        var r = Reader(data: data)

        // RIFF header
        let riff = r.readFourCC()
        guard riff == "RIFF" else {
            throw TranscodeError(code: "NOT_RIFF", message: "Not a RIFF/AVI file (got '\(riff)')")
        }
        _ = r.readInt32() // file size, ignore
        let aviType = r.readFourCC()
        guard aviType == "AVI " else {
            throw TranscodeError(code: "NOT_AVI", message: "RIFF type is not 'AVI ' (got '\(aviType)')")
        }

        var fps: Int = 15 // default fallback (camera preview is ~15fps)
        var frames: [Data] = []
        var audioChunks: [Data] = []
        // Audio format discovered in hdrl/strl (stream index 1).
        var audioFmt: (formatTag: UInt16, channels: UInt16,
                       sampleRate: UInt32, bitsPerSample: UInt16)?

        // Walk the top-level chunks.
        while r.remaining > 8 {
            let ckID = r.readFourCC()
            let ckSize = Int(r.readUInt32())

            if ckID == "LIST" {
                let listType = r.readFourCC()
                let listEnd = r.position + (ckSize - 4)
                if listType == "movi" {
                    // Parse frames + audio inside movi until listEnd.
                    let movi = parseMovi(reader: &r, end: listEnd)
                    frames.append(contentsOf: movi.frames)
                    audioChunks.append(contentsOf: movi.audio)
                    r.position = listEnd
                } else if listType == "hdrl" {
                    // Scan for avih (fps) and the audio stream's strf.
                    let hdrl = parseHdrl(reader: &r, end: listEnd)
                    if let f = hdrl.fps { fps = f }
                    audioFmt = hdrl.audioFmt
                    r.position = listEnd
                } else {
                    // Skip unknown LIST contents.
                    r.position = listEnd
                }
                // RIFF chunks are word-aligned (even size); listEnd is already
                // aligned because we compute it from ckSize (payload only).
                // But LIST payload includes the 4-byte type we consumed; ckSize
                // counted it, so listEnd is correct.
            } else {
                // Plain chunk — skip payload.
                r.skip(ckSize)
                if ckSize % 2 != 0 { r.skip(1) } // word alignment
            }
        }

        var audio: AudioInfo?
        if let fmt = audioFmt, !audioChunks.isEmpty {
            audio = AudioInfo(
                formatTag: fmt.formatTag,
                channels: fmt.channels,
                sampleRate: fmt.sampleRate,
                bitsPerSample: fmt.bitsPerSample,
                samples: audioChunks.reduce(into: Data()) { $0.append($1) }
            )
        }

        return Result(frames: frames, fps: fps, audio: audio)
    }

    /// Parse 'movi' LIST body: collect '00dc'/'00db' video frames and '01wb'
    /// audio chunks. Stream index is the first char: '0' = video stream,
    /// '1' = audio stream; suffix 'dc'/'db' = video, 'wb' = wave audio.
    private static func parseMovi(reader: inout Reader, end: Int) -> (frames: [Data], audio: [Data]) {
        var frames: [Data] = []
        var audio: [Data] = []
        while reader.position + 8 <= end {
            let ckID = reader.readFourCC()
            let ckSize = Int(reader.readUInt32())
            if reader.position + ckSize > end { break }

            if ckID.hasSuffix("dc") || ckID.hasSuffix("db") {
                // Video frame (compressed JPEG).
                let frame = reader.readData(count: ckSize)
                if frame.count > 2 && frame[0] == 0xFF && frame[1] == 0xD8 {
                    frames.append(frame)
                }
            } else if ckID.hasSuffix("wb") {
                // Audio (wave) payload — keep raw bytes; format comes from strf.
                audio.append(reader.readData(count: ckSize))
            } else {
                reader.skip(ckSize)
            }
            if ckSize % 2 != 0 { reader.skip(1) }
        }
        return (frames, audio)
    }

    /// Parse 'hdrl' LIST: find avih (fps) and the audio stream's strf
    /// (WAVEFORMATEX). We scan each 'strl' sub-list; the first stream whose
    /// strh fccType is 'auds' is treated as the audio stream.
    private static func parseHdrl(reader: inout Reader, end: Int)
        -> (fps: Int?, audioFmt: (formatTag: UInt16, channels: UInt16,
                                  sampleRate: UInt32, bitsPerSample: UInt16)?) {
        var fps: Int?
        var audioFmt: (formatTag: UInt16, channels: UInt16,
                       sampleRate: UInt32, bitsPerSample: UInt16)?

        while reader.position + 8 <= end {
            let ckID = reader.readFourCC()
            let ckSize = Int(reader.readUInt32())
            if reader.position + ckSize > end { break }

            if ckID == "avih" {
                // avih: dwMicroSecPerFrame (offset 0), ...
                let usPerFrame = reader.readUInt32()
                if usPerFrame > 0 {
                    fps = max(1, min(60, Int(round(1_000_000.0 / Double(usPerFrame)))))
                }
                reader.skip(ckSize - 4)
                if ckSize % 2 != 0 { reader.skip(1) }
            } else if ckID == "LIST" {
                let listType = reader.readFourCC()
                let listEnd = reader.position + (ckSize - 4)
                if listType == "strl" {
                    // Scan this stream list for strh (type) + strf (format).
                    let strl = parseStrl(reader: &reader, end: listEnd)
                    if strl.isAudio, let f = strl.audioFmt {
                        audioFmt = f
                    }
                    reader.position = listEnd
                } else {
                    reader.position = listEnd
                }
                if (ckSize - 4) % 2 != 0 { reader.skip(1) }
            } else {
                reader.skip(ckSize)
                if ckSize % 2 != 0 { reader.skip(1) }
            }
        }
        reader.position = end
        return (fps, audioFmt)
    }

    /// Parse a single 'strl' (stream header list): determine if it's audio
    /// ('auds') and read the WAVEFORMATEX from 'strf'.
    private static func parseStrl(reader: inout Reader, end: Int)
        -> (isAudio: Bool,
            audioFmt: (formatTag: UInt16, channels: UInt16,
                       sampleRate: UInt32, bitsPerSample: UInt16)?) {
        var isAudio = false
        var fccType = ""
        var audioFmt: (formatTag: UInt16, channels: UInt16,
                       sampleRate: UInt32, bitsPerSample: UInt16)?

        while reader.position + 8 <= end {
            let ckID = reader.readFourCC()
            let ckSize = Int(reader.readUInt32())
            if reader.position + ckSize > end { break }

            if ckID == "strh" {
                fccType = reader.readFourCC() // 'vids' or 'auds'
                isAudio = (fccType == "auds")
                reader.skip(ckSize - 4)
            } else if ckID == "strf" && isAudio {
                // WAVEFORMATEX: wFormatTag(2), nChannels(2), nSamplesPerSec(4),
                // nAvgBytesPerSec(4), nBlockAlign(2), wBitsPerSample(2), ...
                let formatTag = reader.readUInt16()
                let channels = reader.readUInt16()
                let sampleRate = reader.readUInt32()
                _ = reader.readUInt32() // nAvgBytesPerSec
                _ = reader.readUInt16() // nBlockAlign
                let bitsPerSample = reader.readUInt16()
                audioFmt = (formatTag, channels, sampleRate, bitsPerSample)
                reader.skip(ckSize - 16)
            } else {
                reader.skip(ckSize)
            }
            if ckSize % 2 != 0 { reader.skip(1) }
        }
        reader.position = end
        return (isAudio, audioFmt)
    }
}

// MARK: - Binary Reader

struct Reader {
    let data: Data
    var position: Int

    init(data: Data) {
        self.data = data
        self.position = 0
    }

    var remaining: Int { data.count - position }

    mutating func readFourCC() -> String {
        guard position + 4 <= data.count else { return "????" }
        let bytes = [UInt8](data[position..<position+4])
        position += 4
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    mutating func readUInt16() -> UInt16 {
        guard position + 2 <= data.count else { return 0 }
        let v = data.subdata(in: position..<position+2).withUnsafeBytes { $0.load(as: UInt16.self) }
        position += 2
        return v
    }

    mutating func readUInt32() -> UInt32 {
        guard position + 4 <= data.count else { return 0 }
        let v = data.subdata(in: position..<position+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        position += 4
        return v
    }

    mutating func readInt32() -> Int32 {
        return Int32(bitPattern: readUInt32())
    }

    mutating func readData(count: Int) -> Data {
        let n = min(count, data.count - position)
        let d = data.subdata(in: position..<position+n)
        position += n
        return d
    }

    mutating func skip(_ n: Int) {
        position += n
    }
}

// MARK: - JPEG → CGImage decode

enum CGImageDecode {
    /// Decode a JPEG frame to CGImage. Each MJPEG frame is an independent JPEG.
    static func decode(jpeg: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - H.264 Encoder (VideoToolbox) + MP4 Writer

final class H264Encoder {
    let width: Int
    let height: Int
    let fps: Int

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// Decode each JPEG to CGImage → CVPixelBuffer, encode with VideoToolbox,
    /// and write an MP4 container. If the AVI has a PCM audio stream, an audio
    /// track is written alongside the video so the output has sound.
    func writeMP4(frames: [Data], audio: AVIParser.AudioInfo?, to outURL: URL) throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        } catch {
            throw TranscodeError(code: "WRITER_INIT",
                                 message: "Cannot init AVAssetWriter: \(error.localizedDescription)")
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAverageBitRateKey: max(width * height * fps, 200_000),
                AVVideoMaxKeyFrameIntervalKey: fps, // keyframe every ~1s
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw TranscodeError(code: "WRITER_INPUT", message: "Cannot add video input")
        }
        writer.add(input)

        // BGRA adaptor — VideoToolbox under AVAssetWriter prefers BGRA.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        // Audio: if the AVI has a PCM (formatTag == 1) audio stream, write it
        // alongside the video so the output MP4 has sound. Confirmed format from
        // device logs: PCM, 2ch, 48kHz, 16-bit. Non-PCM codecs (ADPCM etc.) are
        // not written — they'd need a decoder we don't have.
        let audioInput: AVAssetWriterInput? = {
            guard let a = audio, a.formatTag == 1 else {
                if let a = audio {
                    NSLog("[VideoTranscoder] audio codec not written (unsupported): "
                          + "tag=\(a.formatTag) ch=\(a.channels) rate=\(a.sampleRate) "
                          + "bits=\(a.bitsPerSample) bytes=\(a.samples.count)")
                }
                return nil
            }
            let layout = Self.makeAudioChannelLayout(channels: a.channels)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: a.sampleRate,
                AVNumberOfChannelsKey: a.channels,
                AVLinearPCMBitDepthKey: a.bitsPerSample,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVChannelLayoutKey: layout as Any,
            ]
            let in_ = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            in_.expectsMediaDataInRealTime = false
            guard writer.canAdd(in_) else {
                NSLog("[VideoTranscoder] cannot add audio input (settings rejected)")
                return nil
            }
            writer.add(in_)
            return in_
        }()

        guard writer.startWriting() else {
            throw TranscodeError(code: "WRITER_START",
                                 message: "AVAssetWriter startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale = CMTimeScale(fps)

        // Drive the encoder on a background serial queue. We poll
        // isReadyForMoreMediaData and append frames one at a time;
        // when all frames are done, mark the input finished and
        // finishWriting on the writer.
        let encodingQueue = DispatchQueue(label: "com.cameraapp.encode", qos: .userInitiated)
        let doneSemaphore = DispatchSemaphore(value: 0)

        encodingQueue.async { [weak self] in
            guard let self = self else {
                input.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { doneSemaphore.signal() }
                return
            }

            // ── Video frames ──
            for (idx, frame) in frames.enumerated() {
                // Backpressure: wait until the writer pipeline can accept more.
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                    if writer.status == .failed { break }
                }
                if writer.status == .failed { break }

                guard let cg = CGImageDecode.decode(jpeg: frame),
                      let px = self.makePixelBuffer(from: cg) else {
                    continue // skip undecodable frame, keep PTS monotonic
                }
                let pts = CMTime(value: CMTimeValue(idx), timescale: timescale)
                adaptor.append(px, withPresentationTime: pts)
            }

            // ── Audio ──
            // Slice the PCM byte stream into per-frame chunks whose duration
            // matches each video frame (1/fps s), and append them with PTS
            // aligned to the video timescale. This keeps audio/video in sync
            // without needing a separate audio clock.
            if let a = audio, audioInput != nil {
                self.appendAudio(audio: a,
                                 frameCount: frames.count,
                                 fps: fps,
                                 audioInput: audioInput!,
                                 timescale: timescale)
            }

            input.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { doneSemaphore.signal() }
        }

        doneSemaphore.wait()

        if writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? "unknown"
            throw TranscodeError(code: "WRITER_FAILED", message: "MP4 write failed: \(msg)")
        }
    }

    /// Append the AVI's PCM audio into the MP4, sliced to match each video
    /// frame's duration. Each chunk's PTS advances by one frame interval so
    /// audio stays aligned with video.
    private func appendAudio(audio: AVIParser.AudioInfo,
                             frameCount: Int,
                             fps: Int,
                             audioInput: AVAssetWriterInput,
                             timescale: CMTimeScale) {
        guard fps > 0 else { return }
        let bytesPerSample = Int(audio.bitsPerSample) / 8
        let bytesPerFrame = bytesPerSample * Int(audio.channels)
        guard bytesPerFrame > 0 else { return }

        // Bytes of audio that play during one video frame (1/fps seconds).
        let bytesPerVideoFrame = Int(Double(audio.sampleRate) * Double(bytesPerFrame) / Double(fps))
        guard bytesPerVideoFrame > 0 else { return }

        // Round to a whole sample frame so we never split an interleaved sample.
        let chunkBytes = (bytesPerVideoFrame / bytesPerFrame) * bytesPerFrame
        guard chunkBytes > 0 else { return }

        let total = audio.samples.count
        var offset = 0
        var frameIdx = 0
        while offset < total {
            while !audioInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let take = min(chunkBytes, total - offset)
            // The last chunk may not be a full sample frame; only append whole
            // frames to keep the PCM stream valid.
            let aligned = (take / bytesPerFrame) * bytesPerFrame
            guard aligned > 0 else { break }
            let chunk = audio.samples.subdata(in: offset..<offset + aligned)
            let numSamples = aligned / bytesPerFrame
            let cmBlockBuf = Self.makeBlockBuffer(from: chunk)
            let pts = CMTime(value: CMTimeValue(frameIdx), timescale: timescale)
            let duration = CMTime(value: CMTimeValue(1), timescale: timescale)
            if let cmBlockBuf = cmBlockBuf,
               let sampleBuf = Self.makeSampleBuffer(blockBuffer: cmBlockBuf,
                                                     sampleRate: audio.sampleRate,
                                                     channels: audio.channels,
                                                     bitsPerSample: audio.bitsPerSample,
                                                     numSamples: numSamples,
                                                     pts: pts,
                                                     duration: duration) {
                _ = audioInput.append(sampleBuf)
            }
            offset += aligned
            frameIdx += 1
            if frameIdx >= frameCount { break }
        }
    }

    /// Build an AudioChannelLayout for the given channel count (mono/stereo).
    static func makeAudioChannelLayout(channels: UInt16) -> NSData {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = (channels >= 2)
            ? kAudioChannelLayoutTag_Stereo
            : kAudioChannelLayoutTag_Mono
        layout.mNumberChannelDescriptions = 0
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size) as NSData
    }

    /// Wrap raw PCM bytes in a CMBlockBuffer. Bytes are copied in (the source
    /// Data is short-lived), so no custom block source / refcon is needed.
    static func makeBlockBuffer(from data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let totalLength = data.count
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }
        let copied = data.withUnsafeBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                  blockBuffer: bb,
                                                  offsetIntoDestination: 0,
                                                  dataLength: totalLength)
        }
        return copied == kCMBlockBufferNoErr ? bb : nil
    }

    /// Build a CMSampleBuffer wrapping [numSamples] PCM frames with the given
    /// PTS. For uncompressed PCM every frame has the same size; we pass a single
    /// sample-size entry and numSampleSizeEntries == 1 to signal a constant size.
    static func makeSampleBuffer(blockBuffer: CMBlockBuffer,
                                 sampleRate: UInt32,
                                 channels: UInt16,
                                 bitsPerSample: UInt16,
                                 numSamples: Int,
                                 pts: CMTime,
                                 duration: CMTime) -> CMSampleBuffer? {
        var asbd = Self.makeASBD(sampleRate: sampleRate,
                                 channels: channels,
                                 bitsPerSample: bitsPerSample)
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       asbd: &asbd,
                                       layoutSize: 0,
                                       layout: nil,
                                       magicCookieSize: 0,
                                       magicCookie: nil,
                                       extensions: nil,
                                       formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return nil }

        // For uncompressed PCM every sample has the same size (one frame).
        let bytesPerFrame = Int(bitsPerSample) / 8 * Int(channels)
        var sampleSize = bytesPerFrame   // CMSampleBuffer sampleSizeArray is Int
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fd,
            sampleCount: numSamples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,   // constant size → one entry
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else {
            NSLog("[VideoTranscoder] CMSampleBufferCreateReady failed: \(status)")
            return nil
        }
        return sampleBuffer
    }

    /// AudioStreamBasicDescription for interleaved 16-bit PCM.
    static func makeASBD(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(bitsPerSample) * UInt32(channels) / 8
        return AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bitsPerSample),
            mReserved: 0)
    }

    /// Render a CGImage into a 32BGRA CVPixelBuffer matching the encoder size.
    private func makePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        var px: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        width, height,
                                        kCVPixelFormatType_32BGRA,
                                        attrs as CFDictionary,
                                        &px)
        guard status == kCVReturnSuccess, let buffer = px else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Flip Y: CGContext origin is bottom-left, image origin top-left.
        ctx.interpolationQuality = .medium
        // The sensor is mounted mirrored and firmware cannot correct it, so every
        // frame is mirrored here. Doing it in the bitmap context we already have
        // costs almost nothing, and the saved MP4 is then correct everywhere
        // (Photos, QuickTime, share sheet) without relying on a track matrix that
        // some players ignore.
        ctx.translateBy(x: CGFloat(width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

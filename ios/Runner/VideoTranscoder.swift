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
                try encoder.writeMP4(frames: parsed.frames, to: outURL)

                DispatchQueue.main.async {
                    result([
                        "path": outURL.path,
                        "width": width,
                        "height": height,
                        "frameCount": parsed.frames.count,
                        "fps": parsed.fps,
                    ])
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
    struct Result {
        let frames: [Data]   // raw JPEG bytes per frame
        let fps: Int
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

        // Walk the top-level chunks.
        while r.remaining > 8 {
            let ckID = r.readFourCC()
            let ckSize = Int(r.readUInt32())

            if ckID == "LIST" {
                let listType = r.readFourCC()
                let listEnd = r.position + (ckSize - 4)
                if listType == "movi" {
                    // Parse frames inside movi until listEnd.
                    frames.append(contentsOf: parseMovi(reader: &r, end: listEnd))
                    r.position = listEnd
                } else if listType == "hdrl" {
                    // Scan for the avih chunk to read fps.
                    let maybeFps = parseHdrl(reader: &r, end: listEnd)
                    if let f = maybeFps { fps = f }
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

        return Result(frames: frames, fps: fps)
    }

    /// Parse 'movi' LIST body: collect all '00dc' (compressed video) chunks.
    private static func parseMovi(reader: inout Reader, end: Int) -> [Data] {
        var frames: [Data] = []
        while reader.position + 8 <= end {
            let ckID = reader.readFourCC()
            let ckSize = Int(reader.readUInt32())
            if reader.position + ckSize > end { break }

            // '00dc' / '00db' = video stream 0, compressed/uncompressed.
            // Also accept any '??dc' to be lenient.
            if ckID.hasSuffix("dc") || ckID.hasSuffix("db") {
                let frame = reader.readData(count: ckSize)
                if frame.count > 2 && frame[0] == 0xFF && frame[1] == 0xD8 {
                    // Valid JPEG (SOI marker)
                    frames.append(frame)
                }
            } else {
                reader.skip(ckSize)
            }
            if ckSize % 2 != 0 { reader.skip(1) }
        }
        return frames
    }

    /// Parse 'hdrl' LIST to find avih (Main AVI Header) and read fps.
    /// dwMicroSecPerFrame is the 4th DWORD in the avih chunk.
    private static func parseHdrl(reader: inout Reader, end: Int) -> Int? {
        while reader.position + 8 <= end {
            let ckID = reader.readFourCC()
            let ckSize = Int(reader.readUInt32())
            if reader.position + ckSize > end { break }

            if ckID == "avih" {
                // avih: dwMicroSecPerFrame (offset 0, 4 bytes), dwMaxBytesPerSec,
                // dwPadding, dwFlags, dwTotalFrames, ...
                let usPerFrame = reader.readUInt32()
                reader.position = end
                if usPerFrame > 0 {
                    let fps = Int(round(1_000_000.0 / Double(usPerFrame)))
                    return max(1, min(60, fps)) // sanity clamp
                }
                return nil
            } else if ckID == "LIST" {
                let listType = reader.readFourCC()
                let listEnd = reader.position + (ckSize - 4)
                // Recurse into strl but we don't need anything from it for fps.
                reader.position = listEnd
                if (ckSize - 4) % 2 != 0 { reader.skip(1) }
            } else {
                reader.skip(ckSize)
                if ckSize % 2 != 0 { reader.skip(1) }
            }
        }
        reader.position = end
        return nil
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
    /// and write an MP4 container.
    func writeMP4(frames: [Data], to outURL: URL) throws {
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
                writer.finishWriting { doneSemaphore.signal() }
                return
            }

            for (idx, frame) in frames.enumerated() {
                // Backpressure: wait until the writer pipeline can accept more.
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                    // If the writer failed mid-flight, bail out.
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

            input.markAsFinished()
            writer.finishWriting { doneSemaphore.signal() }
        }

        doneSemaphore.wait()

        if writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? "unknown"
            throw TranscodeError(code: "WRITER_FAILED", message: "MP4 write failed: \(msg)")
        }
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
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

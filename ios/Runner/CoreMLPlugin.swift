import Foundation
import CoreML
import Vision
import UIKit
import Flutter

/// Native iOS plugin for CoreML neural filter inference.
///
/// Communicates with Flutter via MethodChannel "com.cameraapp/coreml".
/// Handles tile-based image processing to support any input resolution
/// with a fixed model input size.
@objc(CoreMLPlugin)
public class CoreMLPlugin: NSObject, FlutterPlugin {

    // Cache loaded models for performance
    private var modelCache: [String: MLModel] = [:]
    private let modelQueue = DispatchQueue(label: "com.cameraapp.coreml", qos: .userInitiated)

    // MARK: - FlutterPlugin Registration

    public static func register(with registrar: any FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.cameraapp/coreml",
            binaryMessenger: registrar.messenger()
        )
        let instance = CoreMLPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)

        case "loadModel":
            guard let args = call.arguments as? [String: Any],
                  let modelName = args["modelName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelName", details: nil))
                return
            }
            do {
                let _ = try loadModel(named: modelName)
                result(true)
            } catch {
                result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
            }

        case "applyFilter":
            guard let args = call.arguments as? [String: Any],
                  let imageData = args["imageBytes"] as? FlutterStandardTypedData,
                  let modelName = args["modelName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing imageBytes or modelName", details: nil))
                return
            }
            let patchSize = args["patchSize"] as? Int ?? 448
            let padding = args["padding"] as? Int ?? 16
            applyFilterSync(imageData: imageData.data, modelName: modelName, patchSize: patchSize, padding: padding, flutterResult: result)

        case "applyFilterPreview":
            guard let args = call.arguments as? [String: Any],
                  let imageData = args["imageBytes"] as? FlutterStandardTypedData,
                  let modelName = args["modelName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing imageBytes or modelName", details: nil))
                return
            }
            let maxDimension = args["maxDimension"] as? Int ?? 1024
            applyFilterPreviewSync(imageData: imageData.data, modelName: modelName, maxDimension: maxDimension, flutterResult: result)

        case "upscalePhoto":
            guard let args = call.arguments as? [String: Any],
                  let imageData = args["imageBytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing imageBytes", details: nil))
                return
            }
            upscalePhotoSync(imageData: imageData.data, flutterResult: result)

        case "clearCache":
            modelCache.removeAll()
            result(nil)

        case "availableModels":
            // Return list of bundled model names from Flutter assets
            let candidates = [
                Bundle.main.resourceURL?.appendingPathComponent("Frameworks/App.framework/flutter_assets/assets/models"),
                Bundle.main.resourceURL?.appendingPathComponent("flutter_assets/assets/models"),
                Bundle.main.resourceURL,
            ].compactMap { $0 }

            let fileManager = FileManager.default
            var models: [String] = []
            for dir in candidates {
                guard fileManager.fileExists(atPath: dir.path) else { continue }
                do {
                    let files = try fileManager.contentsOfDirectory(atPath: dir.path)
                    let found = files
                        .filter { $0.hasSuffix(".mlmodel") || $0.hasSuffix(".mlmodelc") }
                        .map { $0.replacingOccurrences(of: ".mlmodelc", with: "").replacingOccurrences(of: ".mlmodel", with: "") }
                    models.append(contentsOf: found)
                } catch { }
            }
            result(Array(Set(models)).sorted())

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Synchronous wrappers (async → FlutterResult)

    private func applyFilterSync(imageData: Data, modelName: String, patchSize: Int, padding: Int, flutterResult: @escaping FlutterResult) {
        applyFilter(imageData: imageData, modelName: modelName, patchSize: patchSize, padding: padding) { filteredData, error in
            if let error = error {
                flutterResult(FlutterError(code: "INFERENCE_FAILED", message: error.localizedDescription, details: nil))
            } else if let filteredData = filteredData {
                flutterResult(FlutterStandardTypedData(bytes: filteredData))
            } else {
                flutterResult(FlutterError(code: "NO_RESULT", message: "No output from inference", details: nil))
            }
        }
    }

    private func applyFilterPreviewSync(imageData: Data, modelName: String, maxDimension: Int, flutterResult: @escaping FlutterResult) {
        // Downsample for fast preview, then run full inference
        guard let image = UIImage(data: imageData) else {
            flutterResult(FlutterError(code: "DECODE_FAILED", message: "Cannot decode image", details: nil))
            return
        }

        // Downsample to maxDimension
        let size = image.size
        let scale = min(CGFloat(maxDimension) / size.width, CGFloat(maxDimension) / size.height)
        guard scale < 1.0 else {
            // Image is already small enough — run full resolution
            applyFilterSync(imageData: imageData, modelName: modelName, patchSize: 448, padding: 16, flutterResult: flutterResult)
            return
        }
        let newWidth = Int(size.width * scale)
        let newHeight = Int(size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newWidth, height: newHeight))
        let resized = renderer.image { ctx in
            image.draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        }
        guard let resizedData = resized.jpegData(compressionQuality: 0.85) else {
            flutterResult(FlutterError(code: "PREPROCESS_FAILED", message: "Cannot resize image", details: nil))
            return
        }
        applyFilterSync(imageData: resizedData, modelName: modelName, patchSize: 448, padding: 16, flutterResult: flutterResult)
    }

    private func upscalePhotoSync(imageData: Data, flutterResult: @escaping FlutterResult) {
        upscalePhoto(imageData: imageData) { upscaledData, error in
            if let error = error {
                flutterResult(FlutterError(code: "UPSCALE_FAILED", message: error.localizedDescription, details: nil))
            } else if let upscaledData = upscaledData {
                flutterResult(FlutterStandardTypedData(bytes: upscaledData))
            } else {
                flutterResult(FlutterError(code: "NO_RESULT", message: "No output from upscale", details: nil))
            }
        }
    }

    // MARK: - Model Loading

    /// Load a CoreML model from the app bundle.
    func loadModel(named modelName: String) throws -> MLModel {
        // Check cache first
        if let cached = modelCache[modelName] {
            return cached
        }

        NSLog("[CoreML] loadModel: looking for \(modelName)")

        // Try loading from app bundle (native resources)
        // First try .mlmodelc (compiled), then .mlmodel (uncompiled)
        var modelURL: URL?
        var needsCompile = false

        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            modelURL = url
        } else if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodel") {
            modelURL = url
            needsCompile = true
        } else {
            // Fallback: try Flutter assets path. In release builds Flutter assets live
            // inside App.framework; in some configurations they may be directly under
            // the main bundle.
            let flutterAssetsSubdirs = [
                "Frameworks/App.framework/flutter_assets/assets/models",
                "flutter_assets/assets/models",
            ]
            var foundURL: URL?
            var foundNeedsCompile = false
            for subdir in flutterAssetsSubdirs {
                if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: subdir) {
                    foundURL = url
                    foundNeedsCompile = false
                    break
                }
                if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodel", subdirectory: subdir) {
                    foundURL = url
                    foundNeedsCompile = true
                    break
                }
            }
            if foundURL == nil {
                // Last resort: enumerate the assets directory and look for the file.
                let candidates = [
                    Bundle.main.resourceURL?.appendingPathComponent("Frameworks/App.framework/flutter_assets/assets/models"),
                    Bundle.main.resourceURL?.appendingPathComponent("flutter_assets/assets/models"),
                ].compactMap { $0 }
                for dir in candidates {
                    let mlmodelc = dir.appendingPathComponent("\(modelName).mlmodelc")
                    let mlmodel = dir.appendingPathComponent("\(modelName).mlmodel")
                    if FileManager.default.fileExists(atPath: mlmodelc.path) {
                        foundURL = mlmodelc
                        foundNeedsCompile = false
                        break
                    } else if FileManager.default.fileExists(atPath: mlmodel.path) {
                        foundURL = mlmodel
                        foundNeedsCompile = true
                        break
                    }
                }
            }
            if let found = foundURL {
                modelURL = found
                needsCompile = foundNeedsCompile
            } else {
                NSLog("[CoreML] loadModel: model NOT FOUND: \(modelName)")
                throw CoreMLError.modelNotFound(modelName)
            }
        }

        guard let sourceURL = modelURL else {
            throw CoreMLError.modelNotFound(modelName)
        }

        NSLog("[CoreML] loadModel: found \(sourceURL.lastPathComponent), needsCompile=\(needsCompile)")

        // If we only have an uncompiled .mlmodel, compile it to .mlmodelc first.
        // MLModel(contentsOf:) only accepts compiled .mlmodelc bundles.
        let loadURL: URL
        if needsCompile {
            if #available(iOS 16.0, *) {
                NSLog("[CoreML] loadModel: compiling \(modelName).mlmodel -> .mlmodelc ...")
                do {
                    let compiledURL = try MLModel.compileModel(at: sourceURL)
                    loadURL = compiledURL
                    NSLog("[CoreML] loadModel: compiled to \(compiledURL.path)")
                } catch {
                    NSLog("[CoreML] loadModel: compile FAILED: \(error)")
                    throw error
                }
            } else {
                NSLog("[CoreML] loadModel: cannot compile .mlmodel on iOS < 16")
                throw CoreMLError.modelNotFound(modelName)
            }
        } else {
            loadURL = sourceURL
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        // Use .all for Neural Engine when available (A12+)
        if #available(iOS 14.0, *) {
            // Prefer GPU + Neural Engine; fall back to CPU if unsupported ops
            config.computeUnits = .all
        }
        NSLog("[CoreML] loadModel: loading from \(loadURL.lastPathComponent) ...")
        let model = try MLModel(contentsOf: loadURL, configuration: config)
        modelCache[modelName] = model
        NSLog("[CoreML] loadModel: \(modelName) loaded successfully")
        return model
    }

    // MARK: - Filter Inference

    /// Apply a neural filter to image data using tile-based inference.
    /// - Parameters:
    ///   - imageData: JPEG encoded input image
    ///   - modelName: Name of the .mlmodel file (without extension)
    ///   - patchSize: Tile size in pixels (default 448)
    ///   - padding: Overlap padding between tiles (default 16)
    ///   - completion: Called with filtered JPEG data or nil on error
    func applyFilter(
        imageData: Data,
        modelName: String,
        patchSize: Int = 448,
        padding: Int = 16,
        completion: @escaping (Data?, Error?) -> Void
    ) {
        guard let image = UIImage(data: imageData) else {
            completion(nil, CoreMLError.preprocessingFailed)
            return
        }

        modelQueue.async { [weak self] in
            do {
                let model = try self?.loadModel(named: modelName)
                guard let model = model else {
                    completion(nil, CoreMLError.modelNotFound(modelName))
                    return
                }

                let result = try self?.processTiled(
                    image: image,
                    model: model,
                    patchSize: patchSize,
                    padding: padding
                )

                guard let outputImage = result,
                      let outputData = outputImage.jpegData(compressionQuality: 0.95) else {
                    completion(nil, CoreMLError.inferenceFailed)
                    return
                }

                DispatchQueue.main.async {
                    completion(outputData, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    // MARK: - Super Resolution Upscale

    /// Apply 2x upscale using CILanczosScaleTransform.
    /// Lanczos is a high-quality interpolation method that produces smooth,
    /// artifact-free results with NO tile boundary problems and NO color shift.
    /// It is hardware-accelerated (Metal) and runs in <100ms for a 3MP image.
    /// - Parameters:
    ///   - imageData: JPEG encoded input image
    ///   - completion: Called with upscaled JPEG data or nil on error
    func upscalePhoto(
        imageData: Data,
        completion: @escaping (Data?, Error?) -> Void
    ) {
        guard let image = UIImage(data: imageData) else {
            NSLog("[CoreML] upscalePhoto: failed to decode image (\(imageData.count) bytes)")
            completion(nil, CoreMLError.preprocessingFailed)
            return
        }

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        NSLog("[CoreML] upscalePhoto: input \(width)x\(height), using Lanczos 2x")

        modelQueue.async { [weak self] in
            if let outputImage = self?.upscaleWithLanczos(image: image),
               let outputData = outputImage.jpegData(compressionQuality: 0.95) {
                NSLog("[CoreML] upscalePhoto: Lanczos output \(Int(outputImage.size.width))x\(Int(outputImage.size.height)), \(outputData.count) bytes")
                DispatchQueue.main.async {
                    completion(outputData, nil)
                }
                return
            }

            NSLog("[CoreML] upscalePhoto: Lanczos failed")
            DispatchQueue.main.async {
                completion(nil, CoreMLError.inferenceFailed)
            }
        }
    }

    // MARK: - PiperSR Upscale (flexible input, no tile blending needed)

    /// Upscale using PiperSR model with flexible input size.
    /// PiperSR is a lightweight (453K params, ~928KB) ANE-native model that
    /// supports any input resolution. Tiles are processed without overlap
    /// and directly pasted into the output — no blending artifacts.
    private func upscaleWithPiperSR(image: UIImage, model: MLModel) throws -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let outputScale = 2

        // Get model's preferred tile size from spec
        let desc = model.modelDescription
        let tileSize: Int
        if let arrType = desc.inputDescriptionsByName.first?.value.multiArrayConstraint {
            let shape = arrType.shape
            tileSize = shape.count >= 3 && shape[2].intValue > 0 ? shape[2].intValue : 128
        } else {
            tileSize = 128
        }

        NSLog("[CoreML] upscaleWithPiperSR: \(width)x\(height), tileSize=\(tileSize)")

        // Try processing the entire image at once (PiperSR supports flexible input)
        // If the image is small enough, we can avoid tiling entirely
        let maxSingleTile = 1024  // process up to 1024x1024 as single tile
        if width <= maxSingleTile && height <= maxSingleTile {
            NSLog("[CoreML] upscaleWithPiperSR: processing as single tile")
            if let cgResult = try processSinglePiperSRTile(cgImage: cgImage, model: model,
                                                 srcX: 0, srcY: 0, tileW: width, tileH: height) {
                return UIImage(cgImage: cgResult)
            }
            return nil
        }

        // For larger images, use tiling without overlap (PiperSR is boundary-insensitive)
        let cols = Int(ceil(Double(width) / Double(tileSize)))
        let rows = Int(ceil(Double(height) / Double(tileSize)))
        let outputWidth = width * outputScale
        let outputHeight = height * outputScale
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!

        NSLog("[CoreML] upscaleWithPiperSR: tiling \(cols)x\(rows) = \(cols*rows) tiles")

        guard let outCtx = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        var tileIdx = 0
        for row in 0..<rows {
            for col in 0..<cols {
                let srcX = col * tileSize
                let srcY = row * tileSize
                let tileW = min(tileSize, width - srcX)
                let tileH = min(tileSize, height - srcY)

                guard let tileResult = try? processSinglePiperSRTile(
                    cgImage: cgImage, model: model,
                    srcX: srcX, srcY: srcY, tileW: tileW, tileH: tileH
                ) else { continue }

                // Direct paste — no blending needed for PiperSR
                let destX = srcX * outputScale
                let destY = srcY * outputScale
                outCtx.draw(tileResult, in: CGRect(x: destX, y: destY,
                                                    width: tileResult.width, height: tileResult.height))

                tileIdx += 1
                if tileIdx % 10 == 0 {
                    NSLog("[CoreML] upscaleWithPiperSR: \(tileIdx)/\(cols*rows) tiles")
                }
            }
        }

        guard let finalCG = outCtx.makeImage() else { return nil }
        return UIImage(cgImage: finalCG)
    }

    /// Process a single tile through PiperSR model.
    private func processSinglePiperSRTile(
        cgImage: CGImage, model: MLModel,
        srcX: Int, srcY: Int, tileW: Int, tileH: Int
    ) throws -> CGImage? {
        guard let patch = cgImage.cropping(to: CGRect(x: srcX, y: srcY, width: tileW, height: tileH))
        else { return nil }

        // Convert to CVPixelBuffer for CoreML
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, tileW, tileH, kCVPixelFormatType_32ARGB,
                             attrs as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        guard let c = CGContext(
            data: CVPixelBufferGetBaseAddress(buf), width: tileW, height: tileH,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        c.draw(patch, in: CGRect(x: 0, y: 0, width: tileW, height: tileH))

        // Run prediction
        let input = CoreMLInput(input: buf)
        let prediction = try model.prediction(from: input)

        // Get output
        guard let outName = prediction.featureNames.first,
              let outVal = prediction.featureValue(for: outName) else { return nil }

        if let multiArray = outVal.multiArrayValue {
            return imageFromMultiArray(multiArray)?.cgImage
        } else if let pixelBuffer = outVal.imageBufferValue {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ciCtx = CIContext()
            return ciCtx.createCGImage(ciImage, from: ciImage.extent)
        }
        return nil
    }

    // MARK: - Lanczos 2x Upscale (no model, high-quality interpolation)

    /// Upscale using CILanczosScaleTransform — hardware-accelerated,
    /// no tile artifacts, excellent quality for 2x photo upscaling.
    private func upscaleWithLanczos(image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let scale = 2.0

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)

        guard let output = filter.outputImage else { return nil }
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ciCtx.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Tile-based Processing

    /// Tile-based image processing.
    ///
    /// Divides the image into overlapping patches, processes each through
    /// the CoreML model, and reconstructs the full output image.
    /// Uses feathered blending in the padding overlap region to avoid
    /// visible seams between tiles.
    ///
    /// - Parameter outputScale: The spatial scale factor between model input and
    ///   output. Use 1 for filters (448 -> 448) and 2 for EDSR super-resolution
    ///   (224 -> 448).
    // Precomputed weight maps for tile blending.
    // Each entry maps tile coordinate → 1D weight ramp (sigmoid).
    private static var weightCache: [String: [[Float]]] = [:]
    private static let weightCacheLock = NSLock()

    private func processTiled(
        image: UIImage,
        model: MLModel,
        patchSize: Int,
        padding: Int,
        outputScale: Int = 1
    ) throws -> UIImage? {

        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        NSLog("[CoreML] processTiled: input \(width)x\(height), patchSize=\(patchSize), padding=\(padding), outputScale=\(outputScale)")

        let cols = Int(ceil(Double(width) / Double(patchSize)))
        let rows = Int(ceil(Double(height) / Double(patchSize)))

        let outPatchSize = patchSize * outputScale
        let outPadding = padding * outputScale
        let outputWidth = width * outputScale
        let outputHeight = height * outputScale
        let effectiveSize = patchSize + 2 * padding
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        if outputScale == 1 {
            // ── Filter path: premultiplied + feather alpha blend ──
            return try processTiledFilter(
                cgImage: cgImage, model: model,
                cols: cols, rows: rows,
                patchSize: patchSize, padding: padding,
                width: width, height: height,
                effectiveSize: effectiveSize,
                outPatchSize: outPatchSize, outPadding: outPadding,
                outputWidth: outputWidth, outputHeight: outputHeight,
                outputScale: outputScale
            )
        }

        // ── Super-resolution path ──
        // Standard approach from Real-ESRGAN / ChaiNNer:
        // 1. Each tile is the model's FULL output (effectiveSize * outputScale pixels).
        // 2. Adjacent tiles overlap by 2*outPadding (output-space).
        // 3. The overlap is blended using a sigmoid weight map: weight(x,y) =
        //    sigmoid_x(x) * sigmoid_y(y), where sigmoid_x fades from 0→1
        //    across the tile and sigmoid_y does the same vertically.
        // 4. Because the weight sum across all tiles covering a pixel is 1,
        //    there is NO darkening — this is a pure weighted average.

        // Precompute 1D weight ramps for each column/row position
        let wx = try precomputeWeights(count: cols, size: outPatchSize, overlap: outPadding)
        let wy = try precomputeWeights(count: rows, size: outPatchSize, overlap: outPadding)

        // Output canvas: opaque
        guard let outCtx = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Temporary accumulation buffers (Float for precision)
        guard let outData = outCtx.data else { return nil }
        let outPtr = outData.assumingMemoryBound(to: UInt8.self)
        let outBpr = outCtx.bytesPerRow

        // We'll accumulate weighted sums per-pixel.
        // Allocate float accumulation buffers.
        let accR = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
        let accG = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
        let accB = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
        let accW = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
        accR.initialize(repeating: 0, count: outputWidth * outputHeight)
        accG.initialize(repeating: 0, count: outputWidth * outputHeight)
        accB.initialize(repeating: 0, count: outputWidth * outputHeight)
        accW.initialize(repeating: 0, count: outputWidth * outputHeight)
        defer {
            accR.deallocate()
            accG.deallocate()
            accB.deallocate()
            accW.deallocate()
        }

        var tileIdx = 0
        for row in 0..<rows {
            for col in 0..<cols {
                // Run inference for this tile
                guard let tileCG = try runTile(
                    cgImage: cgImage, model: model,
                    col: col, row: row,
                    patchSize: patchSize, padding: padding,
                    width: width, height: height,
                    effectiveSize: effectiveSize,
                    outputScale: outputScale
                ) else { continue }

                // Tile output dimensions in output space
                let tileOutW = tileCG.width   // cropW * outputScale
                let tileOutH = tileCG.height  // cropH * outputScale

                // Decode tile to raw RGBA
                var tileBytes = [UInt8](repeating: 0, count: tileOutW * tileOutH * 4)
                guard let tileCtx = CGContext(
                    data: &tileBytes, width: tileOutW, height: tileOutH,
                    bitsPerComponent: 8, bytesPerRow: tileOutW * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { continue }
                tileCtx.draw(tileCG, in: CGRect(x: 0, y: 0, width: tileOutW, height: tileOutH))

                // Destination in output canvas
                let destX = col * outPatchSize - outPadding
                let destY = row * outPatchSize - outPadding

                // Add tile contribution weighted by the sigmoid map
                for ty in 0..<tileOutH {
                    let oy = destY + ty
                    if oy < 0 || oy >= outputHeight { continue }
                    let wyVal = wy[row][ty]  // vertical weight for this row

                    for tx in 0..<tileOutW {
                        let ox = destX + tx
                        if ox < 0 || ox >= outputWidth { continue }
                        let wxVal = wx[col][tx]  // horizontal weight for this column

                        let weight = wxVal * wyVal
                        let tileOff = ty * tileOutW * 4 + tx * 4
                        let accOff = oy * outputWidth + ox

                        let r = Float(tileBytes[tileOff])
                        let g = Float(tileBytes[tileOff + 1])
                        let b = Float(tileBytes[tileOff + 2])

                        accR[accOff] += r * weight
                        accG[accOff] += g * weight
                        accB[accOff] += b * weight
                        accW[accOff] += weight
                    }
                }

                tileIdx += 1
                if tileIdx % 10 == 0 {
                    NSLog("[CoreML] processTiled: \(tileIdx)/\(cols*rows) tiles")
                }
            }
        }

        // Normalize and write to output canvas
        for i in 0..<(outputWidth * outputHeight) {
            let w = accW[i]
            if w > 0.0001 {
                outPtr[i * 4]     = UInt8(min(max(accR[i] / w, 0), 255))
                outPtr[i * 4 + 1] = UInt8(min(max(accG[i] / w, 0), 255))
                outPtr[i * 4 + 2] = UInt8(min(max(accB[i] / w, 0), 255))
            }
            outPtr[i * 4 + 3] = 255
        }

        guard let finalCG = outCtx.makeImage() else {
            NSLog("[CoreML] processTiled: makeImage() failed")
            return nil
        }
        return UIImage(cgImage: finalCG)
    }

    // MARK: - Tile weight maps

    /// Generate 1D weight ramps for each tile column/row.
    /// Each ramp is `size` elements long (the tile width/height in output pixels).
    /// Interior tiles get sigmoid fades on both ends; edge tiles get a half-ramp
    /// (only one side fades). The sum of weights across all tiles for any given
    /// output pixel is always 1.0.
    private func precomputeWeights(count: Int, size: Int, overlap: Int) throws -> [[Float]] {
        let cacheKey = "\(count)_\(size)_\(overlap)"
        Self.weightCacheLock.lock()
        if let cached = Self.weightCache[cacheKey] {
            Self.weightCacheLock.unlock()
            return cached
        }
        Self.weightCacheLock.unlock()

        var result: [[Float]] = []
        for i in 0..<count {
            var ramp = [Float](repeating: 1.0, count: size + 2 * overlap)
            let hasLeft = i > 0
            let hasRight = i < count - 1

            // Sigmoid fade-in on left edge (if there's a neighbor)
            if hasLeft {
                for x in 0..<overlap {
                    let t = Float(x) / Float(overlap)  // 0 → 1 across overlap
                    ramp[x] = sigmoidWeight(t)
                }
            }
            // Sigmoid fade-out on right edge
            if hasRight {
                for x in 0..<overlap {
                    let t = Float(x) / Float(overlap)
                    ramp[size + overlap + x] = 1.0 - sigmoidWeight(t)
                }
            }
            result.append(ramp)
        }

        Self.weightCacheLock.lock()
        Self.weightCache[cacheKey] = result
        Self.weightCacheLock.unlock()
        return result
    }

    /// Sigmoid-based weight: f(t) where f(0)≈0, f(1)≈1, smooth transition.
    /// Uses σ(12*(t-0.5)) which gives a steep but smooth ramp.
    private func sigmoidWeight(_ t: Float) -> Float {
        let x = 12.0 * (t - 0.5)
        // Stable sigmoid: 1/(1+exp(-x))
        if x > 20 { return 1.0 }
        if x < -20 { return 0.0 }
        return 1.0 / (1.0 + expf(-x))
    }

    // MARK: - Single tile inference

    /// Run one tile through the model and return the full output CGImage.
    private func runTile(
        cgImage: CGImage,
        model: MLModel,
        col: Int, row: Int,
        patchSize: Int, padding: Int,
        width: Int, height: Int,
        effectiveSize: Int,
        outputScale: Int
    ) throws -> CGImage? {
        let srcX = col * patchSize - padding
        let srcY = row * patchSize - padding
        let padL = max(0, -srcX)
        let padT = max(0, -srcY)
        let padR = max(0, (srcX + effectiveSize) - width)
        let padB = max(0, (srcY + effectiveSize) - height)
        let cropX = srcX + padL
        let cropY = srcY + padT
        let cropW = effectiveSize - padL - padR
        let cropH = effectiveSize - padT - padB

        guard cropW > 0, cropH > 0,
              let patch = cgImage.cropping(to: CGRect(x: cropX, y: cropY,
                                                       width: cropW, height: cropH))
        else { return nil }

        let patchImage: UIImage
        if padL > 0 || padT > 0 || padR > 0 || padB > 0 {
            patchImage = padTile(
                UIImage(cgImage: patch),
                to: CGSize(width: effectiveSize, height: effectiveSize),
                offsetX: padL, offsetY: padT
            )
        } else {
            patchImage = UIImage(cgImage: patch)
        }

        guard let pred = try? predict(model: model, image: patchImage),
              let predCG = pred.cgImage else { return nil }

        // Crop to valid output region (skip padded output at image edges)
        let outCropX = padL * outputScale
        let outCropY = padT * outputScale
        let validOutW = cropW * outputScale
        let validOutH = cropH * outputScale

        return predCG.cropping(to: CGRect(x: outCropX, y: outCropY,
                                           width: validOutW, height: validOutH))
    }

    // MARK: - Filter tiling (unchanged alpha-feather path)

    private func processTiledFilter(
        cgImage: CGImage,
        model: MLModel,
        cols: Int, rows: Int,
        patchSize: Int, padding: Int,
        width: Int, height: Int,
        effectiveSize: Int,
        outPatchSize: Int, outPadding: Int,
        outputWidth: Int, outputHeight: Int,
        outputScale: Int
    ) throws -> UIImage? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        for row in 0..<rows {
            for col in 0..<cols {
                guard let tile = try runTile(
                    cgImage: cgImage, model: model,
                    col: col, row: row,
                    patchSize: patchSize, padding: padding,
                    width: width, height: height,
                    effectiveSize: effectiveSize,
                    outputScale: outputScale
                ) else { continue }

                let validOutW = tile.width
                let validOutH = tile.height
                let destX = col * outPatchSize - outPadding
                let destY = row * outPatchSize - outPadding

                let hasLeft = col > 0
                let hasRight = col < cols - 1
                let hasTop = row > 0
                let hasBottom = row < rows - 1

                let toDraw: CGImage
                if hasLeft || hasRight || hasTop || hasBottom {
                    toDraw = applyFeatherAlpha(
                        cgImage: tile, width: validOutW, height: validOutH,
                        padding: outPadding,
                        left: hasLeft, right: hasRight,
                        top: hasTop, bottom: hasBottom
                    ) ?? tile
                } else {
                    toDraw = tile
                }

                UIGraphicsPushContext(context)
                context.draw(toDraw, in: CGRect(x: destX, y: destY,
                                                width: validOutW, height: validOutH))
                UIGraphicsPopContext()
            }
        }

        guard let full = context.makeImage() else { return nil }
        let flatInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let flatCtx = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: flatInfo
        ) else { return nil }
        flatCtx.draw(full, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard let final = flatCtx.makeImage() else { return nil }
        return UIImage(cgImage: final)
    }

    private func applyFeatherAlpha(
        cgImage: CGImage, width: Int, height: Int, padding: Int,
        left: Bool, right: Bool, top: Bool, bottom: Bool
    ) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Now modulate the alpha channel with the feather weights.
        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow
        let pad = CGFloat(padding)

        for y in 0..<height {
            for x in 0..<width {
                let fx = CGFloat(x)
                let fy = CGFloat(y)
                let fw = CGFloat(width)
                let fh = CGFloat(height)

                var alpha: CGFloat = 1.0
                if left   { alpha *= min(fx, pad) / pad }
                if right  { alpha *= min(fw - 1 - fx, pad) / pad }
                if top    { alpha *= min(fy, pad) / pad }
                if bottom { alpha *= min(fh - 1 - fy, pad) / pad }

                let a = UInt8(min(max(alpha, 0), 1) * 255)
                let offset = y * bytesPerRow + x * 4
                // Premultiplied alpha: scale RGB by the feather alpha.
                let oldA = ptr[offset + 3]
                if oldA == 0 { continue }
                let scale = CGFloat(a) / CGFloat(oldA)
                ptr[offset + 0] = UInt8(min(CGFloat(ptr[offset + 0]) * scale, 255))
                ptr[offset + 1] = UInt8(min(CGFloat(ptr[offset + 1]) * scale, 255))
                ptr[offset + 2] = UInt8(min(CGFloat(ptr[offset + 2]) * scale, 255))
                ptr[offset + 3] = a
            }
        }

        return ctx.makeImage()
    }

    /// Run a single CoreML prediction on a patch.
    private func predict(model: MLModel, image: UIImage) throws -> UIImage? {
        guard let pixelBuffer = image.pixelBuffer() else {
            NSLog("[CoreML] predict: pixelBuffer() failed for \(Int(image.size.width))x\(Int(image.size.height))")
            throw CoreMLError.preprocessingFailed
        }

        let input = CoreMLInput(input: pixelBuffer)
        let prediction = try model.prediction(from: input)

        // Try to get output from the first available output feature
        guard let outputName = prediction.featureNames.first,
              let outputValue = prediction.featureValue(for: outputName) else {
            NSLog("[CoreML] predict: no output features")
            throw CoreMLError.inferenceFailed
        }

        // Handle both MultiArray and Image output types
        if let multiArray = outputValue.multiArrayValue {
            let h = multiArray.shape[2].intValue
            let w = multiArray.shape[3].intValue
            NSLog("[CoreML] predict: MultiArray output \(w)x\(h)")
            return imageFromMultiArray(multiArray)
        } else if let pixelBuffer = outputValue.imageBufferValue {
            NSLog("[CoreML] predict: ImageBuffer output")
            return UIImage(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        }

        NSLog("[CoreML] predict: unrecognized output type")
        throw CoreMLError.inferenceFailed
    }

    /// Convert MLMultiArray back to UIImage.
    /// Auto-detects output range: if values > 1 → [0,255] (EDSR), else [0,1] (filters).
    private func imageFromMultiArray(_ array: MLMultiArray) -> UIImage? {
        // Array shape: [1, 3, height, width] (channel first)
        let height = array.shape[2].intValue
        let width = array.shape[3].intValue

        let totalPixels = height * width
        // Use 4 bytes per pixel (RGBA) — RGB w/o alpha fails on iOS 18+
        var rgbaData = [UInt8](repeating: 0, count: totalPixels * 4)

        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)

        // Auto-detect output range: sample first 100 values
        var needsScaling = false
        let sampleCount = min(100, totalPixels * 3)
        for i in 0..<sampleCount {
            if pointer[i] > 2.0 {
                needsScaling = false // values already in [0, 255]
                break
            }
            if pointer[i] <= 1.0 && i == sampleCount - 1 {
                needsScaling = true // all sampled values in [0, 1]
            }
        }
        let scale: Float = needsScaling ? 255.0 : 1.0

        for c in 0..<3 {
            for i in 0..<totalPixels {
                let val = pointer[c * totalPixels + i] * scale
                rgbaData[i * 4 + c] = UInt8(min(max(val, 0), 255))
            }
        }
        for i in 0..<totalPixels {
            rgbaData[i * 4 + 3] = 255
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &rgbaData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Pad a tile image: place content at (offsetX, offsetY), fill rest with edge color.
    private func padTile(_ image: UIImage, to size: CGSize, offsetX: Int, offsetY: Int) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Fill with edge pixel color to replicate border
            if let cgImg = image.cgImage,
               let edgeCtx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
               ) {
                edgeCtx.draw(cgImg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if let edgeData = edgeCtx.data?.assumingMemoryBound(to: UInt8.self) {
                    let r = CGFloat(edgeData[0]) / 255.0
                    let g = CGFloat(edgeData[1]) / 255.0
                    let b = CGFloat(edgeData[2]) / 255.0
                    UIColor(red: r, green: g, blue: b, alpha: 1.0).setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                }
            }
            image.draw(in: CGRect(x: CGFloat(offsetX), y: CGFloat(offsetY),
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// Clear the model cache.
    func clearCache() {
        modelCache.removeAll()
    }

    // MARK: - Feather Mask for Tile Blending

    /// Create a CGImage mask that fades to black (transparent) at tile edges
    /// that have neighbours. Internal edges get a linear ramp from 1→0
    /// over `padding` pixels; external edges (image border) stay fully
    /// opaque so the edge of the image doesn't fade.
    private func featherMask(
        size: CGSize,
        padding: Int,
        left: Bool,
        right: Bool,
        top: Bool,
        bottom: Bool
    ) -> CGImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        let pad = CGFloat(padding)
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = w
        var data = [UInt8](repeating: 0, count: w * h)

        for y in 0..<h {
            for x in 0..<w {
                let fx = CGFloat(x)
                let fy = CGFloat(y)
                let cw = CGFloat(w)
                let ch = CGFloat(h)

                var alpha: CGFloat = 1.0

                if left   { alpha *= min(fx, pad) / pad }
                if right  { alpha *= min(cw - 1 - fx, pad) / pad }
                if top    { alpha *= min(fy, pad) / pad }
                if bottom { alpha *= min(ch - 1 - fy, pad) / pad }

                data[y * bytesPerRow + x] = UInt8(min(max(alpha, 0), 1) * 255)
            }
        }

        guard let provider = CGDataProvider(data: NSData(bytes: &data,
                                                     length: data.count)) else {
            return nil
        }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - Errors

enum CoreMLError: LocalizedError {
    case modelNotFound(String)
    case preprocessingFailed
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Model not found: \(name).mlmodel"
        case .preprocessingFailed:
            return "Failed to preprocess image for CoreML"
        case .inferenceFailed:
            return "CoreML inference failed"
        }
    }
}

// MARK: - CoreML Input Wrapper

class CoreMLInput: MLFeatureProvider {
    let input: CVPixelBuffer
    var featureNames: Set<String> { ["input"] }

    init(input: CVPixelBuffer) {
        self.input = input
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        guard featureName == "input" else { return nil }
        return MLFeatureValue(pixelBuffer: input)
    }
}

// MARK: - UIImage to CVPixelBuffer Extension

extension UIImage {
    func pixelBuffer() -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        guard let cgImage = self.cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }
}

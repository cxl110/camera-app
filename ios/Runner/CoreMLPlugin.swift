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

        // Try loading from app bundle (native resources)
        // First try .mlmodelc (compiled), then .mlmodel (uncompiled)
        let modelURL: URL?
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            modelURL = url
        } else if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodel") {
            modelURL = url
        } else {
            // Fallback: try Flutter assets path. In release builds Flutter assets live
            // inside App.framework; in some configurations they may be directly under
            // the main bundle.
            let flutterAssetsSubdirs = [
                "Frameworks/App.framework/flutter_assets/assets/models",
                "flutter_assets/assets/models",
            ]
            var foundURL: URL?
            for subdir in flutterAssetsSubdirs {
                if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: subdir) {
                    foundURL = url
                    break
                }
                if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodel", subdirectory: subdir) {
                    foundURL = url
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
                    let mlmodel = dir.appendingPathComponent("\(modelName).mlmodel")
                    let mlmodelc = dir.appendingPathComponent("\(modelName).mlmodelc")
                    if FileManager.default.fileExists(atPath: mlmodel.path) {
                        foundURL = mlmodel
                        break
                    } else if FileManager.default.fileExists(atPath: mlmodelc.path) {
                        foundURL = mlmodelc
                        break
                    }
                }
            }
            if let foundURL = foundURL {
                modelURL = foundURL
            } else {
                throw CoreMLError.modelNotFound(modelName)
            }
        }

        let model = try MLModel(contentsOf: modelURL!)
        modelCache[modelName] = model
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

    /// Apply EDSR-Base x2 super-resolution upscale.
    /// - Parameters:
    ///   - imageData: JPEG encoded input image
    ///   - completion: Called with upscaled JPEG data or nil on error
    func upscalePhoto(
        imageData: Data,
        completion: @escaping (Data?, Error?) -> Void
    ) {
        guard let image = UIImage(data: imageData) else {
            completion(nil, CoreMLError.preprocessingFailed)
            return
        }

        let modelName = "edsr_base_x2"

        modelQueue.async { [weak self] in
            do {
                let model = try self?.loadModel(named: modelName)
                guard let model = model else {
                    completion(nil, CoreMLError.modelNotFound(modelName))
                    return
                }

                // For EDSR-Base x2: model expects 224x224 input tiles, produces 2x output.
                // effectiveSize = patchSize + 2*padding = 192 + 32 = 224 → matches model.
                let result = try self?.processTiled(
                    image: image,
                    model: model,
                    patchSize: 192,
                    padding: 16,
                    outputScale: 2
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

    // MARK: - Tile-based Processing

    /// Tile-based image processing.
    ///
    /// Divides the image into overlapping patches, processes each through
    /// the CoreML model, and reconstructs the full output image.
    ///
    /// - Parameter outputScale: The spatial scale factor between model input and
    ///   output. Use 1 for filters (448 -> 448) and 2 for EDSR super-resolution
    ///   (224 -> 448).
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

        // Calculate grid dimensions
        let cols = Int(ceil(Double(width) / Double(patchSize)))
        let rows = Int(ceil(Double(height) / Double(patchSize)))

        // Output buffer accounts for the model's output scale
        let outPatchSize = patchSize * outputScale
        let outPadding = padding * outputScale
        let outputWidth = cols * outPatchSize
        let outputHeight = rows * outPatchSize
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        let effectiveSize = patchSize + 2 * padding

        for row in 0..<rows {
            for col in 0..<cols {
                // Calculate source region with padding
                let srcX = max(0, col * patchSize - padding)
                let srcY = max(0, row * patchSize - padding)
                let srcWidth = min(effectiveSize, width - srcX)
                let srcHeight = min(effectiveSize, height - srcY)

                // Extract patch
                guard let patchCGImage = cgImage.cropping(to: CGRect(
                    x: srcX, y: srcY,
                    width: srcWidth, height: srcHeight
                )) else { continue }

                // If patch is smaller than effective size, pad with edge values
                let patchImage: UIImage
                if srcWidth < effectiveSize || srcHeight < effectiveSize {
                    patchImage = padImage(
                        UIImage(cgImage: patchCGImage),
                        to: CGSize(width: effectiveSize, height: effectiveSize)
                    )
                } else {
                    patchImage = UIImage(cgImage: patchCGImage)
                }

                // Run CoreML inference
                guard let filteredPatch = try? predict(model: model, image: patchImage) else {
                    continue
                }

                // Remove padding and place in output. Padding is scaled on the
                // output side for super-resolution.
                let cropRect = CGRect(
                    x: outPadding, y: outPadding,
                    width: outPatchSize, height: outPatchSize
                )

                guard let croppedCGImage = filteredPatch.cgImage?.cropping(to: cropRect) else {
                    continue
                }

                let destX = col * outPatchSize
                let destY = row * outPatchSize
                let destRect = CGRect(
                    x: destX, y: destY,
                    width: outPatchSize, height: outPatchSize
                )

                // Draw into output context
                let croppedImage = UIImage(cgImage: croppedCGImage)
                UIGraphicsPushContext(context)
                croppedImage.draw(in: destRect)
                UIGraphicsPopContext()
            }
        }

        // Crop to final output size (original image size multiplied by outputScale)
        guard let fullOutput = context.makeImage() else { return nil }
        guard let finalImage = fullOutput.cropping(to: CGRect(
            x: 0, y: 0, width: width * outputScale, height: height * outputScale
        )) else { return nil }

        return UIImage(cgImage: finalImage)
    }

    /// Run a single CoreML prediction on a patch.
    private func predict(model: MLModel, image: UIImage) throws -> UIImage? {
        guard let pixelBuffer = image.pixelBuffer() else {
            throw CoreMLError.preprocessingFailed
        }

        let input = CoreMLInput(input: pixelBuffer)
        let prediction = try model.prediction(from: input)

        // Try to get output from the first available output feature
        guard let outputName = prediction.featureNames.first,
              let outputValue = prediction.featureValue(for: outputName) else {
            throw CoreMLError.inferenceFailed
        }

        // Handle both MultiArray and Image output types
        if let multiArray = outputValue.multiArrayValue {
            return imageFromMultiArray(multiArray)
        } else if let pixelBuffer = outputValue.imageBufferValue {
            return UIImage(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        }

        throw CoreMLError.inferenceFailed
    }

    /// Convert MLMultiArray back to UIImage.
    private func imageFromMultiArray(_ array: MLMultiArray) -> UIImage? {
        // Array shape: [1, 3, height, width] (channel first)
        let height = array.shape[2].intValue
        let width = array.shape[3].intValue

        let totalPixels = height * width
        var rgbData = [UInt8](repeating: 0, count: totalPixels * 3)

        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)

        for c in 0..<3 {
            for i in 0..<totalPixels {
                let val = pointer[c * totalPixels + i] * 255.0
                rgbData[i * 3 + c] = UInt8(min(max(val, 0), 255))
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &rgbData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Pad an image to fill target size (edge replication).
    private func padImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Draw original at (0,0) — remaining area is transparent black
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Clear the model cache.
    func clearCache() {
        modelCache.removeAll()
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
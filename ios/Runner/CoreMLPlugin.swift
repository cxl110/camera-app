import Foundation
import CoreML
import Vision
import UIKit

/// Native iOS plugin for CoreML neural filter inference.
///
/// Communicates with Flutter via MethodChannel "com.cameraapp/coreml".
/// Handles tile-based image processing to support any input resolution
/// with a fixed model input size.
@objc(CoreMLPlugin)
class CoreMLPlugin: NSObject {

    // Cache loaded models for performance
    private var modelCache: [String: MLModel] = [:]
    private let modelQueue = DispatchQueue(label: "com.cameraapp.coreml", qos: .userInitiated)

    /// Load a CoreML model from the app bundle.
    func loadModel(named modelName: String) throws -> MLModel {
        // Check cache first
        if let cached = modelCache[modelName] {
            return cached
        }

        guard let modelURL = Bundle.main.url(forResource: modelName,
                                              withExtension: "mlmodelc") ??
                              Bundle.main.url(forResource: modelName,
                                              withExtension: "mlmodel") else {
            throw CoreMLError.modelNotFound(modelName)
        }

        let model = try MLModel(contentsOf: modelURL)
        modelCache[modelName] = model
        return model
    }

    /// Apply a neural filter to an image using tile-based inference.
    ///
    /// - Parameters:
    ///   - image: Input UIImage
    ///   - modelName: Name of the .mlmodel file (without extension)
    ///   - patchSize: Size of each tile (default 448)
    ///   - padding: Overlap padding between tiles (default 16)
    ///   - completion: Called with filtered UIImage or nil on error
    func applyFilter(
        to image: UIImage,
        modelName: String,
        patchSize: Int = 448,
        padding: Int = 16,
        progress: ((Float) -> Void)? = nil,
        completion: @escaping (UIImage?, Error?) -> Void
    ) {
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
                    padding: padding,
                    progress: progress
                )

                DispatchQueue.main.async {
                    completion(result, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    /// Tile-based image processing.
    ///
    /// Divides the image into overlapping patches, processes each through
    /// the CoreML model, and reconstructs the full output image.
    private func processTiled(
        image: UIImage,
        model: MLModel,
        patchSize: Int,
        padding: Int,
        progress: ((Float) -> Void)? = nil
    ) throws -> UIImage? {

        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        // Calculate grid dimensions
        let cols = Int(ceil(Double(width) / Double(patchSize)))
        let rows = Int(ceil(Double(height) / Double(patchSize)))
        let totalPatches = cols * rows

        // Output buffer
        let outputWidth = cols * patchSize
        let outputHeight = rows * patchSize
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

                // Remove padding and place in output
                let cropRect = CGRect(
                    x: padding, y: padding,
                    width: patchSize, height: patchSize
                )

                guard let croppedCGImage = filteredPatch.cgImage?.cropping(to: cropRect) else {
                    continue
                }

                let destX = col * patchSize
                let destY = row * patchSize
                let destRect = CGRect(
                    x: destX, y: destY,
                    width: patchSize, height: patchSize
                )

                // Draw into output context
                let croppedImage = UIImage(cgImage: croppedCGImage)
                UIGraphicsPushContext(context)
                croppedImage.draw(in: destRect)
                UIGraphicsPopContext()

                // Report progress
                let current = row * cols + col + 1
                progress?(Float(current) / Float(totalPatches))
            }
        }

        // Crop to original image size
        guard let fullOutput = context.makeImage() else { return nil }
        guard let finalImage = fullOutput.cropping(to: CGRect(
            x: 0, y: 0, width: width, height: height
        )) else { return nil }

        return UIImage(cgImage: finalImage)
    }

    /// Run a single CoreML prediction on a patch.
    private func predict(model: MLModel, image: UIImage) throws -> UIImage? {
        // CoreML model expects RGB input with shape [1, 3, H, W]
        // The model definition includes scale=1/255.0 normalization

        guard let pixelBuffer = image.pixelBuffer() else {
            throw CoreMLError.preprocessingFailed
        }

        let input = try MLMultiArray(shape: [1, 3,
                                             NSNumber(value: image.size.height),
                                             NSNumber(value: image.size.width)],
                                     dataType: .float32)

        // The model handles the conversion internally via ImageType input
        let prediction = try model.prediction(from: CoreMLInput(input: pixelBuffer))

        guard let outputData = prediction.featureValue(for: "output")?.multiArrayValue else {
            throw CoreMLError.inferenceFailed
        }

        return imageFromMultiArray(outputData)
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

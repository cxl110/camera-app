import Foundation
import CoreML
import CoreGraphics

// Test if EDSR model accepts a larger input (e.g. 480x480 instead of 224x224)

let model = try MLModel(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/camera_app/assets/models/edsr_base_x2.mlmodelc"), configuration: { let c = MLModelConfiguration(); c.computeUnits = .all; return c }())
print("Model loaded")

// Try different sizes
let testSizes = [224, 320, 384, 480]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

for size in testSizes {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
    guard let buf = pb else { continue }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }

    // Fill with test data
    guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { continue }
    c.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: size, height: size))

    do {
        let pred = try model.prediction(from: CoreMLInput(input: buf))
        if let nm = pred.featureNames.first, let fv = pred.featureValue(for: nm),
           let arr = fv.multiArrayValue {
            print("\(size)x\(size): OK -> output \(arr.shape[2].intValue)x\(arr.shape[3].intValue)")
        } else {
            print("\(size)x\(size): OK (image output)")
        }
    } catch {
        print("\(size)x\(size): FAILED - \(error.localizedDescription)")
    }
}

print("Done!")

class CoreMLInput: MLFeatureProvider {
    let input: CVPixelBuffer
    var featureNames: Set<String> { ["input"] }
    init(input: CVPixelBuffer) { self.input = input }
    func featureValue(for name: String) -> MLFeatureValue? { name == "input" ? MLFeatureValue(pixelBuffer: input) : nil }
}

import Foundation
import CoreML
import CoreGraphics
import CoreImage

// Test: create a gradient test image and upscale it with the FIXED tile logic
let width = 320
let height = 240
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
var pixelData = [UInt8](repeating: 0, count: width * height * 4)

for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        pixelData[offset] = UInt8(x * 255 / width)     // R: horizontal
        pixelData[offset + 1] = UInt8(y * 255 / height) // G: vertical
        pixelData[offset + 2] = 128                      // B
        pixelData[offset + 3] = 255                      // A
    }
}

guard let ctx = CGContext(
    data: &pixelData,
    width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
), let testCGImage = ctx.makeImage() else { fatalError("create image") }

print("Input: \(width)x\(height)")

let modelURL = URL(fileURLWithPath: NSHomeDirectory() + "/camera_app/assets/models/edsr_base_x2.mlmodelc")
let config = MLModelConfiguration()
config.computeUnits = .all
let model = try MLModel(contentsOf: modelURL, configuration: config)
print("Model loaded")

let patchSize = 192
let padding = 16
let effectiveSize = patchSize + 2 * padding  // 224
let outputScale = 2

let cols = Int(ceil(Double(width) / Double(patchSize)))
let rows = Int(ceil(Double(height) / Double(patchSize)))
print("Grid: \(cols)x\(rows) tiles")

let outputWidth = width * outputScale
let outputHeight = height * outputScale
let outColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let outPatchSize = patchSize * outputScale

// FIXED: opaque noneSkipLast context for super-resolution
guard let outputCtx = CGContext(
    data: nil,
    width: outputWidth, height: outputHeight,
    bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
    space: outColorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("output ctx") }

// FIXED tile logic: simple tiling, content region only, no overlap
for row in 0..<rows {
    for col in 0..<cols {
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
              let patchCGImage = testCGImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
        else { continue }

        // Pad to effectiveSize
        let paddedImage: CGImage
        if padL > 0 || padT > 0 || padR > 0 || padB > 0 {
            guard let padCtx = CGContext(
                data: nil,
                width: effectiveSize, height: effectiveSize,
                bitsPerComponent: 8, bytesPerRow: effectiveSize * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            padCtx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            padCtx.fill(CGRect(x: 0, y: 0, width: effectiveSize, height: effectiveSize))
            padCtx.draw(patchCGImage, in: CGRect(x: padL, y: padT, width: cropW, height: cropH))
            guard let p = padCtx.makeImage() else { continue }
            paddedImage = p
        } else {
            paddedImage = patchCGImage
        }

        guard let tilePB = cgImageToPixelBuffer(paddedImage) else { continue }
        let tileInput = CoreMLInput(input: tilePB)
        let tilePred = try model.prediction(from: tileInput)
        guard let tOutName = tilePred.featureNames.first,
              let tOutVal = tilePred.featureValue(for: tOutName),
              let tArr = tOutVal.multiArrayValue else { continue }

        let th = tArr.shape[2].intValue
        let tw = tArr.shape[3].intValue
        let tPtr = tArr.dataPointer.assumingMemoryBound(to: Float.self)

        var tNeedsScale = false
        for i in 0..<min(100, tw*th*3) {
            if tPtr[i] > 2.0 { tNeedsScale = false; break }
            if tPtr[i] <= 1.0 && i == min(100, tw*th*3)-1 { tNeedsScale = true }
        }
        let tScale: Float = tNeedsScale ? 255.0 : 1.0

        var tRgba = [UInt8](repeating: 0, count: tw * th * 4)
        let tTotal = tw * th
        for c in 0..<3 {
            for i in 0..<tTotal {
                let v = tPtr[c * tTotal + i] * tScale
                tRgba[i * 4 + c] = UInt8(min(max(v, 0), 255))
            }
        }
        for i in 0..<tTotal { tRgba[i * 4 + 3] = 255 }

        guard let tCtx = CGContext(
            data: &tRgba, width: tw, height: th,
            bitsPerComponent: 8, bytesPerRow: tw * 4,
            space: outColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let tCG = tCtx.makeImage() else { continue }

        // FIXED v2: always skip output padding for super-resolution.
        // The model output at padding positions is a prediction of neighboring
        // tile content — including it causes overlap/stripes with adjacent tiles.
        let outCropX = padding * outputScale
        let outCropY = padding * outputScale
        let validW = min(outPatchSize, (width - col * patchSize) * outputScale)
        let validH = min(outPatchSize, (height - row * patchSize) * outputScale)

        guard validW > 0, validH > 0,
              let croppedTile = tCG.cropping(to: CGRect(x: outCropX, y: outCropY, width: validW, height: validH))
        else { continue }

        let destX = col * outPatchSize
        let destY = row * outPatchSize
        outputCtx.draw(croppedTile, in: CGRect(x: destX, y: destY, width: validW, height: validH))
        print("Tile[\(row),\(col)]: src(\(cropX),\(cropY)) -> out(\(destX),\(destY)) \(validW)x\(validH)")
    }
}

guard let outputCGImage = outputCtx.makeImage() else { fatalError("no final") }

let ciImage = CIImage(cgImage: outputCGImage)
let ciCtx = CIContext()
let outputURL = URL(fileURLWithPath: "/tmp/test_upscale_output_fixed.jpg")
try! ciCtx.writeJPEGRepresentation(of: ciImage, to: outputURL, colorSpace: outColorSpace, options: [:])
print("\nOutput: \(outputWidth)x\(outputHeight)")
print("Saved to /tmp/test_upscale_output_fixed.jpg")

// Verify samples
print("\nVerification:")
guard let outData = outputCtx.data else { fatalError() }
let outPtr = outData.assumingMemoryBound(to: UInt8.self)
let outBytesPerRow = outputWidth * 4
// Input at (x,y): R = x*255/width, G = y*255/height
// Output at (2x, 2y) should be roughly 2x the R/G values (since upscale preserves gradient)
for (label, sx, sy) in [
    ("top-left (should R~16,G~0)", 4, 4),
    ("top-mid (should R~128,G~0)", outputWidth/2, 4),
    ("top-right (should R~248,G~0)", outputWidth-4, 4),
    ("center (should R~128,G~128)", outputWidth/2, outputHeight/2),
    ("bottom-left (should R~16,G~248)", 4, outputHeight-4),
    ("bottom-right (should R~248,G~248)", outputWidth-4, outputHeight-4)
] {
    let off = sy * outBytesPerRow + sx * 4
    let r = outPtr[off], g = outPtr[off+1], b = outPtr[off+2]
    print("  \(label): (\(sx),\(sy)) R=\(r) G=\(g) B=\(b)")
}

print("\nDone!")

func cgImageToPixelBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
    let w = cgImage.width
    let h = cgImage.height
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
    guard let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let c = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: w, height: h,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else { return nil }
    c.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buffer
}

class CoreMLInput: MLFeatureProvider {
    let input: CVPixelBuffer
    var featureNames: Set<String> { ["input"] }
    init(input: CVPixelBuffer) { self.input = input }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        guard featureName == "input" else { return nil }
        return MLFeatureValue(pixelBuffer: input)
    }
}

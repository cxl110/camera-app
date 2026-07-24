import Foundation
import CoreML
import CoreGraphics
import CoreImage

// Test EDSR x2 upscale with a REAL photo to detect tile boundary artifacts.
// Usage: swift test_upscale_real.swift <input.jpg> [output.jpg]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift test_upscale_real.swift <input.jpg> [output.jpg]")
    exit(1)
}

let inputPath = args[1]
let outputPath = args.count >= 3 ? args[2] : "/tmp/test_upscale_real_output.jpg"

// Load input image
let inputURL = URL(fileURLWithPath: inputPath)
guard let inputCI = CIImage(contentsOf: inputURL) else {
    print("ERROR: Cannot load image from \(inputPath)")
    exit(1)
}
let ciCtx = CIContext()
guard let inputCG = ciCtx.createCGImage(inputCI, from: inputCI.extent) else {
    print("ERROR: Cannot create CGImage")
    exit(1)
}

let width = inputCG.width
let height = inputCG.height
print("Input: \(width)x\(height)")

// Load EDSR model
let modelPath = NSHomeDirectory() + "/camera_app/assets/models/edsr_base_x2.mlmodelc"
let modelURL = URL(fileURLWithPath: modelPath)
let config = MLModelConfiguration()
config.computeUnits = .all
let model = try MLModel(contentsOf: modelURL, configuration: config)
print("Model loaded from \(modelPath)")

// Tile parameters
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
let outPatchSize = patchSize * outputScale  // 384

// Create output context (opaque, no alpha)
guard let outputCtx = CGContext(
    data: nil,
    width: outputWidth, height: outputHeight,
    bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
    space: outColorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("output ctx") }

// Process tiles
var tileCount = 0
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
              let patchCGImage = inputCG.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
        else { continue }

        // Pad to effectiveSize with edge color
        let paddedImage: CGImage
        if padL > 0 || padT > 0 || padR > 0 || padB > 0 {
            guard let padCtx = CGContext(
                data: nil,
                width: effectiveSize, height: effectiveSize,
                bitsPerComponent: 8, bytesPerRow: effectiveSize * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            // Fill with edge pixel color
            if let edgeCtx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) {
                edgeCtx.draw(patchCGImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if let edgeData = edgeCtx.data?.assumingMemoryBound(to: UInt8.self) {
                    let r = CGFloat(edgeData[0]) / 255.0
                    let g = CGFloat(edgeData[1]) / 255.0
                    let b = CGFloat(edgeData[2]) / 255.0
                    padCtx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1.0))
                    padCtx.fill(CGRect(x: 0, y: 0, width: effectiveSize, height: effectiveSize))
                }
            }
            padCtx.draw(patchCGImage, in: CGRect(x: padL, y: padT, width: cropW, height: cropH))
            guard let p = padCtx.makeImage() else { continue }
            paddedImage = p
        } else {
            paddedImage = patchCGImage
        }

        // Run model prediction
        guard let tilePB = cgImageToPixelBuffer(paddedImage) else { continue }
        let tileInput = CoreMLInput(input: tilePB)
        let tilePred = try model.prediction(from: tileInput)
        guard let tOutName = tilePred.featureNames.first,
              let tOutVal = tilePred.featureValue(for: tOutName),
              let tArr = tOutVal.multiArrayValue else { continue }

        let th = tArr.shape[2].intValue
        let tw = tArr.shape[3].intValue
        let tPtr = tArr.dataPointer.assumingMemoryBound(to: Float.self)

        // Auto-detect scale
        var tNeedsScale = false
        for i in 0..<min(100, tw*th*3) {
            if tPtr[i] > 2.0 { tNeedsScale = false; break }
            if tPtr[i] <= 1.0 && i == min(100, tw*th*3)-1 { tNeedsScale = true }
        }
        let tScale: Float = tNeedsScale ? 255.0 : 1.0

        // Convert to RGBA
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

        // *** KEY FIX v2: always skip output padding for super-resolution ***
        let outCropX = padding * outputScale  // 32
        let outCropY = padding * outputScale  // 32
        let validW = min(outPatchSize, (width - col * patchSize) * outputScale)
        let validH = min(outPatchSize, (height - row * patchSize) * outputScale)

        guard validW > 0, validH > 0,
              let croppedTile = tCG.cropping(to: CGRect(x: outCropX, y: outCropY, width: validW, height: validH))
        else { continue }

        let destX = col * outPatchSize
        let destY = row * outPatchSize
        outputCtx.draw(croppedTile, in: CGRect(x: destX, y: destY, width: validW, height: validH))
        tileCount += 1
        if tileCount % 10 == 0 { print("  Processed \(tileCount) tiles...") }
    }
}

print("Total tiles: \(tileCount)")

guard let outputCGImage = outputCtx.makeImage() else { fatalError("no final") }

let outputCI = CIImage(cgImage: outputCGImage)
let outputJPEGURL = URL(fileURLWithPath: outputPath)
try! ciCtx.writeJPEGRepresentation(of: outputCI, to: outputJPEGURL, colorSpace: outColorSpace, options: [:])

print("\nOutput: \(outputWidth)x\(outputHeight)")
print("Saved to \(outputPath)")

// ── Boundary verification: check for stripe artifacts ──
// Sample pixels at tile boundaries and compare with interior pixels.
// If there's a visible offset, the difference at boundaries will be much
// larger than the difference between adjacent interior pixels.
print("\n── Tile boundary verification ──")
guard let outData = outputCtx.data else { fatalError() }
let outPtr = outData.assumingMemoryBound(to: UInt8.self)
let outBytesPerRow = outputWidth * 4

func pixelAt(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let off = y * outBytesPerRow + x * 4
    return (outPtr[off], outPtr[off+1], outPtr[off+2])
}

func colorDiff(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
    return abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
}

var maxBoundaryDiff = 0
var maxInteriorDiff = 0
var boundarySamples = 0
var interiorSamples = 0

// Check horizontal boundaries (between tile columns)
for col in 1..<cols {
    let boundaryX = col * outPatchSize  // x=384, 768, ...
    for y in stride(from: 10, to: outputHeight - 10, by: 20) {
        guard boundaryX >= 2 && boundaryX < outputWidth - 2 else { continue }
        let left = pixelAt(boundaryX - 2, y)
        let right = pixelAt(boundaryX + 2, y)
        let diff = colorDiff(left, right)
        if diff > maxBoundaryDiff { maxBoundaryDiff = diff }
        boundarySamples += 1

        // Compare with interior pixels (same distance apart but away from boundary)
        let interiorX = boundaryX + outPatchSize / 2
        guard interiorX >= 2 && interiorX < outputWidth - 2 else { continue }
        let iLeft = pixelAt(interiorX - 2, y)
        let iRight = pixelAt(interiorX + 2, y)
        let iDiff = colorDiff(iLeft, iRight)
        if iDiff > maxInteriorDiff { maxInteriorDiff = iDiff }
        interiorSamples += 1
    }
}

// Check vertical boundaries (between tile rows)
for row in 1..<rows {
    let boundaryY = row * outPatchSize
    for x in stride(from: 10, to: outputWidth - 10, by: 20) {
        guard boundaryY >= 2 && boundaryY < outputHeight - 2 else { continue }
        let top = pixelAt(x, boundaryY - 2)
        let bottom = pixelAt(x, boundaryY + 2)
        let diff = colorDiff(top, bottom)
        if diff > maxBoundaryDiff { maxBoundaryDiff = diff }
        boundarySamples += 1

        let interiorY = boundaryY + outPatchSize / 2
        guard interiorY >= 2 && interiorY < outputHeight - 2 else { continue }
        let iTop = pixelAt(x, interiorY - 2)
        let iBottom = pixelAt(x, interiorY + 2)
        let iDiff = colorDiff(iTop, iBottom)
        if iDiff > maxInteriorDiff { maxInteriorDiff = iDiff }
        interiorSamples += 1
    }
}

print("  Boundary samples: \(boundarySamples), max diff: \(maxBoundaryDiff)")
print("  Interior samples: \(interiorSamples), max diff: \(maxInteriorDiff)")
let ratio = maxInteriorDiff > 0 ? Double(maxBoundaryDiff) / Double(maxInteriorDiff) : 0
print("  Boundary/Interior ratio: \(String(format: "%.2f", ratio))")
if ratio > 3.0 {
    print("  ⚠️  WARNING: Boundary differences are much larger than interior — possible stripe artifacts!")
} else {
    print("  ✅  Boundary differences are similar to interior — no obvious stripe artifacts.")
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

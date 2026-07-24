import Foundation
import CoreML
import CoreGraphics
import CoreImage

// Test EDSR x2 upscale with overlap + feather blending (unified approach).
// Uses synthetic image with high-frequency content (checkerboard, diagonal stripes,
// color blocks, gradient) that exposes tile boundary artifacts.

let width = 2048
let height = 1536
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
var pixelData = [UInt8](repeating: 0, count: width * height * 4)

for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        var r: UInt8, g: UInt8, b: UInt8

        if x < width/2 && y < height/2 {
            let cx = x / 16; let cy = y / 16
            if (cx + cy) % 2 == 0 { r = 255; g = 255; b = 255 } else { r = 0; g = 0; b = 0 }
        } else if x >= width/2 && y < height/2 {
            let stripe = (x + y) / 4
            if stripe % 2 == 0 { r = 255; g = 0; b = 0 } else { r = 0; g = 0; b = 255 }
        } else if x < width/2 && y >= height/2 {
            let bx = (x % 128) / 64; let by = ((y - height/2) % 128) / 64
            let idx = (by * 2 + bx) % 4
            switch idx {
            case 0: r = 255; g = 0; b = 0
            case 1: r = 0; g = 255; b = 0
            case 2: r = 0; g = 0; b = 255
            default: r = 255; g = 255; b = 0
            }
        } else {
            r = UInt8(x * 255 / width); g = UInt8((y - height/2) * 255 / (height/2)); b = 128
        }

        pixelData[offset] = r; pixelData[offset+1] = g; pixelData[offset+2] = b; pixelData[offset+3] = 255
    }
}

guard let ctx = CGContext(
    data: &pixelData, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
), let testCGImage = ctx.makeImage() else { fatalError("create image") }

print("Input: \(width)x\(height)")

// Load EDSR model
let modelPath = NSHomeDirectory() + "/camera_app/assets/models/edsr_base_x2.mlmodelc"
let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: {
    let c = MLModelConfiguration(); c.computeUnits = .all; return c }()
)
print("Model loaded")

let patchSize = 192
let padding = 16
let effectiveSize = patchSize + 2 * padding  // 224
let outputScale = 2
let outPatchSize = patchSize * outputScale    // 384
let outPadding = padding * outputScale        // 32

let cols = Int(ceil(Double(width) / Double(patchSize)))
let rows = Int(ceil(Double(height) / Double(patchSize)))
let outputWidth = width * outputScale
let outputHeight = height * outputScale
let outColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

print("Grid: \(cols)x\(rows) tiles, output: \(outputWidth)x\(outputHeight)")

// premultipliedLast context for feather blending
guard let outputCtx = CGContext(
    data: nil, width: outputWidth, height: outputHeight,
    bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
    space: outColorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("output ctx") }

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
              let patchCGImage = testCGImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
        else { continue }

        // Pad to effectiveSize with edge color
        let paddedImage: CGImage
        if padL > 0 || padT > 0 || padR > 0 || padB > 0 {
            guard let padCtx = CGContext(
                data: nil, width: effectiveSize, height: effectiveSize,
                bitsPerComponent: 8, bytesPerRow: effectiveSize * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
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

        // ── Unified overlap + feather blending ──
        let outCropX = padL * outputScale
        let outCropY = padT * outputScale
        let validOutW = cropW * outputScale
        let validOutH = cropH * outputScale

        guard validOutW > 0, validOutH > 0,
              let croppedTile = tCG.cropping(to: CGRect(x: outCropX, y: outCropY, width: validOutW, height: validOutH))
        else { continue }

        // Destination includes overlap offset
        let destX = col * outPatchSize - outPadding + padL * outputScale
        let destY = row * outPatchSize - outPadding + padT * outputScale

        // Feather blending
        let hasLeft = col > 0
        let hasRight = col < cols - 1
        let hasTop = row > 0
        let hasBottom = row < rows - 1

        let tileToDraw: CGImage
        if hasLeft || hasRight || hasTop || hasBottom {
            tileToDraw = applyFeatherAlpha(
                cgImage: croppedTile, width: validOutW, height: validOutH,
                padding: outPadding,
                left: hasLeft, right: hasRight, top: hasTop, bottom: hasBottom
            ) ?? croppedTile
        } else {
            tileToDraw = croppedTile
        }

        outputCtx.draw(tileToDraw, in: CGRect(x: destX, y: destY, width: validOutW, height: validOutH))
        tileCount += 1
        if tileCount % 20 == 0 { print("  Processed \(tileCount)/\(cols*rows) tiles...") }
    }
}

print("Total tiles: \(tileCount)")

// Flatten alpha
guard let rawOutput = outputCtx.makeImage() else { fatalError("no raw output") }
guard let flatCtx = CGContext(
    data: nil, width: outputWidth, height: outputHeight,
    bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
    space: outColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("flat ctx") }
flatCtx.draw(rawOutput, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
guard let outputCGImage = flatCtx.makeImage() else { fatalError("no final") }

let ciCtx = CIContext()
let outputCI = CIImage(cgImage: outputCGImage)
let outputURL = URL(fileURLWithPath: "/tmp/test_upscale_v3_feather.jpg")
try! ciCtx.writeJPEGRepresentation(of: outputCI, to: outputURL, colorSpace: outColorSpace, options: [:])
print("\nOutput: \(outputWidth)x\(outputHeight)")
print("Saved to /tmp/test_upscale_v3_feather.jpg")

// ── Boundary verification ──
print("\n-- Tile boundary verification --")
guard let outData = flatCtx.data else { fatalError() }
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

for col in 1..<cols {
    let boundaryX = col * outPatchSize
    for y in stride(from: 10, to: outputHeight - 10, by: 20) {
        guard boundaryX >= 2 && boundaryX < outputWidth - 2 else { continue }
        let left = pixelAt(boundaryX - 2, y)
        let right = pixelAt(boundaryX + 2, y)
        let diff = colorDiff(left, right)
        if diff > maxBoundaryDiff { maxBoundaryDiff = diff }
        boundarySamples += 1
        let interiorX = boundaryX + outPatchSize / 2
        guard interiorX >= 2 && interiorX < outputWidth - 2 else { continue }
        let iLeft = pixelAt(interiorX - 2, y)
        let iRight = pixelAt(interiorX + 2, y)
        let iDiff = colorDiff(iLeft, iRight)
        if iDiff > maxInteriorDiff { maxInteriorDiff = iDiff }
        interiorSamples += 1
    }
}
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
let ratioStr = String(format: "%.2f", ratio)
print("  Boundary/Interior ratio: \(ratioStr)")
if ratio > 2.0 {
    print("  WARNING: Boundary differences much larger than interior!")
} else {
    print("  OK: No obvious stripe artifacts at tile boundaries.")
}

print("\nDone!")

// ── Helper functions ──

func cgImageToPixelBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
    let w = cgImage.width; let h = cgImage.height
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
        data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
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

func applyFeatherAlpha(cgImage: CGImage, width: Int, height: Int, padding: Int,
                        left: Bool, right: Bool, top: Bool, bottom: Bool) -> CGImage? {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return nil }
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    let bpr = ctx.bytesPerRow
    let pad = CGFloat(padding)
    for y in 0..<height {
        for x in 0..<width {
            var alpha: CGFloat = 1.0
            if left   { alpha *= min(CGFloat(x), pad) / pad }
            if right  { alpha *= min(CGFloat(width - 1 - x), pad) / pad }
            if top    { alpha *= min(CGFloat(y), pad) / pad }
            if bottom { alpha *= min(CGFloat(height - 1 - y), pad) / pad }
            let a = UInt8(min(max(alpha, 0), 1) * 255)
            let offset = y * bpr + x * 4
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

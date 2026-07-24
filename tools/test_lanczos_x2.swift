import Foundation
import CoreImage
import CoreGraphics
import ImageIO

// Test high-quality Lanczos 2x upscale using CoreImage.
// This is a non-neural approach that produces NO tile artifacts.
// Compare with EDSR x2 neural upscale.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift test_lanczos_x2.swift <input.jpg> [output.jpg]")
    exit(1)
}
let inputPath = args[1]
let outputPath = args.count >= 3 ? args[2] : "/tmp/forTest_lanczos_x2.jpg"

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let inputCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("ERROR: Cannot load \(inputPath)"); exit(1)
}
let width = inputCG.width, height = inputCG.height
print("Input: \(width)x\(height)")

let outputWidth = width * 2
let outputHeight = height * 2
print("Output: \(outputWidth)x\(outputHeight)")

// Method 1: CoreImage Lanczos (high quality, hardware accelerated)
let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
let ciImage = CIImage(cgImage: inputCG)
let lanczosFilter = CIFilter(name: "CILanczosScaleTransform")!
lanczosFilter.setValue(ciImage, forKey: kCIInputImageKey)
lanczosFilter.setValue(2.0, forKey: kCIInputScaleKey)

guard let lanczosOutput = lanczosFilter.outputImage else {
    print("ERROR: Lanczos filter failed"); exit(1)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let lanczosCG = ciCtx.createCGImage(lanczosOutput, from: lanczosOutput.extent, format: .RGBA8, colorSpace: cs) else {
    print("ERROR: Cannot create CGImage from Lanczos output"); exit(1)
}

print("Lanczos output: \(lanczosCG.width)x\(lanczosCG.height)")

// Save as JPEG
try! ciCtx.writeJPEGRepresentation(of: CIImage(cgImage: lanczosCG),
    to: URL(fileURLWithPath: outputPath), colorSpace: cs)
print("Saved to \(outputPath)")

// Method 2: Also test CGImage bicubic for comparison
let bicubicPath = outputPath.replacingOccurrences(of: ".jpg", with: "_bicubic.jpg")
guard let bicubicCtx = CGContext(data: nil, width: outputWidth, height: outputHeight,
    bitsPerComponent: 8, bytesPerRow: outputWidth * 4, space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    print("ERROR: Cannot create bicubic context"); exit(1)
}
bicubicCtx.interpolationQuality = .high // bicubic
bicubicCtx.draw(inputCG, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
guard let bicubicCG = bicubicCtx.makeImage() else {
    print("ERROR: Cannot create bicubic output"); exit(1)
}
try! ciCtx.writeJPEGRepresentation(of: CIImage(cgImage: bicubicCG),
    to: URL(fileURLWithPath: bicubicPath), colorSpace: cs)
print("Bicubic saved to \(bicubicPath)")

// Compare file sizes
let lanczosAttr = try! FileManager.default.attributesOfItem(atPath: outputPath)
let bicubicAttr = try! FileManager.default.attributesOfItem(atPath: bicubicPath)
let lanczosSize = lanczosAttr[.size] as! UInt64
let bicubicSize = bicubicAttr[.size] as! UInt64
print("Lanczos file size: \(lanczosSize) bytes")
print("Bicubic file size: \(bicubicSize) bytes")

// Quality check: compare a few pixels at tile boundaries (where EDSR has problems)
// For a 2048x1536 input with patchSize=192, tile boundaries are at x=384,768,1152,1536,1920,2304,2688,3072,3456,3840
// and y=384,768,1152,1536,1920,2304,2688,3072
// Check if Lanczos has any discontinuities at these positions
var maxDiff = 0
let lanczosData = UnsafeMutablePointer<UInt8>.allocate(capacity: outputWidth * outputHeight * 4)
guard let checkCtx = CGContext(data: lanczosData, width: outputWidth, height: outputHeight,
    bitsPerComponent: 8, bytesPerRow: outputWidth * 4, space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(0) }
checkCtx.draw(lanczosCG, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

// Check at EDSR tile boundary positions (output space)
let patchSize = 192
let outPatchSize = patchSize * 2  // 384
for col in 1..<11 {
    let bx = col * outPatchSize
    if bx >= 2 && bx < outputWidth - 2 {
        for y in stride(from: 10, to: outputHeight-10, by: 20) {
            let i1 = (y * outputWidth + bx - 2) * 4
            let i2 = (y * outputWidth + bx + 2) * 4
            let d = abs(Int(lanczosData[i1]) - Int(lanczosData[i2])) +
                    abs(Int(lanczosData[i1+1]) - Int(lanczosData[i2+1])) +
                    abs(Int(lanczosData[i1+2]) - Int(lanczosData[i2+2]))
            if d > maxDiff { maxDiff = d }
        }
    }
}
for row in 1..<8 {
    let by = row * outPatchSize
    if by >= 2 && by < outputHeight - 2 {
        for x in stride(from: 10, to: outputWidth-10, by: 20) {
            let i1 = ((by-2) * outputWidth + x) * 4
            let i2 = ((by+2) * outputWidth + x) * 4
            let d = abs(Int(lanczosData[i1]) - Int(lanczosData[i2])) +
                    abs(Int(lanczosData[i1+1]) - Int(lanczosData[i2+1])) +
                    abs(Int(lanczosData[i1+2]) - Int(lanczosData[i2+2]))
            if d > maxDiff { maxDiff = d }
        }
    }
}
print("Lanczos max boundary diff: \(maxDiff) (should be very small, no tile artifacts)")
print("Done!")

import Foundation
import CoreML
import CoreGraphics
import CoreImage
import ImageIO

// Test PiperSR 2x upscale model.
// PiperSR is a lightweight (453K params, 928KB) ANE-native super-resolution model.
// Key advantage: supports flexible input sizes, no tile boundary artifacts.
//
// Usage: swift test_pipersr.swift <input.jpg> [output.jpg]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift test_pipersr.swift <input.jpg> [output.jpg]")
    exit(1)
}
let inputPath = args[1]
let outputPath = args.count >= 3 ? args[2] : "/tmp/forTest_pipersr_x2.jpg"

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let inputCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("ERROR: Cannot load \(inputPath)"); exit(1)
}
let width = inputCG.width, height = inputCG.height
print("Input: \(width)x\(height)")

// Try to load PiperSR model
let modelSearchPaths = [
    "/tmp/PiperSR/PiperSR_2x.mlpackage",
    NSHomeDirectory() + "/.cache/pipersr/PiperSR_2x.mlpackage",
    NSHomeDirectory() + "/camera_app/assets/models/PiperSR_2x.mlpackage",
]

var model: MLModel?
var modelPath: String?

for path in modelSearchPaths {
    let url = URL(fileURLWithPath: path)
    // Check if path exists
    if FileManager.default.fileExists(atPath: path) {
        print("Found model at: \(path)")
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: url, configuration: config)
            modelPath = path
            print("Model loaded successfully!")
            break
        } catch {
            print("Failed to load from \(path): \(error)")
        }
    }
}

// Also try .mlmodelc (compiled) format
if model == nil {
    for path in modelSearchPaths.map({ $0.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc") }) {
        if FileManager.default.fileExists(atPath: path) {
            print("Found compiled model at: \(path)")
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                model = try MLModel(contentsOf: URL(fileURLWithPath: path), configuration: config)
                modelPath = path
                print("Model loaded successfully!")
                break
            } catch {
                print("Failed to load from \(path): \(error)")
            }
        }
    }
}

// Also try compiling .mlpackage to .mlmodelc at runtime
if model == nil {
    for path in modelSearchPaths {
        if FileManager.default.fileExists(atPath: path) {
            print("Trying to compile .mlpackage at runtime...")
            if #available(iOS 16.0, macOS 13.0, *) {
                do {
                    let compiledURL = try MLModel.compileModel(at: URL(fileURLWithPath: path))
                    print("Compiled to: \(compiledURL.path)")
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine
                    model = try MLModel(contentsOf: compiledURL, configuration: config)
                    modelPath = path
                    print("Model loaded after compilation!")
                    break
                } catch {
                    print("Compile failed: \(error)")
                }
            }
        }
    }
}

guard let mlModel = model else {
    print("ERROR: Could not load PiperSR model from any path")
    print("Searched: \(modelSearchPaths.joined(separator: ", "))")

    // Fallback: test with CILanczosScaleTransform
    print("\n--- Fallback: CILanczosScaleTransform (Lanczos 2x) ---")
    let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
    let ciImage = CIImage(cgImage: inputCG)
    let lanczosFilter = CIFilter(name: "CILanczosScaleTransform")!
    lanczosFilter.setValue(ciImage, forKey: kCIInputImageKey)
    lanczosFilter.setValue(2.0, forKey: kCIInputScaleKey)

    guard let lanczosOutput = lanczosFilter.outputImage,
          let lanczosCG = ciCtx.createCGImage(lanczosOutput, from: lanczosOutput.extent,
                                               format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
        print("ERROR: Lanczos failed too"); exit(1)
    }

    print("Lanczos output: \(lanczosCG.width)x\(lanczosCG.height)")
    try! ciCtx.writeJPEGRepresentation(of: CIImage(cgImage: lanczosCG),
        to: URL(fileURLWithPath: outputPath), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("Saved to \(outputPath)")
    print("Done (Lanczos fallback)!")
    exit(0)
}

// Print model info
let spec = mlModel.modelDescription
print("Model inputs:")
for input in spec.inputDescriptionsByName {
    print("  \(input.key): \(input.value.type)")
}
print("Model outputs:")
for output in spec.outputDescriptionsByName {
    print("  \(output.key): \(output.value.type)")
}

// Get tile size from model spec
let tileSize: Int
if let multiArray = spec.inputDescriptionsByName.first?.value.multiArrayConstraint {
    let shape = multiArray.shape
    if shape.count >= 3 {
        tileSize = shape[1].intValue > 0 ? shape[1].intValue : 128
    } else {
        tileSize = 128
    }
    print("Model input shape: \(shape), using tile size: \(tileSize)")
} else {
    tileSize = 128
    print("Unknown input type, defaulting to tile size: \(tileSize)")
}

let outputScale = 2
let outputWidth = width * outputScale
let outputHeight = height * outputScale
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

print("Output: \(outputWidth)x\(outputHeight)")

// ── PiperSR tiling: no overlap, direct paste ──
// Pad image to tile size multiple
let padW = (tileSize - width % tileSize) % tileSize
let padH = (tileSize - height % tileSize) % tileSize
let canvasW = width + padW
let canvasH = height + padH

// Create padded canvas
var canvasData = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
guard let canvasCtx = CGContext(data: &canvasData, width: canvasW, height: canvasH,
    bitsPerComponent: 8, bytesPerRow: canvasW * 4, space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("canvas ctx") }
canvasCtx.draw(inputCG, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

// Create output canvas
var outData = [UInt8](repeating: 0, count: canvasW * outputScale * canvasH * outputScale * 4)
guard let outCtx = CGContext(data: &outData, width: canvasW * outputScale, height: canvasH * outputScale,
    bitsPerComponent: 8, bytesPerRow: canvasW * outputScale * 4, space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("out ctx") }

let cols = canvasW / tileSize
let rows = canvasH / tileSize
let totalTiles = cols * rows
var tileCount = 0

let startTime = CFAbsoluteTimeGetCurrent()

for row in 0..<rows {
    for col in 0..<cols {
        let srcX = col * tileSize
        let srcY = row * tileSize

        // Extract tile as CVPixelBuffer
        guard let tileCG = inputCG.cropping(to: CGRect(x: srcX, y: srcY, width: tileSize, height: tileSize)) else { continue }

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, tileSize, tileSize, kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buf = pb else { continue }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: tileSize, height: tileSize,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { continue }
        c.draw(tileCG, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))

        // Run inference
        let input = CoreMLInput(input: buf)
        guard let pred = try? mlModel.prediction(from: input) else {
            print("ERROR: prediction failed for tile (\(col),\(row))")
            continue
        }

        // Get output
        guard let outName = pred.featureNames.first,
              let outVal = pred.featureValue(for: outName) else { continue }

        var tileOutCG: CGImage?
        if let arr = outVal.multiArrayValue {
            let th = arr.shape[2].intValue, tw = arr.shape[3].intValue
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
            var ns = false
            for i in 0..<min(100, tw*th*3) { if ptr[i] > 2.0 { ns = false; break }; if ptr[i] <= 1.0 && i == min(100, tw*th*3)-1 { ns = true } }
            let sc: Float = ns ? 255 : 1
            var rgba = [UInt8](repeating: 0, count: tw*th*4)
            for ch in 0..<3 { for i in 0..<(tw*th) { rgba[i*4+ch] = UInt8(min(max(ptr[ch*tw*th+i]*sc, 0), 255)) } }
            for i in 0..<(tw*th) { rgba[i*4+3] = 255 }
            guard let tc = CGContext(data: &rgba, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw*4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let timg = tc.makeImage()
            else { continue }
            tileOutCG = timg
        } else if let pb = outVal.imageBufferValue {
            let ciImg = CIImage(cvPixelBuffer: pb)
            let ciCtx = CIContext()
            tileOutCG = ciCtx.createCGImage(ciImg, from: ciImg.extent)
        }

        guard let outCG = tileOutCG else { continue }

        // Direct paste into output canvas (no blending!)
        let destX = srcX * outputScale
        let destY = srcY * outputScale
        outCtx.draw(outCG, in: CGRect(x: destX, y: destY, width: outCG.width, height: outCG.height))

        tileCount += 1
        if tileCount % 10 == 0 { print("  Tile \(tileCount)/\(totalTiles)") }
    }
}

let elapsed = CFAbsoluteTimeGetCurrent() - startTime
print("All \(tileCount) tiles done in \(String(format: "%.2f", elapsed))s")

// Crop to original size (remove padding)
guard let fullOut = outCtx.makeImage(),
      let finalOut = fullOut.cropping(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
else { print("ERROR: final crop failed"); exit(1) }

// Save
let ciCtx = CIContext()
try! ciCtx.writeJPEGRepresentation(of: CIImage(cgImage: finalOut),
    to: URL(fileURLWithPath: outputPath), colorSpace: cs)
print("Saved to \(outputPath)")
print("Output: \(finalOut.width)x\(finalOut.height)")

// ── Boundary check ──
// Check for discontinuities at tile boundaries
var maxBd = 0, maxIn = 0
func pdiff(_ o1: Int, _ o2: Int) -> Int {
    abs(Int(outData[o1*4])-Int(outData[o2*4])) + abs(Int(outData[o1*4+1])-Int(outData[o2*4+1])) + abs(Int(outData[o1*4+2])-Int(outData[o2*4+2]))
}
let outW = canvasW * outputScale
for c in 1..<cols {
    let bx = c * tileSize * outputScale
    for y in stride(from: 10, to: outputHeight-10, by: 20) {
        if bx >= 2 && bx < outputWidth-2 { let d = pdiff((bx-2)+y*outW, (bx+2)+y*outW); if d>maxBd { maxBd=d } }
        let ix = bx + tileSize
        if ix >= 2 && ix < outputWidth-2 { let d = pdiff((ix-2)+y*outW, (ix+2)+y*outW); if d>maxIn { maxIn=d } }
    }
}
for r in 1..<rows {
    let by = r * tileSize * outputScale
    for x in stride(from: 10, to: outputWidth-10, by: 20) {
        if by >= 2 && by < outputHeight-2 { let d = pdiff(x+(by-2)*outW, x+(by+2)*outW); if d>maxBd { maxBd=d } }
        let iy = by + tileSize
        if iy >= 2 && iy < outputHeight-2 { let d = pdiff(x+(iy-2)*outW, x+(iy+2)*outW); if d>maxIn { maxIn=d } }
    }
}
let ratio = maxIn > 0 ? Double(maxBd)/Double(maxIn) : 0
let ratioStr = String(format: "%.2f", ratio)
print("Boundary max: \(maxBd), Interior max: \(maxIn), Ratio: \(ratioStr)")
print(ratio > 2.0 ? "WARNING: visible tile boundaries" : "OK: no visible tile boundaries")
print("Done!")

class CoreMLInput: MLFeatureProvider {
    let input: CVPixelBuffer
    var featureNames: Set<String> { ["input"] }
    init(input: CVPixelBuffer) { self.input = input }
    func featureValue(for name: String) -> MLFeatureValue? { name == "input" ? MLFeatureValue(pixelBuffer: input) : nil }
}

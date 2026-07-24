import Foundation
import CoreML
import CoreGraphics
import CoreImage

// Test EDSR x2 upscale with sigmoid weight-map blending (matching CoreMLPlugin.swift).
// Each tile's contribution is weighted by sigmoid_x(x) * sigmoid_y(y).
// Weights sum to 1.0 across all tiles covering a pixel → no dark seams.

let args = CommandLine.arguments
guard args.count >= 2 else { print("Usage: swift test_sigmoid.swift <input.jpg> [output.jpg]"); exit(1) }
let inputPath = args[1]
let outputPath = args.count >= 3 ? args[2] : "/tmp/forTest_upscale_sigmoid.jpg"

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let inputCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("ERROR: Cannot load \(inputPath)"); exit(1)
}
let width = inputCG.width, height = inputCG.height
print("Input: \(width)x\(height)")

let model = try MLModel(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/camera_app/assets/models/edsr_base_x2.mlmodelc"), configuration: { let c = MLModelConfiguration(); c.computeUnits = .all; return c }())
print("Model loaded")

let patchSize = 192, padding = 16
let effectiveSize = patchSize + 2 * padding
let outputScale = 2
let outPatchSize = patchSize * outputScale    // 384
let outPadding = padding * outputScale        // 32
let outputWidth = width * outputScale
let outputHeight = height * outputScale
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

print("Grid: \(Int(ceil(Double(width)/Double(patchSize))))x\(Int(ceil(Double(height)/Double(patchSize))))")
print("Output: \(outputWidth)x\(outputHeight)")

// ── Helper: sigmoid weight ──
func sigmoidW(_ t: Float) -> Float {
    let x = 12.0 * (t - 0.5)
    if x > 20 { return 1.0 }; if x < -20 { return 0.0 }
    return 1.0 / (1.0 + expf(-x))
}

// ── Run one tile ──
func runTile(col: Int, row: Int) -> (CGImage?, Int, Int) {
    let srcX = col * patchSize - padding
    let srcY = row * patchSize - padding
    let padL = max(0, -srcX), padT = max(0, -srcY)
    let padR = max(0, srcX + effectiveSize - width), padB = max(0, srcY + effectiveSize - height)
    let cropW = effectiveSize - padL - padR, cropH = effectiveSize - padT - padB
    guard cropW > 0, cropH > 0,
          let patch = inputCG.cropping(to: CGRect(x: srcX+padL, y: srcY+padT, width: cropW, height: cropH))
    else { return (nil, 0, 0) }

    let padded: CGImage
    if padL>0||padT>0||padR>0||padB>0 {
        guard let pc = CGContext(data: nil, width: effectiveSize, height: effectiveSize,
            bitsPerComponent: 8, bytesPerRow: effectiveSize*4, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (nil, 0, 0) }
        if let ec = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ec.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if let ed = ec.data?.assumingMemoryBound(to: UInt8.self) {
                pc.setFillColor(CGColor(red: CGFloat(ed[0])/255, green: CGFloat(ed[1])/255, blue: CGFloat(ed[2])/255, alpha: 1))
                pc.fill(CGRect(x: 0, y: 0, width: effectiveSize, height: effectiveSize))
            }
        }
        pc.draw(patch, in: CGRect(x: padL, y: padT, width: cropW, height: cropH))
        guard let p = pc.makeImage() else { return (nil, 0, 0) }; padded = p
    } else { padded = patch }

    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, effectiveSize, effectiveSize, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
    guard let buf = pb else { return (nil, 0, 0) }
    CVPixelBufferLockBaseAddress(buf, []); defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: effectiveSize, height: effectiveSize, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return (nil, 0, 0) }
    c.draw(padded, in: CGRect(x: 0, y: 0, width: effectiveSize, height: effectiveSize))

    guard let pred = try? model.prediction(from: CoreMLInput(input: buf)),
          let nm = pred.featureNames.first, let fv = pred.featureValue(for: nm),
          let arr = fv.multiArrayValue else { return (nil, 0, 0) }
    let th = arr.shape[2].intValue, tw = arr.shape[3].intValue
    let tPtr = arr.dataPointer.assumingMemoryBound(to: Float.self)

    var ns = false
    for i in 0..<min(100, tw*th*3) { if tPtr[i] > 2.0 { ns = false; break }; if tPtr[i] <= 1.0 && i == min(100, tw*th*3)-1 { ns = true } }
    let sc: Float = ns ? 255 : 1
    var rgba = [UInt8](repeating: 0, count: tw*th*4)
    for c in 0..<3 { for i in 0..<(tw*th) { rgba[i*4+c] = UInt8(min(max(tPtr[c*tw*th+i]*sc, 0), 255)) } }
    for i in 0..<(tw*th) { rgba[i*4+3] = 255 }
    guard let tc = CGContext(data: &rgba, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw*4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let tcg = tc.makeImage()
    else { return (nil, 0, 0) }

    let ocx = padL * outputScale, ocy = padT * outputScale
    let vow = cropW * outputScale, voh = cropH * outputScale
    guard vow > 0, voh > 0, let cropped = tcg.cropping(to: CGRect(x: ocx, y: ocy, width: vow, height: voh))
    else { return (nil, 0, 0) }

    return (cropped, vow, voh)
}

// ── Run all tiles ──
let cols = Int(ceil(Double(width) / Double(patchSize)))
let rows = Int(ceil(Double(height) / Double(patchSize)))
let totalTiles = cols * rows

var tiles: [(cg: CGImage, w: Int, h: Int, destX: Int, destY: Int)] = []
for row in 0..<rows {
    for col in 0..<cols {
        let (cg, tw, th) = runTile(col: col, row: row)
        guard let t = cg else { continue }
        let dx = col * outPatchSize - outPadding
        let dy = row * outPatchSize - outPadding
        tiles.append((t, tw, th, dx, dy))
        if tiles.count % 10 == 0 { print("  Tile \(tiles.count)/\(totalTiles)") }
    }
}
print("All \(tiles.count) tiles done")

// ── Accumulate with sigmoid weights ──
let accR = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
let accG = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
let accB = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
let accW = UnsafeMutablePointer<Float>.allocate(capacity: outputWidth * outputHeight)
accR.initialize(repeating: 0, count: outputWidth * outputHeight)
accG.initialize(repeating: 0, count: outputWidth * outputHeight)
accB.initialize(repeating: 0, count: outputWidth * outputHeight)
accW.initialize(repeating: 0, count: outputWidth * outputHeight)
defer { accR.deallocate(); accG.deallocate(); accB.deallocate(); accW.deallocate() }

for (idx, tile) in tiles.enumerated() {
    let col = idx % cols, row = idx / cols
    var tBytes = [UInt8](repeating: 0, count: tile.w * tile.h * 4)
    guard let tc = CGContext(data: &tBytes, width: tile.w, height: tile.h, bitsPerComponent: 8, bytesPerRow: tile.w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
    tc.draw(tile.cg, in: CGRect(x: 0, y: 0, width: tile.w, height: tile.h))

    for ty in 0..<tile.h {
        let oy = tile.destY + ty
        if oy < 0 || oy >= outputHeight { continue }
        // vertical weight: sigmoid fade at top/bottom edges
        var wy: Float = 1.0
        if row > 0 && ty < outPadding { wy = sigmoidW(Float(ty) / Float(outPadding)) }
        if row < rows-1 && ty >= tile.h - outPadding {
            let t = Float(ty - (tile.h - outPadding)) / Float(outPadding)
            wy = 1.0 - sigmoidW(t)
        }

        for tx in 0..<tile.w {
            let ox = tile.destX + tx
            if ox < 0 || ox >= outputWidth { continue }
            // horizontal weight: sigmoid fade at left/right edges
            var wx: Float = 1.0
            if col > 0 && tx < outPadding { wx = sigmoidW(Float(tx) / Float(outPadding)) }
            if col < cols-1 && tx >= tile.w - outPadding {
                let t = Float(tx - (tile.w - outPadding)) / Float(outPadding)
                wx = 1.0 - sigmoidW(t)
            }

            let weight = wx * wy
            let tOff = ty * tile.w * 4 + tx * 4
            let accOff = oy * outputWidth + ox

            accR[accOff] += Float(tBytes[tOff]) * weight
            accG[accOff] += Float(tBytes[tOff+1]) * weight
            accB[accOff] += Float(tBytes[tOff+2]) * weight
            accW[accOff] += weight
        }
    }
    if (idx+1) % 10 == 0 { print("  Blend \(idx+1)/\(tiles.count)") }
}
print("Blending done")

// ── Normalize and write ──
guard let outCtx = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: outputWidth * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let outData = outCtx.data else { fatalError("no ctx") }
let outPtr = outData.assumingMemoryBound(to: UInt8.self)
for i in 0..<(outputWidth * outputHeight) {
    let w = accW[i]
    if w > 0.0001 {
        outPtr[i*4]   = UInt8(min(max(accR[i]/w, 0), 255))
        outPtr[i*4+1] = UInt8(min(max(accG[i]/w, 0), 255))
        outPtr[i*4+2] = UInt8(min(max(accB[i]/w, 0), 255))
    }
    outPtr[i*4+3] = 255
}

guard let final = outCtx.makeImage() else { fatalError("no final") }
let ciCtx = CIContext()
try! ciCtx.writeJPEGRepresentation(of: CIImage(cgImage: final), to: URL(fileURLWithPath: outputPath), colorSpace: cs)
print("Saved to \(outputPath)")
print("Output: \(outputWidth)x\(outputHeight)")

// ── Boundary check ──
var maxBd = 0, maxIn = 0
func pdiff(_ o1: Int, _ o2: Int) -> Int { abs(Int(outPtr[o1*4])-Int(outPtr[o2*4])) + abs(Int(outPtr[o1*4+1])-Int(outPtr[o2*4+1])) + abs(Int(outPtr[o1*4+2])-Int(outPtr[o2*4+2])) }
for c in 1..<cols {
    let bx = c * outPatchSize
    for y in stride(from: 10, to: outputHeight-10, by: 20) {
        if bx>=2 && bx<outputWidth-2 { let d = pdiff((bx-2)+y*outputWidth, (bx+2)+y*outputWidth); if d>maxBd { maxBd=d } }
        let ix = bx + outPatchSize/2
        if ix>=2 && ix<outputWidth-2 { let d = pdiff((ix-2)+y*outputWidth, (ix+2)+y*outputWidth); if d>maxIn { maxIn=d } }
    }
}
for r in 1..<rows {
    let by = r * outPatchSize
    for x in stride(from: 10, to: outputWidth-10, by: 20) {
        if by>=2 && by<outputHeight-2 { let d = pdiff(x+(by-2)*outputWidth, x+(by+2)*outputWidth); if d>maxBd { maxBd=d } }
        let iy = by + outPatchSize/2
        if iy>=2 && iy<outputHeight-2 { let d = pdiff(x+(iy-2)*outputWidth, x+(iy+2)*outputWidth); if d>maxIn { maxIn=d } }
    }
}
let ratio = maxIn > 0 ? Double(maxBd)/Double(maxIn) : 0
let ratioStr = String(format: "%.2f", ratio)
print("Boundary max: \(maxBd), Interior max: \(maxIn), Ratio: \(ratioStr)")
print(ratio > 2.0 ? "WARNING" : "OK")
print("Done!")

class CoreMLInput: MLFeatureProvider {
    let input: CVPixelBuffer
    var featureNames: Set<String> { ["input"] }
    init(input: CVPixelBuffer) { self.input = input }
    func featureValue(for name: String) -> MLFeatureValue? { name == "input" ? MLFeatureValue(pixelBuffer: input) : nil }
}

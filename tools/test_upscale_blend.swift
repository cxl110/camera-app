import Foundation
import CoreML
import CoreGraphics
import CoreImage

// Test EDSR x2 upscale with pixel-level weighted blending (NOT alpha feather).
// The new approach: draw each tile's center content directly, then for overlap
// strips, compute weighted average of adjacent tiles' predictions pixel-by-pixel
// so weights always sum to 1.0 — no dark seams.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift test_upscale_blend.swift <input.jpg> [output.jpg]")
    exit(1)
}
let inputPath = args[1]
let outputPath = args.count >= 3 ? args[2] : "/tmp/forTest_upscale_blend.jpg"

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let inputCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("ERROR: Cannot load \(inputPath)"); exit(1)
}
let width = inputCG.width, height = inputCG.height
print("Input: \(width)x\(height)")

let model = try MLModel(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/camera_app/assets/models/edsr_base_x2.mlmodelc"), configuration: { let c = MLModelConfiguration(); c.computeUnits = .all; return c }())
print("Model loaded")

let patchSize = 192, padding = 16
let effectiveSize = patchSize + 2 * padding  // 224
let outputScale = 2
let outPatchSize = patchSize * outputScale    // 384
let outPadding = padding * outputScale        // 32

let cols = Int(ceil(Double(width) / Double(patchSize)))
let rows = Int(ceil(Double(height) / Double(patchSize)))
let outW = width * outputScale, outH = height * outputScale
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

print("Grid: \(cols)x\(rows), output: \(outW)x\(outH)")

// opaque output canvas
guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                          bytesPerRow: outW * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("ctx") }

// ── Phase 1: draw each tile's center content ──
// Store full tile outputs for later blending
struct TileData {
    let cg: CGImage   // full model output (cropW*2 x cropH*2)
    let contentW: Int // content width in output pixels
    let contentH: Int
    let padL: Int, padT: Int
    let col: Int, row: Int
}
var tiles: [TileData] = []

for row in 0..<rows {
    for col in 0..<cols {
        let (tileCG, contentW, contentH, padL, padT) = try runTile(
            inputCG: inputCG, model: model,
            col: col, row: row, width: width, height: height,
            patchSize: patchSize, padding: padding,
            effectiveSize: effectiveSize, outputScale: outputScale
        )
        guard let t = tileCG else { continue }

        tiles.append(TileData(cg: t, contentW: contentW, contentH: contentH,
                              padL: padL, padT: padT, col: col, row: row))

        // Draw center content (skip overlap padding)
        let destX = col * outPatchSize
        let destY = row * outPatchSize
        if let content = t.cropping(to: CGRect(x: outPadding, y: outPadding,
                                               width: contentW, height: contentH)) {
            ctx.draw(content, in: CGRect(x: destX, y: destY, width: contentW, height: contentH))
        }
        if tiles.count % 10 == 0 { print("  Phase 1: \(tiles.count)/\(cols*rows) tiles") }
    }
}
print("Phase 1 done: \(tiles.count) tiles drawn")

// ── Phase 2: pixel-level weighted blend in overlap strips ──
for tile in tiles {
    let destX = tile.col * outPatchSize
    let destY = tile.row * outPatchSize

    // Left overlap: this tile contributes to strip [destX-outPadding, destX)
    if tile.col > 0 && tile.padL == 0,
       let strip = tile.cg.cropping(to: CGRect(x: 0, y: outPadding,
                                               width: outPadding, height: tile.contentH)) {
        blendStrip(ctx: ctx, strip: strip,
                   destX: destX - outPadding, destY: destY,
                   w: outPadding, h: tile.contentH,
                   rampDir: 1)  // weight 0→1 (this is the RIGHT tile)
    }

    // Right overlap: [destX+contentW, destX+contentW+outPadding)
    let fullOutW = (effectiveSize - tile.padL - max(0, (tile.col * patchSize - padding + effectiveSize) - width)) * outputScale
    if tile.col < cols - 1 && fullOutW == effectiveSize * outputScale,
       let strip = tile.cg.cropping(to: CGRect(x: outPadding + tile.contentW, y: outPadding,
                                               width: outPadding, height: tile.contentH)) {
        blendStrip(ctx: ctx, strip: strip,
                   destX: destX + tile.contentW, destY: destY,
                   w: outPadding, h: tile.contentH,
                   rampDir: -1)  // weight 1→0 (this is the LEFT tile)
    }

    // Top overlap
    if tile.row > 0 && tile.padT == 0,
       let strip = tile.cg.cropping(to: CGRect(x: outPadding, y: 0,
                                               width: tile.contentW, height: outPadding)) {
        blendStrip(ctx: ctx, strip: strip,
                   destX: destX, destY: destY - outPadding,
                   w: tile.contentW, h: outPadding,
                   rampDir: 1)
    }

    // Bottom overlap
    let fullOutH = (effectiveSize - tile.padT - max(0, (tile.row * patchSize - padding + effectiveSize) - height)) * outputScale
    if tile.row < rows - 1 && fullOutH == effectiveSize * outputScale,
       let strip = tile.cg.cropping(to: CGRect(x: outPadding, y: outPadding + tile.contentH,
                                               width: tile.contentW, height: outPadding)) {
        blendStrip(ctx: ctx, strip: strip,
                   destX: destX, destY: destY + tile.contentH,
                   w: tile.contentW, h: outPadding,
                   rampDir: -1)
    }
}
print("Phase 2 done: overlap strips blended")

guard let final = ctx.makeImage() else { fatalError("no output") }
let ciCtx = CIContext()
try! ciCtx.writeJPEGRepresentation(of: CIImage(cgImage: final),
    to: URL(fileURLWithPath: outputPath), colorSpace: cs)
print("Saved to \(outputPath)")
print("Output: \(outW)x\(outH)")

// ── Boundary check ──
guard let d = ctx.data else { exit(0) }
let p = d.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow
var maxBd = 0, maxIn = 0
func diff(_ a: Int, _ b: Int) -> Int {
    let o1 = (a/outPatchSize)*bpr + (a%outPatchSize)*4
    let o2 = (b/outPatchSize)*bpr + (b%outPatchSize)*4
    return abs(Int(p[o1])-Int(p[o2]))+abs(Int(p[o1+1])-Int(p[o2+1]))+abs(Int(p[o1+2])-Int(p[o2+2]))
}
for c in 1..<cols {
    let bx = c * outPatchSize
    for y in stride(from: 10, to: outH-10, by: 20) {
        if bx>=2 && bx<outW-2 { let d=diff(bx-2+y*outW, bx+2+y*outW); if d>maxBd { maxBd=d } }
        let ix = bx + outPatchSize/2
        if ix>=2 && ix<outW-2 { let d=diff(ix-2+y*outW, ix+2+y*outW); if d>maxIn { maxIn=d } }
    }
}
for r in 1..<rows {
    let by = r * outPatchSize
    for x in stride(from: 10, to: outW-10, by: 20) {
        if by>=2 && by<outH-2 { let d=diff(x+(by-2)*outW, x+(by+2)*outW); if d>maxBd { maxBd=d } }
        let iy = by + outPatchSize/2
        if iy>=2 && iy<outH-2 { let d=diff(x+(iy-2)*outW, x+(iy+2)*outW); if d>maxIn { maxIn=d } }
    }
}
let ratio = maxIn>0 ? Double(maxBd)/Double(maxIn) : 0
let ratioStr = String(format: "%.2f", ratio)
print("Boundary max: \(maxBd), Interior max: \(maxIn), Ratio: \(ratioStr)")
print(ratio > 2.0 ? "WARNING" : "OK")

print("Done!")

// ── Helpers ──

func runTile(inputCG: CGImage, model: MLModel,
             col: Int, row: Int, width: Int, height: Int,
             patchSize: Int, padding: Int, effectiveSize: Int, outputScale: Int) throws -> (CGImage?, Int, Int, Int, Int) {
    let srcX = col * patchSize - padding
    let srcY = row * patchSize - padding
    let padL = max(0, -srcX), padT = max(0, -srcY)
    let padR = max(0, srcX+effectiveSize-width), padB = max(0, srcY+effectiveSize-height)
    let cropW = effectiveSize - padL - padR, cropH = effectiveSize - padT - padB
    guard cropW>0, cropH>0, let patch = inputCG.cropping(to: CGRect(x: srcX+padL, y: srcY+padT, width: cropW, height: cropH))
    else { return (nil, 0, 0, 0, 0) }

    let padded: CGImage
    if padL>0||padT>0||padR>0||padB>0 {
        guard let pc = CGContext(data: nil, width: effectiveSize, height: effectiveSize, bitsPerComponent: 8, bytesPerRow: effectiveSize*4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return (nil, 0, 0, 0, 0) }
        if let ec = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ec.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if let ed = ec.data?.assumingMemoryBound(to: UInt8.self) {
                pc.setFillColor(CGColor(red: CGFloat(ed[0])/255, green: CGFloat(ed[1])/255, blue: CGFloat(ed[2])/255, alpha: 1))
                pc.fill(CGRect(x: 0, y: 0, width: effectiveSize, height: effectiveSize))
            }
        }
        pc.draw(patch, in: CGRect(x: padL, y: padT, width: cropW, height: cropH))
        guard let p = pc.makeImage() else { return (nil, 0, 0, 0, 0) }
        padded = p
    } else { padded = patch }

    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, effectiveSize, effectiveSize, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
    guard let buf = pb else { return (nil, 0, 0, 0, 0) }
    CVPixelBufferLockBaseAddress(buf, []); defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: effectiveSize, height: effectiveSize, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return (nil, 0, 0, 0, 0) }
    c.draw(padded, in: CGRect(x: 0, y: 0, width: effectiveSize, height: effectiveSize))

    let pred = try model.prediction(from: CoreMLInput(input: buf))
    guard let nm = pred.featureNames.first, let fv = pred.featureValue(for: nm), let arr = fv.multiArrayValue else { return (nil, 0, 0, 0, 0) }
    let th=arr.shape[2].intValue, tw=arr.shape[3].intValue, tPtr=arr.dataPointer.assumingMemoryBound(to: Float.self)
    var ns=false
    for i in 0..<min(100,tw*th*3) { if tPtr[i]>2.0{ns=false;break}; if tPtr[i]<=1.0 && i==min(100,tw*th*3)-1{ns=true} }
    let sc: Float = ns ? 255 : 1
    var rgba=[UInt8](repeating:0, count:tw*th*4)
    for c in 0..<3 { for i in 0..<(tw*th) { rgba[i*4+c]=UInt8(min(max(tPtr[c*tw*th+i]*sc,0),255)) } }
    for i in 0..<(tw*th) { rgba[i*4+3]=255 }
    guard let tc=CGContext(data:&rgba, width:tw, height:th, bitsPerComponent:8, bytesPerRow:tw*4, space:cs, bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue), let tcg=tc.makeImage()
    else { return (nil, 0, 0, 0, 0) }

    // crop to valid output region
    let ocx=padL*outputScale, ocy=padT*outputScale
    let vow=cropW*outputScale, voh=cropH*outputScale
    guard vow>0, voh>0, let cropped=tcg.cropping(to: CGRect(x:ocx, y:ocy, width:vow, height:voh))
    else { return (nil, 0, 0, 0, 0) }

    let cw=min(outPatchSize, (width-col*patchSize)*outputScale)
    let ch=min(outPatchSize, (height-row*patchSize)*outputScale)
    return (cropped, cw, ch, padL, padT)
}

func blendStrip(ctx: CGContext, strip: CGImage, destX: Int, destY: Int, w: Int, h: Int, rampDir: Int) {
    guard w>0, h>0, destX>=0, destY>=0, destX+w<=ctx.width, destY+h<=ctx.height else { return }
    var s=[UInt8](repeating:0, count:w*h*4)
    guard let sc=CGContext(data:&s, width:w, height:h, bitsPerComponent:8, bytesPerRow:w*4, space:cs, bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    sc.draw(strip, in: CGRect(x:0,y:0,width:w,height:h))
    guard let cd=ctx.data else { return }
    let cp=cd.assumingMemoryBound(to: UInt8.self), bpr=ctx.bytesPerRow
    for y in 0..<h {
        for x in 0..<w {
            let dy=destY+y, dx=destX+x
            var weight = CGFloat(x)/CGFloat(w-1)
            if rampDir < 0 { weight = 1.0 - weight }
            let si=y*w*4+x*4, ci=dy*bpr+dx*4
            let wr=1.0-weight
            cp[ci]=UInt8(min(max(CGFloat(cp[ci])*wr+CGFloat(s[si])*weight,0),255))
            cp[ci+1]=UInt8(min(max(CGFloat(cp[ci+1])*wr+CGFloat(s[si+1])*weight,0),255))
            cp[ci+2]=UInt8(min(max(CGFloat(cp[ci+2])*wr+CGFloat(s[si+2])*weight,0),255))
            cp[ci+3]=255
        }
    }
}

class CoreMLInput: MLFeatureProvider {
    let input: CVPixelBuffer
    var featureNames: Set<String> { ["input"] }
    init(input: CVPixelBuffer) { self.input = input }
    func featureValue(for name: String) -> MLFeatureValue? {
        name=="input" ? MLFeatureValue(pixelBuffer:input) : nil
    }
}

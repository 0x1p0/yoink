// Renders the Yoink app icon.
//
//   swift packaging/icon/make_icon.swift <output.png> [size]
//
// Drawn on Apple's macOS icon grid: a 1024 canvas with an 824-pt continuous-corner
// squircle, a soft drop shadow, a light "glass" sheen, and a glyph that merges ▶ play
// with ↓ download so it still reads at 16 px. `packaging/icon/build_icons.sh` turns the
// 1024 master into every size the app, the DMG and the README need.

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.png> [size]\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]
let size = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1024) : 1024
let s = size / 1024  // everything below is authored at 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple-style continuous corner rectangle (superellipse, n≈5).
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Triangle with rounded corners, points given top-left-origin.
func roundedTriangle(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
    path.move(to: mid)
    path.addArc(tangent1End: p2, tangent2End: p3, radius: r)
    path.addArc(tangent1End: p3, tangent2End: p1, radius: r)
    path.addArc(tangent1End: p1, tangent2End: p2, radius: r)
    path.closeSubpath()
    return path
}

let px = Int(size.rounded())
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Author in a top-left-origin 1024 space
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: s, y: -s)
ctx.interpolationQuality = .high
ctx.setShouldAntialias(true)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile)

// ── Drop shadow under the tile ──────────────────────────────────────────────
ctx.saveGState()
// Shadow offsets are in device space (y up), so negative = downward
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.30))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x7C3AED))
ctx.fillPath()
ctx.restoreGState()

// ── Tile: warm-to-violet gradient ───────────────────────────────────────────
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    rgb(0xFF7A2F), rgb(0xFF3F66), rgb(0xE0247F), rgb(0x7B2FF0), rgb(0x3F148F),
] as CFArray, locations: [0.0, 0.26, 0.47, 0.80, 1.0])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 150, y: 90), end: CGPoint(x: 880, y: 960), options: [])

// Soft light bloom top-left, deep shade bottom-right — gives the tile volume
let bloom = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 290, y: 230), startRadius: 0,
                       endCenter: CGPoint(x: 290, y: 230), endRadius: 480, options: [])
let shade = CGGradient(colorsSpace: cs, colors: [rgb(0x1E0B4A, 0), rgb(0x1E0B4A, 0.30)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(shade, startCenter: CGPoint(x: 512, y: 470), startRadius: 300,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 720, options: [])

// Glass sheen across the upper half
let sheenPath = CGMutablePath()
sheenPath.move(to: CGPoint(x: 100, y: 100))
sheenPath.addLine(to: CGPoint(x: 924, y: 100))
sheenPath.addLine(to: CGPoint(x: 924, y: 400))
sheenPath.addCurve(to: CGPoint(x: 100, y: 520),
                   control1: CGPoint(x: 700, y: 470), control2: CGPoint(x: 360, y: 430))
sheenPath.closeSubpath()
ctx.saveGState()
ctx.addPath(sheenPath)
ctx.clip()
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0.05), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 430), options: [])
ctx.restoreGState()
ctx.restoreGState()

// Crisp rim light: bright on top, fading toward the bottom
ctx.saveGState()
ctx.addPath(tilePath)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0.06)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

// ── Glyph: ▶ turned downward + tray bar ─────────────────────────────────────
let tri = roundedTriangle(CGPoint(x: 278, y: 292), CGPoint(x: 746, y: 292), CGPoint(x: 512, y: 648), radius: 64)
let bar = CGPath(roundedRect: CGRect(x: 296, y: 700, width: 432, height: 76),
                 cornerWidth: 38, cornerHeight: 38, transform: nil)
let glyph = CGMutablePath()
glyph.addPath(tri)
glyph.addPath(bar)

// Glyph shadow, tinted with the tile colour so it feels lit, not pasted on
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(0x3B0A6B, 0.55))
ctx.addPath(glyph)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Glyph fill: white with a whisper of warmth toward the bottom
ctx.saveGState()
ctx.addPath(glyph)
ctx.clip()
let glyphFill = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xFFF1F6), rgb(0xFFE2EE)] as CFArray,
                           locations: [0, 0.6, 1])!
ctx.drawLinearGradient(glyphFill, start: CGPoint(x: 512, y: 292), end: CGPoint(x: 512, y: 776), options: [])
ctx.restoreGState()

// ── Write PNG ──────────────────────────────────────────────────────────────
guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: outPath))

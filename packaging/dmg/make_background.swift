// Renders the DMG installer window background.
//
//   swift packaging/dmg/make_background.swift <out.png> <scale>     (scale 1 or 2)
//
// 660×440 pt window. The app icon sits at (170, 210) and the Applications alias at
// (490, 210) — keep in sync with packaging/dmg/settings.py.
//
// Finder draws the icon labels itself: black in Light Mode, white in Dark Mode. The
// gradient is therefore kept at mid luminance (≈0.15–0.25) so both label colours stay
// readable (≥ 3.5:1) whichever appearance the user runs.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: make_background.swift <out.png> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let W: CGFloat = 660, H: CGFloat = 440
let appCenter  = CGPoint(x: 170, y: 210)
let appsCenter = CGPoint(x: 490, y: 210)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // points → 1x or 2x pixels

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
// Top-left origin, like Finder's icon coordinates
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)

let full = CGRect(x: 0, y: 0, width: W, height: H)

// ── Base gradient: coral → magenta → violet, all mid-luminance ────────────────
let base = NSGradient(colors: [color(0xE0566F), color(0xC2479C), color(0x8A4CD6), color(0x6A45D8)],
                      atLocations: [0, 0.38, 0.72, 1], colorSpace: .displayP3)!
base.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -18)

// Large soft light pools behind each icon (kept above the label area)
func glow(_ c: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let g = NSGradient(colors: [NSColor(white: 1, alpha: alpha), NSColor(white: 1, alpha: 0)])!
    g.draw(fromCenter: c, radius: 0, toCenter: c, radius: radius, options: [])
}
glow(CGPoint(x: appCenter.x, y: appCenter.y - 16), radius: 150, alpha: 0.16)
glow(CGPoint(x: appsCenter.x, y: appsCenter.y - 16), radius: 150, alpha: 0.12)

// Sweeping ribbons for depth
func ribbon(_ y0: CGFloat, _ amp: CGFloat, _ alpha: CGFloat, _ thick: CGFloat) {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: -20, y: y0))
    p.curve(to: CGPoint(x: W + 20, y: y0 - amp * 0.4),
            controlPoint1: CGPoint(x: W * 0.3, y: y0 - amp),
            controlPoint2: CGPoint(x: W * 0.65, y: y0 + amp))
    p.lineWidth = thick
    NSColor(white: 1, alpha: alpha).setStroke()
    p.stroke()
}
ribbon(330, 90, 0.07, 70)
ribbon(360, 60, 0.05, 40)
ribbon(95, -50, 0.05, 50)

// Vignette so the edges feel finished
let vignette = NSGradient(colors: [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0.22)])!
vignette.draw(fromCenter: CGPoint(x: W / 2, y: H * 0.45), radius: 180,
              toCenter: CGPoint(x: W / 2, y: H * 0.45), radius: 520, options: [])

// ── Text ─────────────────────────────────────────────────────────────────────
func drawText(_ s: String, font: NSFont, color c: NSColor, centerX: CGFloat, top: CGFloat,
              kern: CGFloat = 0, shadow: Bool = false) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c,
                                               .paragraphStyle: para, .kern: kern]
    if shadow {
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.25)
        sh.shadowBlurRadius = 6
        sh.shadowOffset = NSSize(width: 0, height: -1)
        attrs[.shadow] = sh
    }
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    // Flip locally so text isn't upside-down in our top-left space
    ctx.saveGState()
    ctx.translateBy(x: 0, y: top + size.height)
    ctx.scaleBy(x: 1, y: -1)
    str.draw(in: NSRect(x: centerX - 300, y: 0, width: 600, height: size.height))
    ctx.restoreGState()
}

let serif: NSFont = {
    let base = NSFont.systemFont(ofSize: 34, weight: .heavy)
    if let d = base.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: d, size: 34) ?? base }
    return base
}()
drawText("Yoink", font: serif, color: .white, centerX: W / 2, top: 34, kern: 0.6, shadow: true)
drawText("Drag Yoink into your Applications folder",
         font: .systemFont(ofSize: 13.5, weight: .medium),
         color: NSColor(white: 1, alpha: 0.88), centerX: W / 2, top: 80)

// ── Arrow between the two icons ───────────────────────────────────────────────
let arrowY = appCenter.y - 6
let startX = appCenter.x + 88, endX = appsCenter.x - 88
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: startX, y: arrowY + 6))
arrow.curve(to: CGPoint(x: endX - 6, y: arrowY),
            controlPoint1: CGPoint(x: startX + 40, y: arrowY - 22),
            controlPoint2: CGPoint(x: endX - 44, y: arrowY - 22))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
let dash: [CGFloat] = [0.1, 11]
arrow.setLineDash(dash, count: 2, phase: 0)
ctx.saveGState()
let arrowShadow = NSShadow()
arrowShadow.shadowColor = NSColor(white: 0, alpha: 0.18); arrowShadow.shadowBlurRadius = 4
arrowShadow.set()
NSColor(white: 1, alpha: 0.9).setStroke()
arrow.stroke()
// Head
let head = NSBezierPath()
head.move(to: CGPoint(x: endX - 20, y: arrowY - 13))
head.line(to: CGPoint(x: endX, y: arrowY))
head.line(to: CGPoint(x: endX - 21, y: arrowY + 11))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()
ctx.restoreGState()

// ── Footer ───────────────────────────────────────────────────────────────────
drawText("Universal app for Apple Silicon and Intel  ·  macOS 13 Ventura or later",
         font: .systemFont(ofSize: 11, weight: .medium),
         color: NSColor(white: 1, alpha: 0.78), centerX: W / 2, top: 352)
drawText("First launch blocked? System Settings → Privacy & Security → Open Anyway",
         font: .systemFont(ofSize: 10.5, weight: .regular),
         color: NSColor(white: 1, alpha: 0.62), centerX: W / 2, top: 370)

NSGraphicsContext.restoreGraphicsState()
_ = full
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))

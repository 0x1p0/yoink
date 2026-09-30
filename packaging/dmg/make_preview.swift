// Renders a picture of the installer window for the README.
//
//   swift packaging/dmg/make_preview.swift <background@2x.png> <icon.png> <out.png> [dark]
//
// Composites the real DMG background and app icon inside macOS-style window chrome,
// with Finder-style labels (black in Light Mode, white in Dark Mode).

import AppKit

let a = CommandLine.arguments
guard a.count >= 4 else { exit(1) }
let bg = NSImage(contentsOfFile: a[1])!
let icon = NSImage(contentsOfFile: a[2])!
let dark = a.count >= 5 && a[4] == "dark"
let apps = NSWorkspace.shared.icon(forFile: "/Applications")

let W: CGFloat = 660, H: CGFloat = 440, bar: CGFloat = 32, pad: CGFloat = 40
let canvas = NSSize(width: W + pad * 2, height: H + bar + pad * 2)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale),
                           pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: canvas.height); ctx.scaleBy(x: 1, y: -1)   // top-left origin

let win = NSRect(x: pad, y: pad, width: W, height: H + bar)
let shape = NSBezierPath(roundedRect: win, xRadius: 14, yRadius: 14)

// Window shadow
ctx.saveGState()
let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35); sh.shadowBlurRadius = 28
sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
NSColor(white: dark ? 0.16 : 0.96, alpha: 1).setFill(); shape.fill()
ctx.restoreGState()

shape.addClip()
// Title bar
NSColor(white: dark ? 0.20 : 0.93, alpha: 1).setFill()
NSRect(x: win.minX, y: win.minY, width: W, height: bar).fill()
for (i, c) in [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1),
               NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
               NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: win.minX + 14 + CGFloat(i) * 20, y: win.minY + 10, width: 12, height: 12)).fill()
}
func text(_ s: String, _ font: NSFont, _ color: NSColor, centerX: CGFloat, top: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    let h = str.size().height
    ctx.saveGState()
    ctx.translateBy(x: 0, y: top + h); ctx.scaleBy(x: 1, y: -1)
    str.draw(in: NSRect(x: centerX - 150, y: 0, width: 300, height: h))
    ctx.restoreGState()
}
text("Yoink", .systemFont(ofSize: 13, weight: .semibold), NSColor(white: dark ? 0.85 : 0.25, alpha: 1),
     centerX: win.midX, top: win.minY + 8)

// Content: background + icons + labels
func drawFlipped(_ img: NSImage, _ r: NSRect) {
    ctx.saveGState()
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    img.draw(in: NSRect(x: 0, y: 0, width: r.width, height: r.height))
    ctx.restoreGState()
}
let content = NSRect(x: win.minX, y: win.minY + bar, width: W, height: H)
drawFlipped(bg, content)
let labelColor = dark ? NSColor.white : NSColor.black
for (img, center, label) in [(icon, CGPoint(x: 170, y: 210), "Yoink"),
                             (apps, CGPoint(x: 490, y: 210), "Applications")] {
    drawFlipped(img, NSRect(x: content.minX + center.x - 60, y: content.minY + center.y - 60, width: 120, height: 120))
    text(label, .systemFont(ofSize: 13, weight: .regular), labelColor,
         centerX: content.minX + center.x, top: content.minY + center.y + 64)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))

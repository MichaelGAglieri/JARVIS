// Draws the app icon (holographic reactor) and saves it as a 1024×1024 PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let c = CGPoint(x: size / 2, y: size / 2)
let cyan = CGColor(red: 0.31, green: 0.86, blue: 1.0, alpha: 1)
let ice = CGColor(red: 0.85, green: 0.98, blue: 1.0, alpha: 1)

func withAlpha(_ color: CGColor, _ a: CGFloat) -> CGColor { color.copy(alpha: a)! }

// Base: midnight blue squircle with a slight gradient, margins like macOS icons.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.5))
ctx.addPath(tilePath)
ctx.setFillColor(CGColor(red: 0.01, green: 0.04, blue: 0.09, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let bg = CGGradient(colorsSpace: space, colors: [withAlpha(cyan, 0.38), withAlpha(cyan, 0.08), withAlpha(cyan, 0)] as CFArray,
                    locations: [0, 0.45, 1])!
ctx.drawRadialGradient(bg, startCenter: c, startRadius: 0, endCenter: c, endRadius: 420, options: [])

func ring(_ r: CGFloat, _ width: CGFloat, _ color: CGColor, from: CGFloat = 0, to: CGFloat = .pi * 2, glow: CGFloat = 18) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glow, color: cyan)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.addArc(center: c, radius: r, startAngle: from, endAngle: to, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

// Outer scale of ticks.
for i in 0..<72 {
    let a = CGFloat(i) / 72 * .pi * 2
    let major = i % 6 == 0
    let r1: CGFloat = major ? 330 : 342
    ctx.setStrokeColor(withAlpha(cyan, major ? 0.9 : 0.45))
    ctx.setLineWidth(major ? 6 : 3)
    ctx.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * 356, y: c.y + sin(a) * 356))
    ctx.strokePath()
}
// Thick segmented arcs.
for (start, span) in [(0.2, 1.3), (1.9, 0.9), (3.2, 0.5), (4.1, 1.6)] as [(CGFloat, CGFloat)] {
    ring(292, 26, withAlpha(cyan, 0.9), from: start, to: start + span)
}
ring(258, 3, withAlpha(cyan, 0.6))
for i in 0..<48 {
    let s = CGFloat(i) / 48 * .pi * 2
    ring(232, 16, withAlpha(cyan, i % 3 == 0 ? 0.9 : 0.35), from: s, to: s + 0.09, glow: 8)
}
// Reactor coils.
for i in 0..<10 {
    let mid = CGFloat(i) / 10 * .pi * 2 + .pi / 2
    let r1: CGFloat = 112, r2: CGFloat = 188
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x + cos(mid - 0.2) * r1, y: c.y + sin(mid - 0.2) * r1))
    p.addLine(to: CGPoint(x: c.x + cos(mid - 0.17) * r2, y: c.y + sin(mid - 0.17) * r2))
    p.addLine(to: CGPoint(x: c.x + cos(mid + 0.17) * r2, y: c.y + sin(mid + 0.17) * r2))
    p.addLine(to: CGPoint(x: c.x + cos(mid + 0.2) * r1, y: c.y + sin(mid + 0.2) * r1))
    p.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: cyan)
    ctx.addPath(p)
    ctx.setFillColor(withAlpha(cyan, 0.45))
    ctx.setStrokeColor(withAlpha(ice, 0.95))
    ctx.setLineWidth(4)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}
ring(200, 7, withAlpha(ice, 0.95))
ring(102, 6, withAlpha(ice, 0.9))
// Glowing core.
let core = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), withAlpha(ice, 0.95), withAlpha(cyan, 0.6), withAlpha(cyan, 0)] as CFArray,
                      locations: [0, 0.3, 0.6, 1])!
ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: 120, options: [])
ctx.restoreGState()

// Thin glowing edge of the tile.
ctx.addPath(tilePath)
ctx.setStrokeColor(withAlpha(cyan, 0.35))
ctx.setLineWidth(4)
ctx.strokePath()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Icona salvata in \(output)")

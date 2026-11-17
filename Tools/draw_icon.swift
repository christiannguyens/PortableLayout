// draw_icon.swift — renders the default PortableDash app icon as a 1024×1024 PNG.
// Usage: swift Tools/draw_icon.swift out.png

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: an 824pt rounded square centred on the 1024 canvas, with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x1B1F4A).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

// Background gradient + glowing orbs, like the dashboard's ambient effect.
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [color(0x2A1450), color(0x3A1C5C), color(0xC2457E)])!
    .draw(in: body, angle: -55)
for (center, radius, hex, alpha) in [(NSPoint(x: 760, y: 820), 330.0, 0xFF8FC7, 0.55),
                                     (NSPoint(x: 230, y: 200), 300.0, 0x8B7BFF, 0.55)] as [(NSPoint, CGFloat, UInt32, CGFloat)] {
    NSGradient(colors: [color(hex, alpha), color(hex, 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

// Three "glass" panels in the sidebar-left layout.
let inset: CGFloat = 112, gap: CGFloat = 34
let grid = body.insetBy(dx: inset, dy: inset)
let sideW = (grid.width - gap) * 0.36
let side = NSRect(x: grid.minX, y: grid.minY, width: sideW, height: grid.height)
let rightX = side.maxX + gap, rightW = grid.maxX - rightX
let bottomH = (grid.height - gap) * 0.30
let bottom = NSRect(x: rightX, y: grid.minY, width: rightW, height: bottomH)
let top = NSRect(x: rightX, y: bottom.maxY + gap, width: rightW, height: grid.maxY - bottom.maxY - gap)

for r in [side, top, bottom] {
    let p = NSBezierPath(roundedRect: r, xRadius: 46, yRadius: 46)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.34), NSColor.white.withAlphaComponent(0.14)])!
        .draw(in: p, angle: -90)
    NSColor.white.withAlphaComponent(0.55).setStroke()
    p.lineWidth = 5
    p.stroke()
}

// Little details: chat bubbles in the sidebar, a sparkle in the big panel, a play button below.
NSColor.white.withAlphaComponent(0.9).setFill()
for (i, w) in [0.62, 0.45, 0.55].enumerated() {
    let y = side.maxY - 110 - CGFloat(i) * 92
    let x = i == 1 ? side.maxX - 36 - side.width * w : side.minX + 36
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: side.width * w, height: 54), xRadius: 27, yRadius: 27).fill()
}
let c = NSPoint(x: top.midX, y: top.midY)
let star = NSBezierPath()
for k in 0..<8 {
    let a = CGFloat(k) * .pi / 4 + .pi / 2
    let r: CGFloat = k % 2 == 0 ? 86 : 22
    let pt = NSPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    k == 0 ? star.move(to: pt) : star.line(to: pt)
}
star.close()
color(0xFFE3F1).setFill()
star.fill()
let play = NSBezierPath()
let pc = NSPoint(x: bottom.midX, y: bottom.midY)
play.move(to: NSPoint(x: pc.x - 26, y: pc.y + 34))
play.line(to: NSPoint(x: pc.x + 38, y: pc.y))
play.line(to: NSPoint(x: pc.x - 26, y: pc.y - 34))
play.close()
NSColor.white.setFill()
play.fill()

// Subtle top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")

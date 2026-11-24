import AppKit

// Draws the AI Pulse app icon (macOS squircle, indigo→violet gradient, white sparkles)
// and writes an .iconset:  swiftc make-icon.swift -o make-icon && ./make-icon OUT.iconset
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Apple's macOS icon grid: 824/1024 body, centered, ~22.4% corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.95, alpha: 1),   // indigo
        NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.93, alpha: 1),   // violet
        NSColor(calibratedRed: 0.80, green: 0.35, blue: 0.80, alpha: 1),   // soft magenta
    ])!
    gradient.draw(in: path, angle: -55)

    // Soft top highlight for depth.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Sparkles glyph.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let g = glyph.size
        let r = NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2 - s * 0.01, width: g.width, height: g.height)
        glyph.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * sc).write(to: out.appendingPathComponent(name))
    }
}
try! render(1024).write(to: out.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
print("wrote \(out.path)")

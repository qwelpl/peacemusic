// Renders Resources/AppIcon.icns. Run from the repo root: swift scripts/make_icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    // A dark tile, one thin ring and a warm dot: a record, pared down.
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [
        NSColor(white: 0.16, alpha: 1),
        NSColor(white: 0.05, alpha: 1),
    ])!.draw(in: tile, angle: -90)

    let center = NSPoint(x: size / 2, y: size / 2)
    func circle(_ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
    let ring = circle(size * 0.215)
    ring.lineWidth = max(size * 0.03, 1)
    NSColor(white: 1, alpha: 0.95).setStroke()
    ring.stroke()
    NSColor(srgbRed: 1, green: 0.74, blue: 0.25, alpha: 1).setFill()
    circle(size * 0.055).fill()
    NSGraphicsContext.restoreGraphicsState()

    // A hairline edge so the tile holds its shape on dark backgrounds.
    tilePath.lineWidth = max(size * 0.004, 0.5)
    NSColor(white: 1, alpha: 0.1).setStroke()
    tilePath.stroke()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Peace-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)

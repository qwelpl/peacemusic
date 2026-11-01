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

    let tilePath = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.96, green: 0.3, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.15, blue: 0.75, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.3, blue: 0.68, alpha: 1),
    ])!.draw(in: tile, angle: -60)

    let center = NSPoint(x: size / 2, y: size / 2)
    func circle(_ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
    NSColor(white: 0.05, alpha: 1).setFill()
    circle(size * 0.3).fill()
    NSColor(white: 1, alpha: 0.09).setStroke()
    for ring in stride(from: size * 0.15, to: size * 0.29, by: size * 0.022) {
        let path = circle(ring)
        path.lineWidth = max(size * 0.002, 0.5)
        path.stroke()
    }
    NSColor(srgbRed: 1, green: 0.78, blue: 0.45, alpha: 1).setFill()
    circle(size * 0.115).fill()
    NSColor(white: 0.05, alpha: 1).setFill()
    circle(size * 0.018).fill()
    NSGraphicsContext.restoreGraphicsState()

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

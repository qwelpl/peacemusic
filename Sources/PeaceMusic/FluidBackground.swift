import AppKit
import SwiftUI

/// Slow liquid mesh built from the artwork's colors, with film grain to hide banding.
struct FluidBackground: View {
    let colors: [Color]
    let trackID: String?
    let isPlaying: Bool

    var body: some View {
        ZStack {
            Color.black
            FluidMesh(colors: colors, isPlaying: isPlaying)
                .id(trackID)
                .transition(.opacity)
            Color.black.opacity(0.18)
            Image(nsImage: Grain.tile)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(0.1)
        }
        .animation(.easeInOut(duration: 1.4), value: trackID)
        .animation(.easeInOut(duration: 1.4), value: colors)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct FluidMesh: View {
    let colors: [Color]
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            MeshGradient(
                width: Palette.gridSize,
                height: Palette.gridSize,
                points: Self.points(at: context.date.timeIntervalSinceReferenceDate),
                colors: colors,
                smoothsColors: true
            )
        }
    }

    private static func points(at time: Double) -> [SIMD2<Float>] {
        let last = Palette.gridSize - 1
        var points: [SIMD2<Float>] = []
        for row in 0...last {
            for column in 0...last {
                let x = Double(column) / Double(last)
                let y = Double(row) / Double(last)
                let phase = Double(row * 3 + column * 7)
                // Outer points stay on the edge so the mesh always covers the window.
                let dx = (column == 0 || column == last) ? 0 : sin(time * 0.31 + phase) * 0.11
                let dy = (row == 0 || row == last) ? 0 : cos(time * 0.23 + phase * 1.4) * 0.11
                points.append(SIMD2(Float(x + dx), Float(y + dy)))
            }
        }
        return points
    }
}

private enum Grain {
    static let tile: NSImage = {
        let size = 192
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: size, bitsPerPixel: 8
        )!
        for index in 0..<(size * size) {
            rep.bitmapData![index] = UInt8.random(in: 0...255)
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }()
}

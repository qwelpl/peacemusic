import AppKit
import SwiftUI

/// Print-inspired mode: the album art is a field of living dots, and every sung word
/// sends a ripple through it. Ripples come from lyric timing, so they follow the vocal.
struct HalftoneView: View {
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store

    var body: some View {
        ZStack {
            HalftoneField()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.92), location: 0.86),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HalftoneHeader()
                Spacer(minLength: 0)
                HalftoneCaption()
                HalftoneControls(chromeVisible: chromeVisible)
                    .padding(.top, 18)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
        .ignoresSafeArea()
    }
}

// MARK: Dot field

private struct HalftoneField: View {
    @Environment(PlayerStore.self) private var store
    @State private var renderer = HalftoneRenderer()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { context in
            let date = context.date
            Canvas(opaque: true) { graphics, size in
                renderer.draw(
                    in: &graphics,
                    size: size,
                    artwork: store.artwork,
                    time: date.timeIntervalSinceReferenceDate,
                    ripples: ripples(position: store.lyricPosition(at: date))
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// The most recent word onsets, or line onsets for songs with only line timing.
    private func ripples(position: Double) -> [HalftoneRipple] {
        guard case .synced(let lines) = store.lyrics, let index = store.lyricIndex else { return [] }
        var result: [HalftoneRipple] = []
        for line in lines[max(index - 1, 0)...index].reversed() where !line.isInterlude {
            let onsets = line.words?.map(\.time) ?? [line.time]
            for (wordIndex, onset) in onsets.enumerated().reversed() {
                let age = position - onset
                guard age >= 0, age < HalftoneRipple.lifetime, result.count < 5 else { continue }
                // A fixed sequence of origins, so a word ripples from the same spot on replay.
                let seed = Double(line.id * 7 + wordIndex)
                result.append(HalftoneRipple(
                    origin: CGPoint(x: 0.5 + 0.34 * sin(seed * 2.4), y: 0.42 + 0.26 * cos(seed * 1.7)),
                    age: age,
                    strength: line.words == nil ? 1.5 : 1
                ))
            }
        }
        return result
    }
}

private struct HalftoneRipple {
    static let lifetime = 1.5

    /// In unit coordinates of the window.
    let origin: CGPoint
    let age: Double
    let strength: Double
}

private struct HalftoneGrid {
    let columns: Int
    let rows: Int
    /// Red, green and blue from 0 to 1, row by row.
    let colors: [SIMD3<Float>]
    let luminance: [Float]
}

/// Holds sampled art between frames and draws the field.
private final class HalftoneRenderer {
    private static let maxDots: CGFloat = 7000
    private static let colorLevels: Float = 6
    private static let morphDuration = 1.3

    private var grid: HalftoneGrid?
    private var previousGrid: HalftoneGrid?
    private var morphStart = 0.0
    private var sampledArtwork: NSImage?
    private var paths = [Path?](repeating: nil, count: 216)

    func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        artwork: NSImage?,
        time: Double,
        ripples: [HalftoneRipple]
    ) {
        graphics.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.02)))
        guard size.width > 0, size.height > 0 else { return }

        let pitch = max(12, (size.width * size.height / Self.maxDots).squareRoot())
        let columns = Int(size.width / pitch) + 1
        let rows = Int(size.height / pitch) + 1
        updateGrid(artwork: artwork, columns: columns, rows: rows, aspect: size.width / size.height, time: time)
        guard let grid else { return }

        // Comparing squared distances against a shared aspect keeps ripples circular.
        let aspect = size.width / size.height
        let morph = min((time - morphStart) / Self.morphDuration, 1)
        let from = morph < 1 ? previousGrid : nil

        for index in paths.indices { paths[index] = nil }

        for row in 0..<rows {
            let v = (Double(row) + 0.5) / Double(rows)
            // Staggered rows, as on a printing screen.
            let shift = row % 2 == 0 ? 0 : pitch / 2
            for column in 0..<columns {
                let index = row * columns + column
                let u = (Double(column) + 0.5) / Double(columns)

                var luminance = grid.luminance[index]
                var color = grid.colors[index]
                if let from {
                    // The new cover spreads outward from the middle.
                    let distance = hypot((u - 0.5) * aspect, v - 0.5)
                    let local = Float(min(max(morph * 2.4 - distance * 1.4, 0), 1))
                    luminance = from.luminance[index] + (luminance - from.luminance[index]) * local
                    color = from.colors[index] + (color - from.colors[index]) * local
                }

                var energy = 0.0
                var pushX = 0.0
                var pushY = 0.0
                for ripple in ripples {
                    let dx = (u - ripple.origin.x) * aspect
                    let dy = v - ripple.origin.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    let band = distance - ripple.age * 0.75
                    guard abs(band) < 0.14 else { continue }
                    let fade = 1 - ripple.age / HalftoneRipple.lifetime
                    let amount = (1 - abs(band) / 0.14) * fade * fade * ripple.strength
                    energy += amount
                    if distance > 0.001 {
                        pushX += dx / distance * amount
                        pushY += dy / distance * amount
                    }
                }

                let breathing = sin(time * 0.6 + u * 5 + v * 4) * 0.07
                let radiusUnit = Double(luminance) * (0.92 + breathing) + 0.05 + energy * 0.34
                let radius = min(radiusUnit, 1.12) * pitch * 0.5
                let x = (Double(column) + 0.5) * pitch + shift + pushX * pitch * 0.7
                let y = (Double(row) + 0.5) * pitch + pushY * pitch * 0.7

                let lift = Float(min(energy * 0.55, 0.7))
                let bucket = Self.bucket(for: color + (SIMD3<Float>(repeating: 1) - color) * lift)
                if paths[bucket] == nil { paths[bucket] = Path() }
                paths[bucket]!.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }

        for (bucket, path) in paths.enumerated() {
            guard let path else { continue }
            graphics.fill(path, with: .color(Self.color(forBucket: bucket)))
        }
    }

    /// Limiting colors posterizes the art like spot inks, and lets dots be drawn in batches.
    private static func bucket(for color: SIMD3<Float>) -> Int {
        let top = colorLevels - 1
        let red = Int(min(max(color.x, 0), 1) * top + 0.5)
        let green = Int(min(max(color.y, 0), 1) * top + 0.5)
        let blue = Int(min(max(color.z, 0), 1) * top + 0.5)
        return red * 36 + green * 6 + blue
    }

    private static func color(forBucket bucket: Int) -> Color {
        let top = Double(colorLevels - 1)
        return Color(.sRGB, red: Double(bucket / 36) / top, green: Double(bucket / 6 % 6) / top, blue: Double(bucket % 6) / top)
    }

    private func updateGrid(artwork: NSImage?, columns: Int, rows: Int, aspect: Double, time: Double) {
        let artworkChanged = artwork !== sampledArtwork
        guard artworkChanged || grid?.columns != columns || grid?.rows != rows else { return }

        let next = Self.sample(artwork, columns: columns, rows: rows, aspect: aspect)
        // Only a new cover animates. A resized window just redraws at the new density.
        if artworkChanged, let grid, grid.columns == columns, grid.rows == rows {
            previousGrid = grid
            morphStart = time
        } else {
            previousGrid = nil
        }
        grid = next
        sampledArtwork = artwork
    }

    private static func sample(_ artwork: NSImage?, columns: Int, rows: Int, aspect: Double) -> HalftoneGrid {
        let count = columns * rows
        let blank = HalftoneGrid(
            columns: columns,
            rows: rows,
            colors: Array(repeating: SIMD3<Float>(repeating: 0.6), count: count),
            luminance: Array(repeating: 0.16, count: count)
        )
        guard let image = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return blank }

        // Scaled to fill the window, cropping whichever sides overflow.
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let scale = max(Double(columns) / imageWidth, Double(rows) / imageHeight)
        let drawWidth = imageWidth * scale
        let drawHeight = imageHeight * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (Double(columns) - drawWidth) / 2,
            y: (Double(rows) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        ))
        guard let data = context.data else { return blank }
        let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)

        var colors = [SIMD3<Float>](repeating: .zero, count: count)
        var luminance = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let color = SIMD3<Float>(
                Float(pixels[index * 4]),
                Float(pixels[index * 4 + 1]),
                Float(pixels[index * 4 + 2])
            ) / 255
            let light = color.x * 0.299 + color.y * 0.587 + color.z * 0.114
            let saturated = SIMD3<Float>(repeating: light) + (color - SIMD3<Float>(repeating: light)) * 1.35
            colors[index] = saturated
            // Lifted, because true luminance would leave dark covers almost empty.
            luminance[index] = pow(light, 0.7)
        }
        return HalftoneGrid(columns: columns, rows: rows, colors: colors, luminance: luminance)
    }
}

// MARK: Interface

private struct HalftoneHeader: View {
    @Environment(\.uiTheme) private var theme
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.track?.title.uppercased() ?? "")
                .font(theme.font(15, .bold))
            Text(store.track?.artist.uppercased() ?? "")
                .font(theme.font(12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .themedPanel(theme, cornerRadius: 12)
    }
}

private struct HalftoneCaption: View {
    @Environment(\.uiTheme) private var theme
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            current
                .font(theme.font(36, .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(nextText)
                .font(theme.font(14))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentLine: LyricLine? {
        guard case .synced(let lines) = store.lyrics, let index = store.lyricIndex else { return nil }
        return lines[index]
    }

    private var nextText: String {
        guard case .synced(let lines) = store.lyrics else { return "" }
        let start = (store.lyricIndex ?? -1) + 1
        return lines[min(start, lines.count)...].first { !$0.isInterlude }?.text ?? ""
    }

    @ViewBuilder
    private var current: some View {
        if let line = currentLine, let words = line.words {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { context in
                litText(words, position: store.lyricPosition(at: context.date))
            }
        } else if let line = currentLine, !line.isInterlude {
            Text(line.text).foregroundStyle(.white)
        } else {
            Text("···").foregroundStyle(.white.opacity(0.5))
        }
    }

    private func litText(_ words: [LyricWord], position: Double) -> Text {
        var string = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(index == 0 ? word.text : " " + word.text)
            piece.foregroundColor = .white.opacity(position >= word.time ? 1 : 0.32)
            string += piece
        }
        return Text(string)
    }
}

private struct HalftoneControls: View {
    @Environment(\.uiTheme) private var theme
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store
    @State private var dragValue: Double?

    private var duration: Double { store.track?.duration ?? 0 }

    var body: some View {
        HStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let shown = dragValue ?? (duration > 0 ? store.position(at: context.date) / duration : 0)
                HStack(spacing: 14) {
                    Text("\(Self.format(shown * duration)) / \(Self.format(duration))")
                        .font(theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                    Scrubber(value: shown) { dragValue = $0 } onCommit: { value in
                        store.seek(to: value * duration)
                        dragValue = nil
                    }
                }
            }
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 8) {
                    PlayerButton(symbol: "backward.fill", title: "PREV", diameter: 40, iconSize: 14, action: store.previous)
                    PlayerButton(
                        symbol: store.isPlaying ? "pause.fill" : "play.fill",
                        title: store.isPlaying ? "PAUSE" : "PLAY",
                        diameter: 48,
                        iconSize: 18,
                        monoWidth: 70,
                        action: store.togglePlayPause
                    )
                    PlayerButton(symbol: "forward.fill", title: "NEXT", diameter: 40, iconSize: 14, action: store.next)
                }
            }
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

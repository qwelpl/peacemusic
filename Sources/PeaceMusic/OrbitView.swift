import AppKit
import SwiftUI

// The art at the centre of rings of spectrum bars, with bass hits rippling out.
struct OrbitView: View {
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer
    @Environment(\.uiTheme) private var theme
    @State private var motion = OrbitMotion()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FluidBackground(colors: store.meshColors, trackID: store.track?.id, isPlaying: store.isPlaying)
                .opacity(0.16)

            VStack(spacing: 14) {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !store.isPlaying)) { context in
                        let pulse = pulse(at: context.date)
                        let radius = min(geometry.size.width, geometry.size.height) * 0.17
                        ZStack {
                            Canvas { graphics, size in
                                motion.draw(
                                    in: &graphics,
                                    size: size,
                                    radius: radius,
                                    pulse: pulse,
                                    date: context.date,
                                    colors: accents,
                                    isMono: theme == .mono
                                )
                            }
                            ArtworkImage(image: store.artwork)
                                .frame(width: radius * 1.7, height: radius * 1.7)
                                .clipShape(.circle)
                                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                                .shadow(color: (accents.first ?? .white).opacity(0.35 + pulse.bass * 0.4), radius: 20 + pulse.bass * 30)
                                .scaleEffect(1 + pulse.bass * 0.07)
                        }
                    }
                }
                .padding(.top, 56)

                OrbitLyric()
                    .padding(.horizontal, 40)

                StageFooter(chromeVisible: chromeVisible)
            }
        }
        .listensToMusic()
    }

    // The three most colourful parts of the art, brightened to read on black.
    private var accents: [Color] {
        let colors = store.meshColors
            .compactMap { NSColor($0).usingColorSpace(.sRGB) }
            .sorted { $0.saturationComponent > $1.saturationComponent }
            .prefix(3)
            .map { Color(hue: $0.hueComponent, saturation: min($0.saturationComponent * 1.1, 0.85), brightness: 1) }
        return colors.isEmpty ? [.white] : colors
    }

    // Without an audio tap, fake the beat from the lyric word timings.
    private func pulse(at date: Date) -> OrbitPulse {
        let audio = analyzer.reading
        if audio.hasSignal {
            return OrbitPulse(
                bass: audio.bass,
                mid: audio.mid,
                spectrum: audio.spectrum,
                hits: audio.onsets.filter(\.isBass).map { date.timeIntervalSince($0.date) }
            )
        }
        let position = store.lyricPosition(at: date)
        var hits: [Double] = []
        if case .synced(let lines) = store.lyrics, let index = store.lyricIndex {
            let line = lines[index]
            hits = (line.words?.map(\.time) ?? [line.time]).map { position - $0 }.filter { $0 >= 0 }
        }
        let latest = hits.min() ?? 10
        let beat = max(1 - latest / 0.35, 0)
        let spectrum = (0..<SpectrumAnalyzer.bandCount).map { band in
            Float(beat * (0.35 + 0.3 * sin(Double(band) * 0.9 + position * 3)))
        }
        return OrbitPulse(bass: beat, mid: beat * 0.6, spectrum: spectrum, hits: hits)
    }
}

struct OrbitPulse {
    var bass: Double
    var mid: Double
    var spectrum: [Float]
    // Seconds since each recent bass hit.
    var hits: [Double]
}

private final class OrbitMotion {
    private static let ringCount = 3
    private static let barsPerRing = 72
    private static let particleCount = 110
    private static let waveLifetime = 1.3

    private var spin = 0.0
    private var drift = 0.0
    private var last: Date?

    func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        radius: CGFloat,
        pulse: OrbitPulse,
        date: Date,
        colors: [Color],
        isMono: Bool
    ) {
        // Speed follows the music, so integrate rather than multiply time.
        let step = min(last.map { date.timeIntervalSince($0) } ?? 0, 0.1)
        last = date
        spin += step * (0.12 + pulse.mid * 0.9)
        drift += step * (0.25 + pulse.bass * 1.6)

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let color = { (index: Int) in isMono ? Color.white : colors[index % colors.count] }

        for age in pulse.hits where age < Self.waveLifetime {
            let progress = age / Self.waveLifetime
            let waveRadius = radius * (1 + progress * 2.6)
            let ring = Path(ellipseIn: CGRect(x: center.x - waveRadius, y: center.y - waveRadius, width: waveRadius * 2, height: waveRadius * 2))
            graphics.stroke(ring, with: .color(color(0).opacity((1 - progress) * 0.5)), lineWidth: 2 + (1 - progress) * 4)
        }

        for ring in 0..<Self.ringCount {
            let inner = radius * (1.02 + CGFloat(ring) * 0.42)
            let reach = radius * (0.22 + CGFloat(ring) * 0.08)
            let direction = ring.isMultiple(of: 2) ? 1.0 : -1.0
            let offset = spin * direction * (1 + Double(ring) * 0.6)
            var bars = Path()
            for bar in 0..<Self.barsPerRing {
                let band = Self.band(for: bar + ring * 5, count: pulse.spectrum.count)
                let value = CGFloat(pulse.spectrum[band])
                let angle = Double(bar) / Double(Self.barsPerRing) * 2 * .pi + offset
                let end = inner + max(reach * value, 1.2)
                bars.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                bars.addLine(to: CGPoint(x: center.x + cos(angle) * end, y: center.y + sin(angle) * end))
            }
            let width = max(inner * 2 * .pi / CGFloat(Self.barsPerRing) * 0.42, 1.5)
            graphics.stroke(
                bars,
                with: .color(color(ring).opacity(0.85 - Double(ring) * 0.18)),
                style: StrokeStyle(lineWidth: width, lineCap: isMono ? .butt : .round)
            )
        }

        let swarm = radius * 2.6
        for particle in 0..<Self.particleCount {
            let seed = Double(particle)
            let orbit = swarm * (0.75 + 0.55 * Self.noise(seed * 1.7)) * (1 + pulse.bass * 0.12)
            let speed = 0.4 + Self.noise(seed * 3.1) * 0.8
            let angle = seed * 2.399 + drift * speed
            let wobble = sin(drift * 2 + seed) * radius * 0.08
            let point = CGPoint(x: center.x + cos(angle) * (orbit + wobble), y: center.y + sin(angle) * (orbit + wobble) * 0.92)
            let dot = 1.2 + Self.noise(seed * 5.3) * 2.2 + pulse.bass * 1.5
            let rect = CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)
            graphics.fill(
                isMono ? Path(rect) : Path(ellipseIn: rect),
                with: .color(color(particle).opacity(0.25 + Self.noise(seed * 7.7) * 0.5))
            )
        }
    }

    // Mirrors the spectrum around the ring so it has no seam.
    private static func band(for bar: Int, count: Int) -> Int {
        let position = bar % (count * 2)
        return position < count ? position : count * 2 - 1 - position
    }

    private static func noise(_ value: Double) -> Double {
        let x = sin(value * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
}

private struct OrbitLyric: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.uiTheme) private var theme
    @Environment(\.lyricFont) private var lyricFont
    @Environment(\.lyricScale) private var scale

    var body: some View {
        Group {
            if let line = currentLine, let words = line.words {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { context in
                    litText(words, position: store.lyricPosition(at: context.date))
                }
            } else if let line = currentLine, !line.isInterlude {
                Text(line.text).foregroundStyle(.white)
            } else {
                Text(" ")
            }
        }
        .font(lyricFont.font(30 * scale, .heavy, theme: theme))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.25), value: store.lyricIndex)
    }

    private var currentLine: LyricLine? {
        guard case .synced(let lines) = store.lyrics, let index = store.lyricIndex else { return nil }
        return lines[index]
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

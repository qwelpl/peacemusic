import SwiftUI

// A slowly turning night sky. Stars twinkle with the spectrum, the whole sky kicks on the
// bass, and the vocals trace new constellations word by word as they're sung.
struct ConstellationView: View {
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer
    @Environment(\.uiTheme) private var theme
    @State private var motion = ConstellationMotion()
    @AppStorage(FrameRate.key) private var frameRate = FrameRate.standard
    @AppStorage(FrameRate.savesBatteryKey) private var savesBattery = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            FluidBackground(colors: store.meshColors, trackID: store.track?.id, isPlaying: store.isPlaying)
                .opacity(0.1)

            TimelineView(.animation(minimumInterval: FrameRate.interval(frameRate, savesBattery: savesBattery), paused: !store.isPlaying)) { context in
                let audio = analyzer.reading
                let pulse = OrbitPulse(store: store, audio: audio, at: context.date)
                let vocals = vocalTrace(at: context.date)
                let voiceHits = audio.hasSignal ? audio.onsets.filter { !$0.isBass }.map(\.date) : []
                Canvas { graphics, size in
                    motion.draw(
                        in: &graphics,
                        size: size,
                        pulse: pulse,
                        vocals: vocals,
                        voiceHits: voiceHits,
                        date: context.date,
                        colors: store.accentColors,
                        isMono: theme == .mono
                    )
                }
            }
            .ignoresSafeArea()

            ConstellationCorner(chromeVisible: chromeVisible)
                .padding(24)
        }
        .listensToMusic()
    }

    // The current and previous lyric lines, with a start time for every syllable.
    private func vocalTrace(at date: Date) -> VocalTrace? {
        guard case .synced(let lines) = store.lyrics else { return nil }
        let position = store.lyricPosition(at: date)
        guard let current = lines.lastIndex(where: { $0.time <= position }) else {
            return VocalTrace(lines: [], position: position)
        }
        let recent = (max(current - 1, 0)...current).compactMap { index -> VocalTrace.Line? in
            let line = lines[index]
            guard !line.isInterlude else { return nil }
            let end = index + 1 < lines.count ? lines[index + 1].time : line.time + 6
            let words = line.words ?? Self.spread(line, until: end)
            return VocalTrace.Line(id: line.id, words: words.map(Self.sung), end: end)
        }
        return VocalTrace(lines: recent, position: position)
    }

    // Lines without word timing get their words spaced evenly across the line.
    private static func spread(_ line: LyricLine, until end: Double) -> [LyricWord] {
        let texts = line.text.split(separator: " ").map(String.init)
        let gap = max(end - line.time, 0.5) * 0.85 / Double(max(texts.count, 1))
        return texts.enumerated().map { LyricWord(text: $1, time: line.time + gap * Double($0), duration: gap * 0.8) }
    }

    // Splits a word's sung time evenly across its syllables.
    private static func sung(_ word: LyricWord) -> SungWord {
        let count = syllables(in: word.text)
        let duration = max(word.duration, 0.12 * Double(count))
        return SungWord(
            syllables: (0..<count).map { word.time + duration * Double($0) / Double(count) },
            end: word.time + duration
        )
    }

    // Vowel groups for Latin text, one per character otherwise (CJK, kana).
    private static func syllables(in word: String) -> Int {
        let letters = word.lowercased().filter(\.isLetter)
        guard letters.contains(where: \.isASCII) else { return min(max(letters.count, 1), 6) }
        var count = 0
        var inVowel = false
        for letter in letters {
            let isVowel = "aeiouyàáâäèéêëìíîïòóôöùúûü".contains(letter)
            if isVowel && !inVowel { count += 1 }
            inVowel = isVowel
        }
        if count > 1, letters.hasSuffix("e"), !letters.hasSuffix("le") { count -= 1 }
        return min(max(count, 1), 6)
    }
}

struct VocalTrace {
    struct Line {
        let id: Int
        // Every word draws one line between stars.
        let words: [SungWord]
        // When the next line starts, so this one can fade out.
        let end: Double
    }

    var lines: [Line]
    var position: Double
}

struct SungWord {
    // When each syllable starts, and when the word is let go.
    var syllables: [Double]
    var end: Double

    // How far along its line the word has got. Each syllable carries it an equal share,
    // easing out so a held syllable keeps creeping toward the star until it ends.
    func progress(at now: Double) -> Double {
        guard let first = syllables.first, now >= first else { return 0 }
        guard now < end else { return 1 }
        let bounds = syllables + [end]
        let index = (0..<syllables.count).last { bounds[$0] <= now } ?? 0
        let length = max(bounds[index + 1] - bounds[index], 0.001)
        let local = min((now - bounds[index]) / length, 1)
        return (Double(index) + 1 - pow(1 - local, 2.2)) / Double(syllables.count)
    }

    // The start of the syllable being sung.
    func latest(at now: Double) -> Double? {
        syllables.last { $0 <= now }
    }
}

private final class ConstellationMotion {
    private static let starCount = 280
    // The first stars are the brighter ones that form the background constellations.
    private static let nodeCount = 64
    private static let linksPerNode = 2
    private static let meteorLifetime = 0.9
    private static let lineFade = 2.5
    private static let voiceFade = 4.0

    private var turn = 0.0
    private var last: Date?
    // Star chains traced by each lyric line, keyed by line id.
    private var chains: [Int: [Int]] = [:]
    // Without synced lyrics, mid-range hits trace a chain instead.
    private var voiceChain: [(date: Date, star: Int)] = []

    func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        pulse: OrbitPulse,
        vocals: VocalTrace?,
        voiceHits: [Date],
        date: Date,
        colors: [Color],
        isMono: Bool
    ) {
        // Speed follows the music, so integrate rather than multiply time.
        let step = min(last.map { date.timeIntervalSince($0) } ?? 0, 0.1)
        last = date
        turn += step * (0.008 + pulse.mid * 0.03)

        // A sharp envelope off each bass hit reads as the beat; the level alone lags.
        let kick = pulse.hits.filter { $0 >= 0 }.map { exp(-$0 / 0.16) }.max() ?? 0
        let beat = min(max(kick, pulse.bass * pulse.bass * 0.6), 1)

        let time = date.timeIntervalSinceReferenceDate
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        // Wide enough that turning never shows an empty corner.
        let reach = hypot(size.width, size.height) * 0.6
        let color = { (index: Int) in isMono ? Color.white : colors[index % colors.count] }
        graphics.blendMode = .plusLighter

        graphics.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [color(0).opacity(beat * 0.06), .clear]),
                center: center,
                startRadius: 0,
                endRadius: reach * 0.8
            )
        )

        // The whole sky swells on the beat.
        let zoom = 1 + beat * 0.015
        graphics.translateBy(x: center.x, y: center.y)
        graphics.scaleBy(x: zoom, y: zoom)
        graphics.translateBy(x: -center.x, y: -center.y)

        var points: [CGPoint] = []
        var levels: [Double] = []
        for star in 0..<Self.starCount {
            let seed = Double(star)
            let depth = Self.noise(seed * 1.3)
            let distance = sqrt(Self.noise(seed * 2.1)) * reach
            let angle = Self.noise(seed * 3.7) * 2 * .pi + turn * (0.5 + depth)
            points.append(CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance))

            let band = star % pulse.spectrum.count
            let twinkle = 0.5 + 0.5 * sin(time * (0.8 + Self.noise(seed * 4.9) * 2.4) + seed)
            levels.append(min(0.2 + twinkle * 0.25 + Double(pulse.spectrum[band]) * 0.8 + beat * 0.12, 1))
        }

        let span = min(size.width, size.height) * (0.17 + beat * 0.01)
        var links = Set<Int>()
        for node in 0..<Self.nodeCount {
            let nearest = (0..<Self.nodeCount)
                .filter { $0 != node }
                .map { ($0, Self.distance(points[node], points[$0])) }
                .filter { $0.1 < span }
                .sorted { $0.1 < $1.1 }
                .prefix(Self.linksPerNode)
            for (other, _) in nearest {
                links.insert(min(node, other) * Self.nodeCount + max(node, other))
            }
        }
        for link in links {
            let a = link / Self.nodeCount
            let b = link % Self.nodeCount
            let closeness = 1 - Self.distance(points[a], points[b]) / span
            var line = Path()
            line.move(to: points[a])
            line.addLine(to: points[b])
            graphics.stroke(
                line,
                with: .color(color(a).opacity(closeness * (0.08 + beat * 0.18) * (levels[a] + levels[b]) / 2 + 0.03)),
                lineWidth: 0.6 + beat * 0.35
            )
        }

        for star in 0..<Self.starCount {
            let seed = Double(star)
            let isNode = star < Self.nodeCount
            let level = levels[star]
            let base = isNode ? 1.4 + Self.noise(seed * 6.1) * 1.2 : 0.5 + Self.noise(seed * 6.1) * 0.9
            let radius = base * (1 + level * 0.6 + beat * 0.2)
            let tint = isNode || star.isMultiple(of: 4) ? color(star) : .white
            if isNode {
                let halo = radius * (3 + beat * 1.2)
                graphics.fill(Self.dot(points[star], halo, isMono), with: .color(tint.opacity(level * 0.18)))
            }
            graphics.fill(Self.dot(points[star], radius, isMono), with: .color(tint.opacity(level)))
        }

        let open = Self.openArea(size)
        if let vocals {
            drawLyricChains(in: &graphics, vocals: vocals, points: points, open: open, span: span, color: color, isMono: isMono)
        } else {
            drawVoiceChain(in: &graphics, hits: voiceHits, date: date, points: points, open: open, span: span, color: color, isMono: isMono)
        }

        // Only some bass hits throw a meteor, or the sky turns into rain.
        for age in pulse.hits where age >= 0 && age < Self.meteorLifetime {
            let seed = ((time - age) * 20).rounded()
            guard Self.noise(seed * 0.37) > 0.55 else { continue }
            let progress = age / Self.meteorLifetime
            let start = CGPoint(x: Self.noise(seed * 1.1) * size.width, y: Self.noise(seed * 2.3) * size.height * 0.6)
            let heading = 0.35 + Self.noise(seed * 3.9) * 0.5
            let travel = min(size.width, size.height) * 0.5
            let head = CGPoint(x: start.x + cos(heading) * travel * progress, y: start.y + sin(heading) * travel * progress)
            let tailLength = travel * 0.35
            let tail = CGPoint(x: head.x - cos(heading) * tailLength, y: head.y - sin(heading) * tailLength)
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            let fade = 1 - progress
            graphics.stroke(
                streak,
                with: .linearGradient(
                    Gradient(colors: [.clear, color(Int(seed)).opacity(fade * 0.9)]),
                    startPoint: tail,
                    endPoint: head
                ),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
            graphics.fill(Self.dot(head, 2.2, isMono), with: .color(.white.opacity(fade)))
        }
    }

    // Each sung word draws the next line of that lyric's constellation.
    private func drawLyricChains(
        in graphics: inout GraphicsContext,
        vocals: VocalTrace,
        points: [CGPoint],
        open: CGRect,
        span: CGFloat,
        color: (Int) -> Color,
        isMono: Bool
    ) {
        chains = chains.filter { id, _ in vocals.lines.contains { $0.id == id } }
        for line in vocals.lines {
            let fade = vocals.position < line.end ? 1 : max(1 - (vocals.position - line.end) / Self.lineFade, 0)
            guard fade > 0 else { continue }
            if chains[line.id] == nil {
                let taken = Set(chains.values.joined())
                chains[line.id] = Self.chain(length: line.words.count + 1, seed: Double(line.id), points: points, open: open, span: span, avoiding: taken)
            }
            guard let stars = chains[line.id] else { continue }
            Self.trace(
                in: &graphics,
                stars: stars,
                words: line.words,
                start: line.words.first?.syllables.first ?? line.end,
                now: vocals.position,
                fade: fade,
                points: points,
                color: color(line.id),
                isMono: isMono
            )
        }
    }

    private func drawVoiceChain(
        in graphics: inout GraphicsContext,
        hits: [Date],
        date: Date,
        points: [CGPoint],
        open: CGRect,
        span: CGFloat,
        color: (Int) -> Color,
        isMono: Bool
    ) {
        for hit in hits.sorted() where hit > (voiceChain.last?.date ?? .distantPast) {
            let seed = hit.timeIntervalSinceReferenceDate * 10
            let continues = voiceChain.last.map { hit.timeIntervalSince($0.date) < 1.5 } ?? false
            let star: Int
            if continues, let previous = voiceChain.last?.star {
                star = Self.next(after: previous, seed: seed, points: points, open: open, span: span, avoiding: Set(voiceChain.map(\.star)))
            } else {
                star = Self.start(seed: seed, points: points, open: open, avoiding: Set(voiceChain.map(\.star)))
                // A gap in the singing starts a new constellation.
                voiceChain.removeAll()
            }
            voiceChain.append((hit, star))
        }
        voiceChain.removeAll { date.timeIntervalSince($0.date) > Self.voiceFade }
        guard !voiceChain.isEmpty else { return }
        let fade = max(1 - date.timeIntervalSince(voiceChain.last!.date) / Self.voiceFade, 0)
        // The first hit only lights a star; each later one draws a short line to its star.
        let words = voiceChain.dropFirst().map { hit in
            SungWord(syllables: [hit.date.timeIntervalSinceReferenceDate], end: hit.date.timeIntervalSinceReferenceDate + 0.15)
        }
        Self.trace(
            in: &graphics,
            stars: voiceChain.map(\.star),
            words: words,
            start: voiceChain[0].date.timeIntervalSinceReferenceDate,
            now: date.timeIntervalSinceReferenceDate,
            fade: fade,
            points: points,
            color: color(1),
            isMono: isMono
        )
    }

    // Draws a chain of stars. Each word grows one line across the time it's sung, stepping
    // forward on every syllable, and the tip flares as each syllable lands.
    private static func trace(
        in graphics: inout GraphicsContext,
        stars: [Int],
        words: [SungWord],
        start: Double,
        now: Double,
        fade: Double,
        points: [CGPoint],
        color: Color,
        isMono: Bool
    ) {
        guard now >= start else { return }
        star(in: &graphics, at: points[stars[0]], age: now - start, fade: fade, color: color, isMono: isMono)
        for (index, word) in words.enumerated() where index + 1 < stars.count {
            guard let latest = word.latest(at: now) else { break }
            let progress = word.progress(at: now)
            let from = points[stars[index]]
            let target = points[stars[index + 1]]
            let tip = CGPoint(x: from.x + (target.x - from.x) * progress, y: from.y + (target.y - from.y) * progress)
            var segment = Path()
            segment.move(to: from)
            segment.addLine(to: tip)
            graphics.stroke(segment, with: .color(color.opacity(0.18 * fade)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            graphics.stroke(segment, with: .color(color.opacity(0.9 * fade)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            if progress >= 1 {
                star(in: &graphics, at: target, age: now - word.end, fade: fade, color: color, isMono: isMono)
            } else {
                let flare = exp(-(now - latest) / 0.15)
                graphics.fill(dot(tip, 2 + flare * 6, isMono), with: .color(color.opacity((0.3 + flare * 0.6) * fade)))
            }
        }
    }

    private static func star(in graphics: inout GraphicsContext, at point: CGPoint, age: Double, fade: Double, color: Color, isMono: Bool) {
        let flare = exp(-age / 0.35)
        graphics.fill(dot(point, 4 + flare * 12, isMono), with: .color(color.opacity((0.2 + flare * 0.5) * fade)))
        graphics.fill(dot(point, 2.4 + flare * 1.5, isMono), with: .color(.white.opacity(fade)))
    }

    private static func chain(length: Int, seed: Double, points: [CGPoint], open: CGRect, span: CGFloat, avoiding taken: Set<Int>) -> [Int] {
        var stars = [start(seed: seed, points: points, open: open, avoiding: taken)]
        while stars.count < length {
            stars.append(next(after: stars.last!, seed: seed + Double(stars.count), points: points, open: open, span: span, avoiding: taken.union(stars)))
        }
        return stars
    }

    private static func start(seed: Double, points: [CGPoint], open: CGRect, avoiding taken: Set<Int>) -> Int {
        let candidates = (0..<starCount).filter { open.contains(points[$0]) && !taken.contains($0) }
        guard !candidates.isEmpty else { return 0 }
        return candidates[Int(noise(seed * 7.13) * Double(candidates.count))]
    }

    // A nearby star, not too close, picked from the few nearest so the shape wanders.
    private static func next(after star: Int, seed: Double, points: [CGPoint], open: CGRect, span: CGFloat, avoiding taken: Set<Int>) -> Int {
        let from = points[star]
        let nearby = (0..<starCount)
            .filter { open.contains(points[$0]) && !taken.contains($0) && $0 != star }
            .map { ($0, distance(from, points[$0])) }
            .filter { $0.1 > span * 0.3 }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
        guard !nearby.isEmpty else { return star }
        return nearby[Int(noise(seed * 3.31) * Double(nearby.count))].0
    }

    // Keeps vocal constellations on screen and clear of the corner card.
    private static func openArea(_ size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: size.height - 240).insetBy(dx: size.width * 0.08, dy: size.height * 0.08)
    }

    private static func dot(_ point: CGPoint, _ radius: CGFloat, _ isMono: Bool) -> Path {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        return isMono ? Path(rect) : Path(ellipseIn: rect)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func noise(_ value: Double) -> Double {
        let x = sin(value * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
}

// Track info and transport tucked into the bottom-left corner. While idle the
// controls step aside and the track info grows to fill the card.
private struct ConstellationCorner: View {
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store
    @Environment(\.uiTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: chromeVisible ? 14 : 18) {
                ArtworkImage(image: store.artwork)
                    .frame(width: artSize, height: artSize)
                    .clipShape(.rect(cornerRadius: theme.cornerRadius(chromeVisible ? 10 : 16), style: .continuous))
                VStack(alignment: .leading, spacing: chromeVisible ? 2 : 5) {
                    Text(store.track?.title ?? "")
                        .font(theme.font(chromeVisible ? 16 : 24, .heavy))
                        .lineLimit(chromeVisible ? 1 : 2)
                        .minimumScaleFactor(0.8)
                    Text(store.track?.artist ?? "")
                        .font(theme.font(chromeVisible ? 13 : 17, .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
            }

            if chromeVisible {
                controls.transition(.opacity)
            }
        }
        .frame(width: 300, height: Self.contentHeight, alignment: chromeVisible ? .topLeading : .leading)
        .padding(16)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: theme.cornerRadius(20), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius(20), style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // Tall enough for the art, progress and buttons stacked.
    private static let contentHeight: CGFloat = 158

    private var artSize: CGFloat { chromeVisible ? 56 : Self.contentHeight }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressRow()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 8) {
                    PlayerButton(symbol: "backward.fill", title: "PREV", diameter: 38, iconSize: 13, action: store.previous)
                    PlayerButton(
                        symbol: store.isPlaying ? "pause.fill" : "play.fill",
                        title: store.isPlaying ? "PAUSE" : "PLAY",
                        diameter: 46,
                        iconSize: 17,
                        monoWidth: 70,
                        action: store.togglePlayPause
                    )
                    PlayerButton(symbol: "forward.fill", title: "NEXT", diameter: 38, iconSize: 13, action: store.next)
                }
            }
        }
    }
}


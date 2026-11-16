import SwiftUI

// Flying down a tunnel made of the music. Every ring is the spectrum at the moment it
// formed, so the song's shape streams past. Speed follows the song's hype, and each bass hit
// punches the camera, splits the colors and fires a shockwave ring.
struct SurgeView: View {
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer
    @Environment(\.uiTheme) private var theme
    @State private var motion = SurgeMotion()
    @AppStorage(FrameRate.key) private var frameRate = FrameRate.standard
    @AppStorage(FrameRate.savesBatteryKey) private var savesBattery = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TimelineView(.animation(minimumInterval: FrameRate.interval(frameRate, savesBattery: savesBattery), paused: !store.isPlaying)) { context in
                let audio = analyzer.reading
                let pulse = OrbitPulse(store: store, audio: audio, at: context.date)
                let high = audio.hasSignal ? audio.high : pulse.mid * 0.5
                ZStack {
                    Canvas { graphics, size in
                        motion.draw(
                            in: &graphics,
                            size: size,
                            pulse: pulse,
                            high: high,
                            trackID: store.track?.id,
                            date: context.date,
                            colors: store.accentColors,
                            isMono: theme == .mono
                        )
                    }
                    SurgeLyric(position: store.lyricPosition(at: context.date), bass: pulse.bass)
                        .padding(.horizontal, 60)
                }
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                StageFooter(chromeVisible: chromeVisible)
            }
        }
        .listensToMusic()
    }
}

private final class SurgeMotion {
    private struct Ring {
        var z: Double
        let shape: [Float]
        let color: Int
        // How hard the bass hit when it formed. Shockwave rings are 1.
        let strength: Double
    }

    // A ring timed to reach the edge of the screen on a beat. It's placed from its beat
    // time each frame, so it arrives on time whatever the speed does on the way.
    private struct BeatRing {
        var time: Date
        let shape: [Float]
        let color: Int
        // Matched to a bass hit actually heard, rather than only predicted.
        var confirmed: Bool
    }

    private struct Streak {
        var angle: Double
        var z: Double
        let spread: Double
    }

    private static let far = 7.0
    private static let near = 0.12
    private static let spacing = 0.2
    private static let ringPoints = 180
    private static let streakCount = 160
    // Where a beat ring is on the beat: right at the edge of the screen.
    private static let arrival = 0.4

    private var rings: [Ring] = []
    private var streaks: [Streak] = []
    private var last: Date?
    private var sinceSpawn = 0.0
    private var spawned = 0
    private var spin = 0.0
    private var kick = 0.0
    private var shake = CGSize.zero
    private var lastHitAge = Double.infinity
    private var speed = 0.6
    // Hype: how loud and how dense with beats the music is, held over a second or so.
    // Every reading this song is kept, so the moment can be ranked against the whole song.
    private var hype = 0.0
    private var hypeHistory: [Double] = []
    private var sinceSample = 0.0
    private var recentLevels: [Double] = []
    private var drop = 0.0
    private var sinceDrop = Double.infinity
    private var track: String?
    private var beatRings: [BeatRing] = []
    private var hitDates: [Date] = []
    private var period: Double?
    private var nextBeat: Date?

    func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        pulse: OrbitPulse,
        high: Double,
        trackID: String?,
        date: Date,
        colors: [Color],
        isMono: Bool
    ) {
        let step = min(last.map { date.timeIntervalSince($0) } ?? 0, 0.1)
        last = date
        let palette = isMono ? [Color.white] : colors
        // Start inside a full tunnel rather than an empty one.
        if rings.isEmpty {
            var z = Self.far
            while z > Self.near * 2 {
                rings.append(Ring(z: z, shape: pulse.spectrum.map { $0 * 0.4 }, color: spawned / 3, strength: 0))
                spawned += 1
                z -= Self.spacing
            }
        }

        // A bass hit is a hit younger than the last one seen.
        let hitAge = pulse.hits.min() ?? .infinity
        if hitAge < lastHitAge, hitAge < 0.1 {
            kick = 1
            shake = CGSize(width: Double.random(in: -1...1), height: Double.random(in: -1...1))
            hit(at: date.addingTimeInterval(-hitAge), shape: pulse.spectrum)
        }
        lastHitAge = hitAge
        kick *= exp(-step / 0.16)

        if trackID != track {
            track = trackID
            hypeHistory = []
            recentLevels = []
            beatRings = []
            hitDates = []
            period = nil
            nextBeat = nil
        }
        let level = hypeLevel(pulse: pulse, high: high, step: step)

        // A drop: from calm to the song's peak within a few seconds.
        sinceDrop += step
        if level > 0.85, (recentLevels.min() ?? 1) < 0.4, sinceDrop > 8 {
            drop = 1
            sinceDrop = 0
            kick = 1
            for _ in 0..<3 { spawn(shape: pulse.spectrum, strength: 1, palette: palette) }
        }
        drop *= exp(-step / 3)

        // Verses cruise, choruses push, the song's biggest moments rush, and a drop
        // throws everything forward on top of that.
        let target = 0.25 + pow(level, 2.2) * 3.8 + drop * 1.6
        // Surge forward quickly, ease off slowly.
        speed += (target - speed) * min(step * (target > speed ? 5 : 1.2), 1)
        let rush = min(max((speed - 0.25) / 3.8, 0), 1)
        if drop > 0.05 { kick = max(kick, drop * 0.5) }
        spin += step * (0.08 + pulse.mid * 0.5)

        scheduleBeats(now: date, shape: pulse.spectrum)
        beatRings.removeAll { Self.arrival + $0.time.timeIntervalSince(date) * speed < Self.near }

        for index in rings.indices { rings[index].z -= step * speed }
        rings.removeAll { $0.z < Self.near }
        sinceSpawn += step * speed
        while sinceSpawn >= Self.spacing {
            sinceSpawn -= Self.spacing
            spawn(shape: pulse.spectrum, strength: pulse.bass * 0.6, palette: palette)
        }

        if streaks.isEmpty {
            streaks = (0..<Self.streakCount).map { _ in Self.newStreak(z: Double.random(in: Self.near...Self.far)) }
        }
        for index in streaks.indices {
            streaks[index].z -= step * speed * 1.6
            if streaks[index].z < Self.near { streaks[index] = Self.newStreak(z: Self.far) }
        }

        // The view widens as it speeds up, which reads as more speed.
        let base = min(size.width, size.height) * 0.2 * (1.1 - rush * 0.25) * (1 + kick * 0.07)
        let center = CGPoint(
            x: size.width / 2 + shake.width * kick * 14,
            y: size.height / 2 + shake.height * kick * 14
        )

        graphics.blendMode = .plusLighter

        // The light at the end of the tunnel.
        let coreRadius = base * (0.25 + pulse.bass * 0.2)
        let core = Path(ellipseIn: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2))
        graphics.fill(core, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.5 + pulse.bass * 0.4), palette[0].opacity(0.25), palette[0].opacity(0)]),
            center: center, startRadius: 0, endRadius: coreRadius
        ))

        // Warp streaks, longer the faster it flies.
        var streakPath = Path()
        let length = 0.03 + speed * 0.1
        for streak in streaks {
            let radius = base * streak.spread
            let from = Self.project(center, radius / streak.z, streak.angle)
            let to = Self.project(center, radius / (streak.z + length), streak.angle)
            streakPath.move(to: from)
            streakPath.addLine(to: to)
        }
        graphics.stroke(streakPath, with: .color(.white.opacity(0.12 + rush * 0.6)), lineWidth: 1 + rush)

        var drawn = rings
        for beat in beatRings {
            let z = Self.arrival + beat.time.timeIntervalSince(date) * speed
            guard z <= Self.far else { continue }
            let missed = !beat.confirmed && date.timeIntervalSince(beat.time) > 0.1
            drawn.append(Ring(z: z, shape: beat.shape, color: beat.color, strength: beat.confirmed ? 1 : missed ? 0.3 : 0.75))
        }
        // Far rings first, so near ones draw over them.
        drawn.sort { $0.z > $1.z }
        for ring in drawn {
            let radius = base / ring.z
            let depthFade = min((Self.far - ring.z) / 1.6, 1) * min(ring.z / 0.5, 1)
            guard depthFade > 0.01 else { continue }
            let path = Self.ringPath(center: center, radius: radius, shape: ring.shape, twist: spin + ring.z * 0.35)
            let color = palette[ring.color % palette.count]
            // Every ring flashes on the beat, the outer ones hardest.
            let flash = kick * min(1.2 / ring.z, 1)
            let lit = max(ring.strength, flash)
            let width = max(0.8, 2.2 / ring.z) * (1 + ring.strength * 1.5 + flash * 1.2)
            if lit > 0.3 {
                graphics.stroke(path, with: .color(color.opacity(0.3 * lit * depthFade)), lineWidth: width * 5)
            }
            graphics.stroke(path, with: .color(color.opacity(min(0.35 + ring.strength * 0.5 + flash * 0.6, 1) * depthFade)), lineWidth: width)
            if flash > 0.2 {
                graphics.stroke(path, with: .color(.white.opacity(flash * 0.45 * depthFade)), lineWidth: max(width * 0.35, 1))
            }

            // On a hit, the nearest rings split into red and cyan.
            if kick > 0.15, ring.z < 1.6, !isMono {
                let offset = kick * 9
                var red = graphics
                red.translateBy(x: offset, y: 0)
                red.stroke(path, with: .color(.red.opacity(0.4 * kick * depthFade)), lineWidth: width)
                var cyan = graphics
                cyan.translateBy(x: -offset, y: 0)
                cyan.stroke(path, with: .color(.cyan.opacity(0.4 * kick * depthFade)), lineWidth: width)
            }
        }

        if kick > 0.02 {
            graphics.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette[0].opacity(kick * 0.06)))
        }

        graphics.blendMode = .normal
        let vignette = Path(CGRect(origin: .zero, size: size))
        graphics.fill(vignette, with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.75)]),
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            startRadius: min(size.width, size.height) * 0.3,
            endRadius: max(size.width, size.height) * 0.75
        ))
    }

    // A bass hit lands on the predicted ring nearest it, which lights up for good, and the
    // beats after it are predicted again from this hit.
    private func hit(at time: Date, shape: [Float]) {
        hitDates.append(time)
        if hitDates.count > 12 { hitDates.removeFirst() }
        period = Self.steadyPeriod(hitDates)

        let tolerance = (period ?? 0.4) * 0.3
        if let index = beatRings.firstIndex(where: { !$0.confirmed && abs($0.time.timeIntervalSince(time)) < tolerance }) {
            beatRings[index].time = time
            beatRings[index].confirmed = true
        } else {
            // Nothing predicted it, so it appears right at the edge.
            beatRings.append(BeatRing(time: time, shape: shape, color: spawned / 3, confirmed: true))
            spawned += 1
        }
        beatRings.removeAll { !$0.confirmed && $0.time > time }
        nextBeat = period.map { time.addingTimeInterval($0) }
    }

    // Sends rings down the tunnel ahead of the predicted beats, far enough out to fly in.
    // Prediction stops a few seconds after the last real hit, when the beat has dropped out.
    private func scheduleBeats(now: Date, shape: [Float]) {
        guard let period, var next = nextBeat, let lastHit = hitDates.last else { return }
        while next < now { next.addTimeInterval(period) }
        let horizon = (Self.far - Self.arrival) / max(speed, 0.1)
        while next.timeIntervalSince(now) < horizon, next.timeIntervalSince(lastHit) < 4 {
            beatRings.append(BeatRing(time: next, shape: shape, color: spawned / 3, confirmed: false))
            spawned += 1
            next.addTimeInterval(period)
        }
        nextBeat = next
    }

    // The beat's period, when the recent hits keep a steady tempo. A skipped beat (a gap
    // of two) still counts as steady.
    private static func steadyPeriod(_ hits: [Date]) -> Double? {
        let gaps = zip(hits, hits.dropFirst()).map { $1.timeIntervalSince($0) }.filter { (0.25...1.6).contains($0) }
        guard gaps.count >= 4 else { return nil }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let steady = gaps.filter { gap in
            [1.0, 2.0].contains { abs(gap / median - $0) < 0.15 * $0 }
        }
        return Double(steady.count) >= Double(gaps.count) * 0.6 ? median : nil
    }

    // Where this moment's hype ranks among everything heard so far in the song, from 0 to 1.
    // Early on, before there's much to compare with, it leans on the hype itself.
    private func hypeLevel(pulse: OrbitPulse, high: Double, step: Double) -> Double {
        let loudness = pulse.bass * 0.45 + pulse.mid * 0.35 + high * 0.2
        let beatsPerSecond = Double(pulse.hits.filter { $0 < 2 }.count) / 2
        let raw = loudness * 0.65 + min(beatsPerSecond / 3, 1) * 0.35
        hype += (raw - hype) * min(step / 1.2, 1)

        sinceSample += step
        if sinceSample >= 0.2 {
            sinceSample = 0
            hypeHistory.append(hype)
            if hypeHistory.count > 3000 { hypeHistory.removeFirst() }
        }
        let rank = hypeHistory.isEmpty ? 0.5 : Double(hypeHistory.filter { $0 < hype }.count) / Double(hypeHistory.count)
        let absolute = min(max((hype - 0.15) / 0.5, 0), 1)
        let trust = min(Double(hypeHistory.count) / 150, 1)
        let level = absolute + (rank - absolute) * trust

        if sinceSample == 0 {
            recentLevels.append(level)
            if recentLevels.count > 20 { recentLevels.removeFirst() }
        }
        return level
    }

    private func spawn(shape: [Float], strength: Double, palette: [Color]) {
        rings.append(Ring(z: Self.far, shape: shape, color: spawned / 3, strength: strength))
        spawned += 1
    }

    private static func newStreak(z: Double) -> Streak {
        Streak(angle: .random(in: 0..<(2 * .pi)), z: z, spread: .random(in: 1.2...4))
    }

    private static func project(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
    }

    // The spectrum wrapped round the ring, mirrored so it has no seam and eased between
    // bands so the ring stays liquid.
    private static func ringPath(center: CGPoint, radius: CGFloat, shape: [Float], twist: Double) -> Path {
        var path = Path()
        let count = shape.count
        func band(_ index: Int) -> Double {
            let position = index % (count * 2)
            return Double(shape[position < count ? position : count * 2 - 1 - position])
        }
        for point in 0...ringPoints {
            let angle = Double(point) / Double(ringPoints) * 2 * .pi + twist
            var value = 0.0
            if count > 0 {
                let position = Double(point) * Double(count * 2) / Double(ringPoints)
                let lower = Int(position)
                let blend = position - Double(lower)
                let eased = blend * blend * (3 - 2 * blend)
                value = band(lower) + (band(lower + 1) - band(lower)) * eased
            }
            let location = project(center, radius * (1 + CGFloat(value) * 0.5), angle)
            if point == 0 { path.move(to: location) } else { path.addLine(to: location) }
        }
        return path
    }
}

// Each sung word slams onto the screen, with the whole line small beneath it.
private struct SurgeLyric: View {
    let position: Double
    let bass: Double

    @Environment(PlayerStore.self) private var store
    @Environment(\.uiTheme) private var theme
    @Environment(\.lyricFont) private var lyricFont
    @Environment(\.lyricScale) private var scale
    @Environment(\.lyricColors) private var colors

    var body: some View {
        VStack(spacing: 14) {
            if let line = currentLine {
                if let words = line.words, let index = words.lastIndex(where: { $0.time <= position }) {
                    let word = words[index]
                    let punch = exp(-max(position - word.time, 0) / 0.14)
                    Text(word.text)
                        .font(lyricFont.font(96 * scale, .black, theme: theme))
                        .foregroundStyle(colors.highlight)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                        .scaleEffect(1 + punch * 0.3 + bass * 0.05)
                        .blur(radius: punch * 6)
                        .shadow(color: colors.highlight.opacity(0.5), radius: 30)
                        .id("\(line.id)-\(index)")
                    Text(line.text)
                        .font(lyricFont.font(20 * scale, .bold, theme: theme))
                        .foregroundStyle(colors.text.opacity(0.55))
                        .lineLimit(2)
                } else {
                    let punch = exp(-max(position - line.time, 0) / 0.2)
                    Text(line.text)
                        .font(lyricFont.font(54 * scale, .black, theme: theme))
                        .foregroundStyle(colors.highlight)
                        .lineLimit(3)
                        .minimumScaleFactor(0.4)
                        .scaleEffect(1 + punch * 0.18 + bass * 0.04)
                        .blur(radius: punch * 5)
                        .shadow(color: colors.highlight.opacity(0.45), radius: 30)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private var currentLine: LyricLine? {
        guard case .synced(let lines) = store.lyrics,
              let index = lines.lastIndex(where: { $0.time <= position }),
              !lines[index].isInterlude else { return nil }
        return lines[index]
    }
}

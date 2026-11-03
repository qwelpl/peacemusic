import SwiftUI

struct LyricsPanel: View {
    @Environment(\.uiTheme) private var theme
    @Environment(PlayerStore.self) private var store
    @AppStorage(LyricSettings.styleKey) private var styleRaw = LyricStyle.classic.rawValue
    @AppStorage(LyricSettings.fontKey) private var fontRaw = LyricFont.theme.rawValue
    @AppStorage(LyricSettings.scaleKey) private var scale = 1.0
    // Read so the panel redraws when a color changes.
    @AppStorage(LyricColorSlot.autoSyncKey) private var autoSync = false
    @AppStorage(LyricColorSlot.text.key) private var textHex = ""
    @AppStorage(LyricColorSlot.highlight.key) private var highlightHex = ""
    @AppStorage(LyricColorSlot.secondary.key) private var secondaryHex = ""

    private var lyricFont: LyricFont { LyricFont(rawValue: fontRaw) ?? .theme }
    private var colors: LyricColors { LyricColorSlot.resolved(mesh: store.meshColors) }

    var body: some View {
        Group {
            switch store.lyrics {
            case .synced(let lines):
                SyncedLyrics(lines: lines)
            case .plain(let text):
                ScrollView(showsIndicators: false) {
                    Text(text)
                        .font(lyricFont.font(26 * scale, .semibold, theme: theme))
                        .lineSpacing(10 * scale)
                        .foregroundStyle(colors.text.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 90)
                }
            case .instrumental:
                LyricsMessage(text: "Instrumental")
            case .loading:
                InterludeDots(isActive: true).frame(maxWidth: .infinity, alignment: .leading)
            case .none:
                LyricsMessage(text: "No lyrics for this one")
            }
        }
        .environment(\.lyricStyle, LyricStyle(rawValue: styleRaw) ?? .classic)
        .environment(\.lyricFont, lyricFont)
        .environment(\.lyricScale, scale)
        .environment(\.lyricColors, colors)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

private struct LyricsMessage: View {
    @Environment(\.uiTheme) private var theme
    @Environment(\.lyricFont) private var lyricFont
    @Environment(\.lyricScale) private var scale
    @Environment(\.lyricColors) private var colors
    let text: String

    var body: some View {
        Text(text)
            .font(lyricFont.font(30 * scale, .bold, theme: theme))
            .foregroundStyle(colors.secondary.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]

    @Environment(PlayerStore.self) private var store
    @Environment(\.lyricScale) private var scale
    @Environment(\.lyricStyle) private var style
    @Environment(\.lyricColors) private var colors

    private var spacing: CGFloat { (style.layout == .terminal ? 4 : 30) * scale }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: style.isCentered ? .center : .leading, spacing: spacing) {
                        ForEach(lines) { line in
                            LyricRow(
                                line: line,
                                distance: distance(of: line),
                                isFirst: line.id == lines.first?.id,
                                isLast: line.id == lines.last?.id,
                                spacing: spacing,
                                indent: style.layout == .stars ? starIndent(for: line, width: geometry.size.width) : 0
                            )
                            .id(line.id)
                        }
                    }
                    .backgroundPreferenceValue(StarAnchors.self) { stars in
                        if style.layout == .stars { starLines(stars) }
                    }
                    .padding(.vertical, geometry.size.height * 0.42)
                }
                .onChange(of: store.lyricIndex, initial: true) { _, index in
                    withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) {
                        proxy.scrollTo(index ?? lines.first?.id, anchor: UnitPoint(x: style.isCentered ? 0.5 : 0, y: 0.38))
                    }
                }
            }
        }
    }

    // Scatters stars across the left third, stable per line.
    private func starIndent(for line: LyricLine, width: CGFloat) -> CGFloat {
        let seed = UInt64(truncatingIfNeeded: line.id &* 2_654_435_761)
        return CGFloat(seed % 1000) / 1000 * width * 0.3
    }

    private func starLines(_ stars: [Int: Anchor<CGPoint>]) -> some View {
        GeometryReader { proxy in
            let points = stars.sorted { $0.key < $1.key }.map { proxy[$0.value] }
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(colors.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        }
    }

    private func distance(of line: LyricLine) -> Int {
        abs(line.id - (store.lyricIndex ?? -1))
    }

}

private struct StarAnchors: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGPoint>] = [:]

    static func reduce(value: inout [Int: Anchor<CGPoint>], nextValue: () -> [Int: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LyricRow: View {
    @Environment(\.uiTheme) private var theme
    @Environment(\.lyricFont) private var lyricFont
    @Environment(\.lyricScale) private var scale
    @Environment(\.lyricColors) private var colors
    @Environment(\.lyricStyle) private var style
    let line: LyricLine
    let distance: Int
    let isFirst: Bool
    let isLast: Bool
    let spacing: CGFloat
    let indent: CGFloat

    @Environment(PlayerStore.self) private var store
    @State private var isHovered = false

    private var isActive: Bool { distance == 0 }
    private var anchor: UnitPoint { style.isCentered ? .center : .leading }

    var body: some View {
        Button {
            store.seek(to: line.time)
        } label: {
            row
                .frame(maxWidth: .infinity, alignment: style.isCentered ? .center : .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .blur(radius: blur)
        .opacity(isActive ? 1 : isHovered ? 0.8 : restingOpacity)
        .scaleEffect(rowScale, anchor: anchor)
        .modifier(AudioPulse(
            isOn: style.isPulsing && isActive,
            strength: style.layout == .terminal ? 0.015 : 0.06,
            color: colors.highlight,
            anchor: anchor
        ))
        .animation(.spring(response: 0.6, dampingFraction: 0.78), value: distance)
    }

    private var blur: Double {
        guard style.layout == .classic, !isHovered, theme == .glass else { return 0 }
        return min(Double(distance) * 0.9, 4.5)
    }

    private var restingOpacity: Double {
        let distance = Double(distance)
        switch style.layout {
        case .classic: return max(0.5 - distance * 0.05, 0.22)
        case .lens: return max(0.85 - distance * 0.14, 0.2)
        case .terminal: return 0.5
        case .graph: return max(0.6 - distance * 0.06, 0.25)
        case .centered: return max(0.8 - distance * 0.15, 0.18)
        case .stars: return max(0.7 - distance * 0.08, 0.2)
        }
    }

    private var rowScale: CGFloat {
        let distance = CGFloat(distance)
        switch style.layout {
        case .classic: return isActive || theme == .mono ? 1 : 0.95
        case .lens: return max(1 - distance * 0.13, 0.45)
        case .centered: return max(1 - distance * 0.08, 0.6)
        case .terminal, .graph, .stars: return 1
        }
    }

    @ViewBuilder
    private var row: some View {
        switch style.layout {
        case .classic, .lens, .centered:
            content
        case .terminal:
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(String(format: "%3d", line.id + 1))
                    .font(.system(size: 13 * scale, weight: .regular, design: .monospaced))
                    .foregroundStyle(colors.secondary.opacity(isActive ? 0.8 : 0.35))
                content
            }
            .padding(.vertical, 6 * scale)
            .padding(.horizontal, 10)
            .background(alignment: .leading) {
                if isActive {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.07))
                        Rectangle().fill(colors.highlight).frame(width: 3)
                    }
                }
            }
        case .graph:
            content
                .padding(.leading, 44)
                .background(alignment: .leading) {
                    BranchNode(
                        lane: line.id % 4 == 1 || line.id % 4 == 2 ? 1 : 0,
                        isActive: isActive,
                        isFirst: isFirst,
                        isLast: isLast,
                        color: colors.highlight
                    )
                    .frame(width: 36)
                    .padding(.vertical, -spacing / 2)
                }
        case .stars:
            HStack(spacing: 14) {
                Circle()
                    .fill(isActive ? colors.highlight : colors.secondary.opacity(0.7))
                    .frame(width: isActive ? 11 : 6, height: isActive ? 11 : 6)
                    .shadow(color: colors.highlight.opacity(isActive ? 0.9 : 0), radius: 8)
                    .anchorPreference(key: StarAnchors.self, value: .center) { [line.id: $0] }
                    .frame(width: 12)
                content
            }
            .padding(.leading, indent)
        }
    }

    @ViewBuilder
    private var content: some View {
        if line.isInterlude {
            InterludeDots(isActive: isActive)
        } else if isActive, let words = line.words {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { context in
                wordTimedText(words, position: store.lyricPosition(at: context.date))
            }
        } else {
            Text(line.text)
                .font(font)
                .foregroundStyle(isActive ? colors.text : colors.secondary)
                .multilineTextAlignment(style.isCentered ? .center : .leading)
        }
    }

    private var font: Font {
        style.layout == .terminal
            ? .system(size: 24 * scale, weight: .semibold, design: .monospaced)
            : lyricFont.font(40 * scale, .heavy, theme: theme)
    }

    private func wordTimedText(_ words: [LyricWord], position: Double) -> Text {
        var string = AttributedString()
        for (index, word) in words.enumerated() {
            let lit = min(max((position - word.time) / max(word.duration, 0.12), 0), 1)
            var piece = AttributedString(index == 0 ? word.text : " " + word.text)
            switch theme {
            case .glass:
                piece.foregroundColor = lit > 0 ? colors.highlight.opacity(0.4 + 0.6 * lit) : colors.text.opacity(0.4)
            case .mono:
                piece.foregroundColor = lit > 0 ? colors.highlight : colors.text.opacity(0.32)
            }
            string += piece
        }
        return Text(string).font(font)
    }
}

private struct AudioPulse: ViewModifier {
    let isOn: Bool
    let strength: Double
    let color: Color
    let anchor: UnitPoint

    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer

    func body(content: Content) -> some View {
        if isOn {
            TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !store.isPlaying)) { _ in
                let audio = analyzer.reading
                content
                    .scaleEffect(1 + audio.bass * strength, anchor: anchor)
                    .shadow(color: color.opacity(0.25 + audio.mid * 0.45), radius: 4 + audio.bass * 16)
            }
        } else {
            content
        }
    }
}

// A git graph rail: a trunk with some lines stepping out onto a branch.
private struct BranchNode: View {
    let lane: Int
    let isActive: Bool
    let isFirst: Bool
    let isLast: Bool
    let color: Color

    var body: some View {
        Canvas { context, size in
            let trunk: CGFloat = 8
            let branch: CGFloat = 28
            let midY = size.height / 2
            let rail = GraphicsContext.Shading.color(.white.opacity(0.28))
            let stroke = StrokeStyle(lineWidth: 2, lineCap: .round)

            var line = Path()
            line.move(to: CGPoint(x: trunk, y: isFirst ? midY : 0))
            line.addLine(to: CGPoint(x: trunk, y: isLast ? midY : size.height))
            context.stroke(line, with: rail, style: stroke)

            var node = CGPoint(x: trunk, y: midY)
            if lane == 1 {
                node.x = branch
                let reach = min(size.height / 2, 26)
                var arc = Path()
                arc.move(to: CGPoint(x: trunk, y: midY - reach))
                arc.addCurve(
                    to: node,
                    control1: CGPoint(x: trunk, y: midY - reach / 3),
                    control2: CGPoint(x: branch, y: midY - reach * 2 / 3)
                )
                arc.addCurve(
                    to: CGPoint(x: trunk, y: midY + reach),
                    control1: CGPoint(x: branch, y: midY + reach * 2 / 3),
                    control2: CGPoint(x: trunk, y: midY + reach / 3)
                )
                context.stroke(arc, with: rail, style: stroke)
            }

            let radius: CGFloat = isActive ? 7 : 4.5
            let dot = Path(ellipseIn: CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(isActive ? color : .white.opacity(0.55)))
        }
    }
}

private struct InterludeDots: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(time * 2.4 - Double(index) * 0.8) + 1) / 2
                    Circle()
                        .fill(.white)
                        .frame(width: 13, height: 13)
                        .scaleEffect(isActive ? 0.75 + wave * 0.35 : 0.75)
                        .opacity(isActive ? 0.45 + wave * 0.55 : 0.5)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

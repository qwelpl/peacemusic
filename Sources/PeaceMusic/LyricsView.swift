import SwiftUI

struct LyricsPanel: View {
    @Environment(\.uiTheme) private var theme
    @Environment(PlayerStore.self) private var store
    @AppStorage(LyricSettings.fontKey) private var fontRaw = LyricFont.theme.rawValue
    @AppStorage(LyricSettings.scaleKey) private var scale = 1.0

    private var lyricFont: LyricFont { LyricFont(rawValue: fontRaw) ?? .theme }

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
                        .foregroundStyle(.white.opacity(0.85))
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
        .environment(\.lyricFont, lyricFont)
        .environment(\.lyricScale, scale)
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
    let text: String

    var body: some View {
        Text(text)
            .font(lyricFont.font(30 * scale, .bold, theme: theme))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]

    @Environment(PlayerStore.self) private var store
    @Environment(\.lyricScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30 * scale) {
                        ForEach(lines) { line in
                            LyricRow(line: line, distance: distance(of: line))
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, geometry.size.height * 0.42)
                }
                .onChange(of: store.lyricIndex, initial: true) { _, index in
                    withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) {
                        proxy.scrollTo(index ?? lines.first?.id, anchor: UnitPoint(x: 0, y: 0.38))
                    }
                }
            }
        }
    }

    private func distance(of line: LyricLine) -> Int {
        abs(line.id - (store.lyricIndex ?? -1))
    }

}

private struct LyricRow: View {
    @Environment(\.uiTheme) private var theme
    @Environment(\.lyricFont) private var lyricFont
    @Environment(\.lyricScale) private var scale
    let line: LyricLine
    let distance: Int

    @Environment(PlayerStore.self) private var store
    @State private var isHovered = false

    private var isActive: Bool { distance == 0 }

    var body: some View {
        Button {
            store.seek(to: line.time)
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .blur(radius: isHovered || theme == .mono ? 0 : min(Double(distance) * 0.9, 4.5))
        .opacity(isActive ? 1 : isHovered ? 0.8 : max(0.5 - Double(distance) * 0.05, 0.22))
        .scaleEffect(isActive || theme == .mono ? 1 : 0.95, anchor: .leading)
        .animation(.spring(response: 0.6, dampingFraction: 0.78), value: distance)
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
            Text(line.text).font(font).foregroundStyle(.white)
        }
    }

    private var font: Font { lyricFont.font(40 * scale, .heavy, theme: theme) }

    private func wordTimedText(_ words: [LyricWord], position: Double) -> Text {
        var string = AttributedString()
        for (index, word) in words.enumerated() {
            let lit = min(max((position - word.time) / max(word.duration, 0.12), 0), 1)
            var piece = AttributedString(index == 0 ? word.text : " " + word.text)
            let brightness = theme == .glass ? 0.4 + 0.6 * lit : (lit > 0 ? 1 : 0.32)
            piece.foregroundColor = .white.opacity(brightness)
            string += piece
        }
        return Text(string).font(font)
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

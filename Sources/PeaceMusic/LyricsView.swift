import SwiftUI

struct LyricsPanel: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Group {
            switch store.lyrics {
            case .synced(let lines):
                SyncedLyrics(lines: lines)
            case .plain(let text):
                ScrollView(showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .lineSpacing(10)
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
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]

    @Environment(PlayerStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(lines) { line in
                            LyricRow(
                                line: line,
                                end: endTime(of: line),
                                distance: distance(of: line)
                            )
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

    private func endTime(of line: LyricLine) -> Double {
        line.id + 1 < lines.count ? lines[line.id + 1].time : line.time + 5
    }
}

private struct LyricRow: View {
    let line: LyricLine
    let end: Double
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
        .blur(radius: isHovered ? 0 : min(Double(distance) * 0.9, 4.5))
        .opacity(isActive ? 1 : isHovered ? 0.8 : max(0.5 - Double(distance) * 0.05, 0.22))
        .scaleEffect(isActive ? 1 : 0.95, anchor: .leading)
        .animation(.spring(response: 0.6, dampingFraction: 0.78), value: distance)
    }

    @ViewBuilder
    private var content: some View {
        if line.isInterlude {
            InterludeDots(isActive: isActive)
        } else if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { context in
                sweepingText(progress: progress(at: context.date))
            }
        } else {
            lyricText.foregroundStyle(.white)
        }
    }

    private var lyricText: Text {
        Text(line.text).font(.system(size: 40, weight: .heavy, design: .rounded))
    }

    private func progress(at date: Date) -> Double {
        guard end > line.time else { return 1 }
        return min(max((store.position(at: date) - line.time) / (end - line.time), 0), 1)
    }

    private func sweepingText(progress: Double) -> some View {
        // The wide soft edge stays off-screen at both ends of the sweep.
        let edge = progress * 1.4 - 0.2
        return lyricText
            .foregroundStyle(.white.opacity(0.42))
            .overlay(alignment: .leading) {
                lyricText
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.45), radius: 16)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: max(edge - 0.1, 0)),
                                .init(color: .clear, location: min(max(edge + 0.1, 0.001), 1)),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
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

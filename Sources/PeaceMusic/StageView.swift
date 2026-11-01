import AppKit
import SwiftUI

struct StageView: View {
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FluidBackground(colors: store.meshColors, trackID: store.track?.id, isPlaying: store.isPlaying)
                .opacity(0.22)

            VStack(spacing: 14) {
                GeometryReader { geometry in
                    let content = content
                    StagePoster(content: content, size: geometry.size)
                        .id(content.key)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 1.05).combined(with: .opacity)
                                .animation(.spring(response: 0.3, dampingFraction: 0.86).delay(0.07)),
                            removal: .opacity.animation(.easeOut(duration: 0.07))
                        ))
                }
                .animation(.default, value: content.key)
                .padding(.horizontal, 28)
                .padding(.top, 56)

                StageFooter(chromeVisible: chromeVisible)
            }
        }
    }

    private var content: StageContent {
        let title = store.track?.title ?? ""
        let fallback = StageContent(key: "\(store.track?.id ?? "")-title", text: title, wordTimes: nil)
        guard case .synced(let lines) = store.lyrics,
              let index = store.lyricIndex,
              !lines[index].isInterlude else { return fallback }

        let line = lines[index]
        return StageContent(
            key: "\(store.track?.id ?? "")-\(line.id)",
            text: line.text,
            wordTimes: line.words?.map(\.time)
        )
    }
}

private struct StageContent {
    let key: String
    let text: String
    let wordTimes: [Double]?
}

private struct StagePoster: View {
    let content: StageContent
    let size: CGSize
    private let layout: StageLayout

    @Environment(PlayerStore.self) private var store

    init(content: StageContent, size: CGSize) {
        self.content = content
        self.size = size
        layout = StageLayout(text: content.text, size: size)
    }

    var body: some View {
        TimelineView(.animation(paused: !store.isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            artFill(time: time)
                .mask { rows(position: store.lyricPosition(at: context.date)) }
        }
        .frame(width: size.width, height: size.height)
    }

    private func artFill(time: Double) -> some View {
        ZStack {
            Group {
                if let artwork = store.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: size.width, height: size.height)
            .saturation(1.25)
            .scaleEffect(1.3 + sin(time * 0.11) * 0.06)
            .offset(x: sin(time * 0.17) * size.width * 0.05, y: cos(time * 0.13) * size.height * 0.05)

            Color.white.opacity(0.16)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func rows(position: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(layout.rows) { row in
                HStack(spacing: row.fontSize * StageLayout.wordGap) {
                    ForEach(row.words) { word in
                        wordView(word, fontSize: row.fontSize, position: position)
                    }
                }
                .frame(height: row.fontSize * StageLayout.rowHeight)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func wordView(_ word: StageWord, fontSize: CGFloat, position: Double) -> some View {
        let reveal = revealAmount(of: word, position: position)
        let eased = 1 - pow(1 - reveal, 3)
        return Text(word.text)
            .font(Font(StageLayout.font(size: fontSize)))
            .lineLimit(1)
            .fixedSize()
            .opacity(0.13 + 0.87 * eased)
            .offset(y: (1 - eased) * fontSize * 0.1)
    }

    private func revealAmount(of word: StageWord, position: Double) -> Double {
        guard let times = content.wordTimes, word.id < times.count else { return 1 }
        return min(max((position - times[word.id]) / 0.2, 0), 1)
    }
}

private struct StageWord: Identifiable {
    let id: Int
    let text: String
}

private struct StageRow: Identifiable {
    let id: Int
    let words: [StageWord]
    let fontSize: CGFloat
}

private struct StageLayout {
    static let wordGap: CGFloat = 0.2
    static let rowHeight: CGFloat = 0.86
    private static let maxRows = 6

    let rows: [StageRow]

    static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .black, width: .compressed)
    }

    init(text: String, size: CGSize) {
        let words = text.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, size.width > 0, size.height > 0 else {
            rows = []
            return
        }
        let referenceFont = Self.font(size: 100)
        let widths = words.map { ($0 as NSString).size(withAttributes: [.font: referenceFont]).width }

        var best: (score: CGFloat, groups: [Range<Int>], scale: CGFloat) = (-1, [], 1)
        for rowCount in 1...min(words.count, Self.maxRows) {
            let groups = Self.split(words: words, into: rowCount)
            let height = groups.reduce(CGFloat(0)) { total, group in
                total + Self.fontSize(for: group, widths: widths, width: size.width) * Self.rowHeight
            }
            let scale = min(1, size.height / height)
            let score = scale * min(1, height / size.height)
            if score > best.score {
                best = (score, groups, scale)
            }
        }

        rows = best.groups.enumerated().map { rowIndex, group in
            let rowWords = group.map { StageWord(id: $0, text: words[$0]) }
            let fontSize = Self.fontSize(for: group, widths: widths, width: size.width) * best.scale
            return StageRow(id: rowIndex, words: rowWords, fontSize: fontSize)
        }
    }

    private static func fontSize(for group: Range<Int>, widths: [CGFloat], width: CGFloat) -> CGFloat {
        let wordsWidth = group.reduce(CGFloat(0)) { $0 + widths[$1] }
        let gaps = CGFloat(group.count - 1) * wordGap * 100
        return width / (wordsWidth + gaps) * 100
    }

    private static func split(words: [String], into rowCount: Int) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        var remainingCharacters = words.reduce(0) { $0 + $1.count }
        for row in 0..<rowCount {
            let rowsLeft = rowCount - row
            if rowsLeft == 1 {
                groups.append(start..<words.count)
                break
            }
            let target = Double(remainingCharacters) / Double(rowsLeft)
            var end = start + 1
            var characters = words[start].count
            while end < words.count - (rowsLeft - 1), Double(characters) + Double(words[end].count) / 2 < target {
                characters += words[end].count
                end += 1
            }
            groups.append(start..<end)
            remainingCharacters -= characters
            start = end
        }
        return groups
    }
}

private struct StageFooter: View {
    @Environment(\.uiTheme) private var theme
    let chromeVisible: Bool

    @Environment(PlayerStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(image: store.artwork)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: theme.cornerRadius(10), style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.track?.title ?? "")
                    .font(theme.font(15, .heavy))
                    .lineLimit(1)
                Text(store.track?.artist ?? "")
                    .font(theme.font(13, .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 24)
            HStack(spacing: 18) {
                ProgressRow().frame(width: 280)
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
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }
}

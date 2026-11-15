import SwiftUI

// The parts of Peace the Settings preview can show, picked with its tabs.
enum PreviewTopic: String, CaseIterable {
    case nowPlaying, lyrics, window, miniPlayer, performance

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .lyrics: "Lyrics"
        case .window: "Window"
        case .miniPlayer: "Mini Player"
        case .performance: "Motion"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .lyrics: "quote.bubble"
        case .window: "macwindow"
        case .miniPlayer: "pip"
        case .performance: "gauge.with.dots.needle.67percent"
        }
    }
}

// The live preview beside Settings. It draws the real views, so every change shows as you make it.
struct SettingsPreview: View {
    @Binding var topic: PreviewTopic

    @Environment(PlayerStore.self) private var store
    @Environment(\.songTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Preview").font(.system(size: 15, weight: .heavy))
                Spacer()
                if store.track == nil {
                    Text("Play a song to see it live")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            tabs
            ZStack {
                switch topic {
                case .nowPlaying: NowPlayingPreview()
                case .lyrics: LyricsPreview()
                case .window: WindowPreview()
                case .miniPlayer: MiniPlayerPreview()
                case .performance: MotionPreview()
                }
            }
            .id(topic)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .songGlass(in: .rect(cornerRadius: 22, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: topic)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(PreviewTopic.allCases, id: \.self) { item in
                Button { topic = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold))
                        Text(item.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }
                        .foregroundStyle(topic == item ? theme.onAccent : .white.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(topic == item ? theme.accent : .white.opacity(0.06), in: .rect(cornerRadius: 9, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.pointer)
            }
        }
    }
}

// Draws a full-size view and scales it down to fit the preview's width.
private struct Scaled<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / size.width
            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: size.height * scale, alignment: .topLeading)
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NowPlayingPreview: View {
    @AppStorage("playerMode") private var modeRaw = PlayerMode.turntable.rawValue
    @AppStorage("uiTheme") private var themeRaw = UITheme.glass.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Scaled(size: CGSize(width: 1280, height: 800)) {
                NowPlayingView(isPreview: true)
            }
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            Caption(text: "\(PlayerMode(rawValue: modeRaw)?.title ?? "Turntable") · \(themeRaw == UITheme.mono.rawValue ? "Mono" : "Glass")")
        }
    }
}

private struct LyricsPreview: View {
    @Environment(PlayerStore.self) private var store
    @AppStorage("uiTheme") private var themeRaw = UITheme.glass.rawValue
    @AppStorage(LyricSettings.fontKey) private var fontRaw = LyricFont.theme.rawValue
    @AppStorage(LyricSettings.scaleKey) private var scale = 1.0
    @AppStorage(LyricSettings.styleKey) private var styleRaw = LyricStyle.classic.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Scaled(size: CGSize(width: 640, height: 720)) {
                ZStack {
                    CoverBackdrop(image: store.artwork)
                    Color.black.opacity(0.35)
                    LyricsPanel()
                        .padding(.horizontal, 48)
                }
                .environment(\.uiTheme, UITheme(rawValue: themeRaw) ?? .glass)
                .environment(\.lyricFont, LyricFont(rawValue: fontRaw) ?? .theme)
                .environment(\.lyricScale, scale)
            }
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            Caption(text: "\(LyricStyle(rawValue: styleRaw)?.title ?? "Classic") · \(LyricFont(rawValue: fontRaw)?.title ?? "") · \(Int((scale * 100).rounded()))%")
        }
    }
}

private struct WindowPreview: View {
    @AppStorage("showsSongPanel") private var showsSongPanel = true
    @AppStorage("showsLyricsCard") private var showsLyricsCard = true
    @AppStorage(ScreenAwake.key) private var keepsScreenAwake = false

    @Environment(\.songTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    block(height: 12, opacity: 0.16)
                    ForEach(0..<6, id: \.self) { _ in block(height: 7, opacity: 0.09) }
                    Spacer()
                }
                .padding(7)
                .frame(width: 58)
                .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    block(height: 52, opacity: 0.14)
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in block(height: 34, opacity: 0.09) } }
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in block(height: 34, opacity: 0.09) } }
                    Spacer()
                    Capsule().fill(.white.opacity(0.12)).frame(height: 14)
                }
                .padding(7)
                .frame(maxWidth: .infinity)

                if showsSongPanel {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 5).fill(theme.accent.opacity(0.5)).frame(height: 38)
                        if showsLyricsCard {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(0..<4, id: \.self) { index in
                                    Capsule().fill(.white.opacity(index == 1 ? 0.8 : 0.25)).frame(width: index.isMultiple(of: 2) ? 44 : 56, height: 4)
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.08), in: .rect(cornerRadius: 6))
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                        }
                        block(height: 30, opacity: 0.08)
                        Spacer()
                    }
                    .padding(7)
                    .frame(width: 78)
                    .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(6)
            .aspectRatio(16 / 10, contentMode: .fit)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showsSongPanel)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showsLyricsCard)
            Caption(text: [
                showsSongPanel ? (showsLyricsCard ? "Song panel with lyrics" : "Song panel without lyrics") : "No song panel",
                keepsScreenAwake ? "screen stays awake" : nil,
            ].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func block(height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(opacity)).frame(maxWidth: .infinity).frame(height: height)
    }
}

private struct MiniPlayerPreview: View {
    @Environment(PlayerStore.self) private var store
    @AppStorage(MiniStyle.key) private var styleRaw = MiniStyle.disc.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                CoverBackdrop(image: store.artwork).opacity(0.6)
                VStack(spacing: 18) {
                    MiniPlayerCard(expanded: false)
                    MiniPlayerCard(expanded: true)
                }
                .scaleEffect(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: styleRaw)
            Caption(text: "Small, and expanded when the pointer is over it.")
        }
    }
}

private struct MotionPreview: View {
    @AppStorage(FrameRate.key) private var frameRate = FrameRate.standard
    @AppStorage(FrameRate.savesBatteryKey) private var savesBattery = true

    @Environment(\.songTheme) private var theme

    var body: some View {
        let interval = FrameRate.interval(frameRate, savesBattery: savesBattery)
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    for index in 0..<5 {
                        let phase = time * 1.6 + Double(index) * 0.5
                        let x = size.width * (0.5 + 0.42 * sin(phase))
                        let y = size.height * (Double(index) + 0.5) / 5
                        let rect = CGRect(x: x - 9, y: y - 9, width: 18, height: 18)
                        canvas.fill(Path(ellipseIn: rect), with: .color(theme == SongTheme() ? PlayButtons.defaultColor : theme.accent))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 14, style: .continuous))
            Caption(text: "Moving at \(Int((1 / interval).rounded())) frames a second\(PowerState.shared.isSaving && savesBattery ? ", halved to save battery" : "").")
        }
    }
}

// The playing song's cover, blurred, behind a preview.
private struct CoverBackdrop: View {
    let image: NSImage?

    var body: some View {
        Color.black.overlay {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .opacity(0.8)
            }
        }
        .clipped()
    }
}

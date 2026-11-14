import AppKit
import SwiftUI

extension Notification.Name {
    // Sent by ⌘, and the menu bar, so the main window opens its own Settings page.
    static let peaceOpenSettings = Notification.Name("peace.openSettings")
}

// Every setting, inside the app, grouped the way you'd look for them.
struct SettingsPage: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @Environment(DisplayPicker.self) private var displays

    @AppStorage("playerMode") private var modeRaw = PlayerMode.turntable.rawValue
    @AppStorage("uiTheme") private var themeRaw = UITheme.glass.rawValue
    @AppStorage("heroStyle") private var heroRaw = HeroStyle.vinyl.rawValue
    @AppStorage("showsLyrics") private var showsNowPlayingLyrics = true
    @AppStorage(LyricSettings.styleKey) private var lyricStyleRaw = LyricStyle.classic.rawValue
    @AppStorage(LyricSettings.fontKey) private var lyricFontRaw = LyricFont.theme.rawValue
    @AppStorage(LyricSettings.scaleKey) private var lyricScale = 1.0
    @AppStorage(LyricColorSlot.autoSyncKey) private var colorsMatchSong = false
    @AppStorage(MiniStyle.key) private var miniStyleRaw = MiniStyle.disc.rawValue
    @AppStorage("miniShowsLyrics") private var miniShowsLyrics = true
    @AppStorage(FrameRate.key) private var frameRate = FrameRate.standard
    @AppStorage(FrameRate.savesBatteryKey) private var savesBattery = true
    @AppStorage(ScreenAwake.key) private var keepsScreenAwake = false
    @AppStorage("showsSongPanel") private var showsSongPanel = true
    @AppStorage("showsLyricsCard") private var showsLyricsCard = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(title: "Settings", subtitle: "Peace")
                VStack(alignment: .leading, spacing: 22) {
                    nowPlaying
                    lyrics
                    window
                    miniPlayerSection
                    performance
                    account
                }
                .padding(.horizontal, Layout.gutter)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .padding(.top, Layout.topInset)
            .padding(.bottom, Layout.bottomInset)
        }
        .scrollIndicators(.never)
    }

    // MARK: Sections

    private var nowPlaying: some View {
        SettingsCard(title: "Now Playing", symbol: "play.circle") {
            SettingsRow(title: "Visualizer", detail: "What fills the screen when you open Now Playing. M switches between them.") {
                ChoiceGrid(
                    options: PlayerMode.allCases.map { ($0.rawValue, $0.title, $0.symbol) },
                    selection: $modeRaw
                )
            }
            SettingsRow(title: "Look", detail: "Liquid Glass, or sharp black and white. T switches.") {
                Segmented(options: [(UITheme.glass.rawValue, "Glass"), (UITheme.mono.rawValue, "Mono")], selection: $themeRaw)
            }
            SettingsRow(title: "Cover", detail: "In the Turntable visualizer. V switches.") {
                Segmented(options: [(HeroStyle.vinyl.rawValue, "Vinyl"), (HeroStyle.cover.rawValue, "Cover")], selection: $heroRaw)
            }
            SettingsRow(title: "Lyrics beside the cover", detail: "In the Turntable visualizer. L switches.") {
                Switch(isOn: $showsNowPlayingLyrics)
            }
        }
    }

    private var lyrics: some View {
        SettingsCard(title: "Lyrics", symbol: "quote.bubble") {
            SettingsRow(title: "Style", detail: "How lines move and highlight in Now Playing.") {
                ChoiceGrid(
                    options: LyricStyle.allCases.map { ($0.rawValue, $0.title, nil) },
                    selection: $lyricStyleRaw
                )
            }
            SettingsRow(title: "Font") {
                ChoiceGrid(
                    options: LyricFont.allCases.map { ($0.rawValue, $0.title, nil) },
                    selection: $lyricFontRaw,
                    font: { LyricFont(rawValue: $0)?.font(13, .semibold, theme: .glass) }
                )
            }
            SettingsRow(title: "Size", detail: "\(Int((lyricScale * 100).rounded()))%") {
                HStack(spacing: 12) {
                    Text("A").font(.system(size: 11, weight: .bold))
                    Slider(value: Binding(get: { lyricScale }, set: { lyricScale = LyricSettings.clampedScale($0) }), in: LyricSettings.scaleRange)
                        .frame(width: 220)
                    Text("A").font(.system(size: 18, weight: .bold))
                }
            }
            SettingsRow(title: "Colors match the song", detail: "Lyrics take their colors from the cover.") {
                Switch(isOn: $colorsMatchSong)
            }
            if !colorsMatchSong {
                ForEach(LyricColorSlot.allCases) { slot in
                    SettingsRow(title: slot.title) { Swatches(slot: slot) }
                }
            }
            SettingsRow(title: "Lyrics in the side panel", detail: "The live lyrics card on the right while a song plays.") {
                Switch(isOn: $showsLyricsCard)
            }
        }
    }

    private var window: some View {
        SettingsCard(title: "Window", symbol: "macwindow") {
            SettingsRow(title: "Song panel", detail: "Lyrics, details and Up Next on the right while a song plays.") {
                Switch(isOn: $showsSongPanel)
            }
            SettingsRow(title: "Keep the screen awake", detail: "While music is playing.") {
                Switch(isOn: $keepsScreenAwake)
            }
            if displays.names.count > 1 {
                SettingsRow(title: "Display", detail: "Where Peace and the mini player live.") {
                    ChoiceGrid(
                        options: displays.names.map { ($0, $0, "display") },
                        selection: Binding(get: { displays.selected }, set: displays.select)
                    )
                }
            }
        }
    }

    private var miniPlayerSection: some View {
        SettingsCard(title: "Mini Player", symbol: "pip") {
            SettingsRow(title: "Style") {
                Segmented(options: MiniStyle.allCases.map { ($0.rawValue, $0.title) }, selection: $miniStyleRaw)
            }
            SettingsRow(title: "Show lyrics") { Switch(isOn: $miniShowsLyrics) }
            SettingsRow(title: "Stay expanded", detail: "Instead of shrinking when the pointer leaves.") {
                Switch(isOn: Binding(get: { miniPlayer.isPinned }, set: { if $0 != miniPlayer.isPinned { miniPlayer.togglePinned() } }))
            }
            SettingsRow(title: "Show on every Space") {
                Switch(isOn: Binding(get: { miniPlayer.isOnAllSpaces }, set: { if $0 != miniPlayer.isOnAllSpaces { miniPlayer.toggleAllSpaces() } }))
            }
            SettingsRow(title: "Open the mini player", detail: "P, or ⇧⌘M.") {
                PillButton(title: "Open", action: miniPlayer.open)
            }
        }
    }

    private var performance: some View {
        SettingsCard(title: "Performance", symbol: "gauge.with.dots.needle.67percent") {
            SettingsRow(title: "Frame rate", detail: "How smoothly the visualizers move. Lower uses less battery.") {
                Segmented(options: FrameRate.choices.map { ("\($0)", "\($0) fps") }, selection: Binding(
                    get: { "\(frameRate)" },
                    set: { frameRate = Int($0) ?? FrameRate.standard }
                ))
            }
            SettingsRow(title: "Halve on battery", detail: "Also in Low Power Mode.") {
                Switch(isOn: $savesBattery)
            }
        }
    }

    private var account: some View {
        SettingsCard(title: "Apple Music", symbol: "person.crop.circle") {
            SettingsRow(title: store.status == .ok ? "Signed in" : "Not signed in", detail: "Peace plays through your Apple Music subscription.") {
                if store.status == .ok {
                    PillButton(title: "Sign Out", action: store.signOut)
                } else {
                    PillButton(title: "Sign In", action: store.signIn)
                }
            }
        }
    }
}

// MARK: Building blocks

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .heavy))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .songGlass(in: .rect(cornerRadius: 22, style: .continuous))
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                labels
                Spacer(minLength: 12)
                control
            }
            VStack(alignment: .leading, spacing: 12) {
                labels
                control
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 20) }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
    }
}

// An on/off switch in the song's color.
private struct Switch: View {
    @Binding var isOn: Bool

    @Environment(\.songTheme) private var theme

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? theme.accent : Color.white.opacity(0.14))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .padding(3)
            }
            .frame(width: 46, height: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.pointer)
    }
}

private struct Segmented: View {
    let options: [(String, String)]
    @Binding var selection: String

    @Environment(\.songTheme) private var theme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = value } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selection == value ? theme.onAccent : .white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if selection == value {
                                Capsule().fill(theme.accent).matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.pointer)
            }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: .capsule)
    }
}

// Chips that wrap onto more lines when there are many choices.
private struct ChoiceGrid: View {
    let options: [(String, String, String?)]
    @Binding var selection: String
    var font: (String) -> Font? = { _ in nil }

    @Environment(\.songTheme) private var theme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.0) { value, title, symbol in
                let isSelected = selection == value
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = value } } label: {
                    HStack(spacing: 7) {
                        if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                        Text(title).font(font(value) ?? .system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? theme.onAccent : .white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(isSelected ? theme.accent : Color.white.opacity(0.07), in: .rect(cornerRadius: 11, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.pointer)
            }
        }
        .frame(width: 400)
    }
}

// A row of colors for one part of the lyrics.
private struct Swatches: View {
    let slot: LyricColorSlot

    @AppStorage private var hex: String

    init(slot: LyricColorSlot) {
        self.slot = slot
        _hex = AppStorage(wrappedValue: "#FFFFFF", slot.key)
    }

    private static let colors = [
        "#FFFFFF", "#FFE7A3", "#FFC15E", "#FF8A65", "#FF5E7E", "#F48FE0",
        "#B39DFF", "#7FA8FF", "#5ED4F5", "#5EE6B0", "#B8F36B", "#9E9E9E",
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Self.colors, id: \.self) { value in
                let isSelected = hex.uppercased() == value
                Button { hex = value } label: {
                    Circle()
                        .fill(Color(hex: value) ?? .white)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2 : 0).padding(-4))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .buttonStyle(.pointer)
            }
        }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .accentFill(in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.pointer)
    }
}

extension PlayerMode {
    var title: String {
        switch self {
        case .turntable: "Turntable"
        case .stage: "Stage"
        case .halftone: "Halftone"
        case .orbit: "Orbit"
        case .constellation: "Constellation"
        }
    }

    var symbol: String {
        switch self {
        case .turntable: "record.circle"
        case .stage: "textformat.size.larger"
        case .halftone: "circle.grid.3x3.fill"
        case .orbit: "circle.dotted.circle"
        case .constellation: "sparkles"
        }
    }
}

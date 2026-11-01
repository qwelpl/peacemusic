import AppKit
import SwiftUI

enum PlayerMode: String, CaseIterable {
    case turntable, stage, halftone

    var next: PlayerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct NowPlayingView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer

    @AppStorage("uiTheme") private var themeRaw = UITheme.glass.rawValue
    @AppStorage("playerMode") private var modeRaw = PlayerMode.turntable.rawValue
    @AppStorage("heroStyle") private var heroStyleRaw = HeroStyle.vinyl.rawValue
    @AppStorage("showsLyrics") private var showsLyrics = true
    @State private var showsLibrary = false
    @State private var lastActivity = Date()
    @State private var isIdle = false
    @FocusState private var isFocused: Bool

    private var theme: UITheme { UITheme(rawValue: themeRaw) ?? .glass }
    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .turntable }
    private var heroStyle: HeroStyle { HeroStyle(rawValue: heroStyleRaw) ?? .vinyl }
    private var chromeVisible: Bool { !isIdle || !store.isPlaying || showsLibrary }

    var body: some View {
        if miniPlayer.isOpen {
            Color.black
        } else {
            fullPlayer
        }
    }

    private var fullPlayer: some View {
        ZStack {
            if store.track == nil || mode == .turntable {
                FluidBackground(
                    colors: store.meshColors,
                    trackID: store.track?.id,
                    isPlaying: store.isPlaying
                )
            }

            if store.track == nil {
                EmptyStateView(openLibrary: { showsLibrary = true })
            } else {
                switch mode {
                case .turntable:
                    player.transition(.opacity)
                case .stage:
                    StageView(chromeVisible: chromeVisible).transition(.opacity)
                case .halftone:
                    HalftoneView(chromeVisible: chromeVisible).transition(.opacity)
                }
            }

            libraryOverlay
        }
        .overlay(alignment: .topTrailing) { topBar }
        .overlay(alignment: .top) { syncToast }
        .environment(\.uiTheme, theme)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            store.start()
            isFocused = true
        }
        .onKeyPress(.space) { store.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { store.previous(); return .handled }
        .onKeyPress(.rightArrow) { store.next(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "m")) { _ in switchMode(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "t")) { _ in switchTheme(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "p")) { _ in miniPlayer.open(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "[")) { _ in store.nudgeLyrics(by: -0.1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "]")) { _ in store.nudgeLyrics(by: 0.1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "\\")) { _ in store.resetLyricOffset(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "l")) { _ in
            guard mode == .turntable else { return .ignored }
            showsLyrics.toggle()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "v")) { _ in
            guard mode == .turntable else { return .ignored }
            toggleHero()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "f")) { _ in toggleFullScreen(); return .handled }
        .onContinuousHover { _ in markActivity() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let idle = Date().timeIntervalSince(lastActivity) > 3.5
                if idle != isIdle {
                    withAnimation(.easeInOut(duration: 0.5)) { isIdle = idle }
                }
            }
        }
    }

    private func markActivity() {
        lastActivity = Date()
        if isIdle {
            withAnimation(.easeOut(duration: 0.2)) { isIdle = false }
        }
    }

    private func switchMode() {
        withAnimation(.easeInOut(duration: 0.5)) { modeRaw = mode.next.rawValue }
    }

    private func switchTheme() {
        withAnimation(.easeInOut(duration: 0.25)) { themeRaw = theme.next.rawValue }
    }

    private func toggleHero() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            heroStyleRaw = (heroStyle == .vinyl ? HeroStyle.cover : .vinyl).rawValue
        }
    }

    private func toggleFullScreen() {
        let window = NSApp.keyWindow ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }
        NSApp.activate(ignoringOtherApps: true)
        window?.toggleFullScreen(nil)
    }

    // MARK: Layout

    private var lyricsVisible: Bool {
        guard showsLyrics else { return false }
        if case .none = store.lyrics { return false }
        return true
    }

    private var player: some View {
        GeometryReader { geometry in
            let columnWidth = min(geometry.size.width * (lyricsVisible ? 0.4 : 0.5), 520)
            let chromeHeight: CGFloat = 270
            let heroSize = min(columnWidth, max(geometry.size.height - chromeHeight - 70, 180))

            HStack(spacing: 56) {
                if !lyricsVisible { Spacer(minLength: 0) }
                VStack(spacing: 22) {
                    hero(size: heroSize)
                    details
                }
                .frame(width: columnWidth)
                .offset(y: chromeVisible ? 0 : 85)

                if lyricsVisible {
                    LyricsPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: lyricsVisible)
        }
    }

    @ViewBuilder
    private func hero(size: CGFloat) -> some View {
        Group {
            switch heroStyle {
            case .vinyl:
                VinylHeroProgress(size: size)
            case .cover:
                CoverHero(image: store.artwork, isPlaying: store.isPlaying, size: size)
            }
        }
        .frame(width: size, height: size)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .id(heroStyle)
    }

    private var details: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.track?.title ?? "")
                        .font(theme.font(24, .heavy))
                        .lineLimit(1)
                    Text([store.track?.artist, store.track?.album]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(theme.font(15, .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                Spacer(minLength: 0)
                PlayerButton(
                    symbol: store.favorited ? "heart.fill" : "heart",
                    title: store.favorited ? "LIKED" : "LIKE",
                    diameter: 38,
                    iconSize: 15,
                    isOn: store.favorited,
                    action: store.toggleFavorite
                )
                .help("Favorite")
                .opacity(chromeVisible ? 1 : 0)
            }
            VStack(spacing: 12) {
                ProgressRow()
                TransportRow()
                VolumeRow()
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
        }
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                PlayerButton(symbol: "music.note.list", title: "LIBRARY", isOn: showsLibrary) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { showsLibrary.toggle() }
                }
                .help("Library")
                PlayerButton(symbol: "sparkles", title: "MODE", action: switchMode)
                    .help("Switch mode (M)")
                PlayerButton(symbol: "circle.lefthalf.filled", title: "THEME", action: switchTheme)
                    .help("Switch between Liquid Glass and Mono (T)")
                if mode == .turntable {
                    PlayerButton(
                        symbol: heroStyle == .vinyl ? "photo" : "record.circle",
                        title: heroStyle == .vinyl ? "COVER" : "VINYL",
                        action: toggleHero
                    )
                        .help("Switch between vinyl and cover (V)")
                    PlayerButton(symbol: "quote.bubble", title: "LYRICS", isOn: showsLyrics) { showsLyrics.toggle() }
                        .help("Lyrics (L)")
                }
                PlayerButton(symbol: "pip.enter", title: "MINI", action: miniPlayer.open)
                    .help("Mini player (P)")
                PlayerButton(symbol: "arrow.up.left.and.arrow.down.right", title: "FULL", action: toggleFullScreen)
                    .help("Full screen (F)")
            }
        }
        .padding(16)
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    @ViewBuilder
    private var syncToast: some View {
        if let message = store.syncMessage {
            Text(message)
                .font(theme.font(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .themedPanel(theme, cornerRadius: 20)
                .padding(.top, 20)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var libraryOverlay: some View {
        if showsLibrary {
            HStack {
                LibraryPanel {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { showsLibrary = false }
                }
                Spacer()
            }
            .padding(.top, 24)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

private struct VinylHeroProgress: View {
    let size: CGFloat

    @Environment(PlayerStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = store.track?.duration ?? 0
            VinylHero(
                image: store.artwork,
                isPlaying: store.isPlaying,
                progress: duration > 0 ? store.position(at: context.date) / duration : 0,
                size: size
            )
        }
    }
}

private struct EmptyStateView: View {
    @Environment(\.uiTheme) private var theme
    let openLibrary: () -> Void

    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .light))
            Text(title)
                .font(theme.font(32, .heavy))
            Text(message)
                .font(theme.font(15, .medium))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(action: action) {
                Text(buttonTitle)
                    .font(theme.font(14, .bold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .themedPanel(theme, cornerRadius: 20)
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
    }

    private var icon: String {
        store.status == .notAuthorized ? "lock.fill" : "music.note"
    }

    private var title: String {
        switch store.status {
        case .notAuthorized: "Peace needs permission"
        case .musicNotRunning: "Music isn't open"
        case .ok: "Nothing playing"
        }
    }

    private var message: String {
        switch store.status {
        case .notAuthorized: "Allow Peace to control Music in System Settings, under Privacy & Security > Automation."
        case .musicNotRunning: "Peace plays through the Music app. Open it and your song shows up here."
        case .ok: "Pick something from your library to get started."
        }
    }

    private var buttonTitle: String {
        switch store.status {
        case .notAuthorized: "Open System Settings"
        case .musicNotRunning: "Open Music"
        case .ok: "Browse Library"
        }
    }

    private func action() {
        switch store.status {
        case .notAuthorized: store.openAutomationSettings()
        case .musicNotRunning: store.openMusic()
        case .ok: openLibrary()
        }
    }
}

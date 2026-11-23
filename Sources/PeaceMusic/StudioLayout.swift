import SwiftUI

// The Studio layout: flat dark panels with hairline edges instead of glass over the song's
// colors. Pages and Now Playing are shared with Peace; only the frame around them changes.
enum Studio {
    static let background = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let panel = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let hairline = Color.white.opacity(0.08)
    static let radius: CGFloat = 14
}

extension SongTheme {
    // The song's color, or amber with nothing playing: white on near-black reads as unselected.
    var studioAccent: Color { self == SongTheme() ? PlayButtons.defaultColor : accent }
}

extension View {
    func studioPanel(cornerRadius: CGFloat = Studio.radius) -> some View {
        background(Studio.panel, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Studio.hairline, lineWidth: 1))
    }

    // A pill or circle outlined with a hairline, for Studio's buttons and fields.
    func studioOutline<S: InsettableShape>(in shape: S) -> some View {
        overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct StudioHoverStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(isHovered ? 0.05 : 0), in: .rect(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
    }
}

// MARK: Sidebar

struct StudioSidebar: View {
    let destination: Destination
    let query: String
    let select: (Destination) -> Void

    @Environment(PlayerStore.self) private var store
    @Environment(\.songTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row("Home", "house.fill", .home)
                    row("New", "sparkles", .new)
                    row("Radio", "dot.radiowaves.left.and.right", .radio)
                    divider
                    header("Library")
                    row("Recently Added", "clock.fill", .library(.recent))
                    row("Artists", "music.mic", .library(.artists))
                    row("Albums", "square.stack.fill", .library(.albums))
                    row("Songs", "music.note", .library(.songs))
                    row("Playlists", "music.note.list", .library(.playlists))
                    divider
                    header("Playlists")
                    ForEach(store.libraryPlaylists) { playlistRow($0) }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
            row("Settings", "gearshape.fill", .settings)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Studio.hairline).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .studioPanel()
    }

    private var divider: some View {
        Rectangle().fill(Studio.hairline).frame(height: 1).padding(.vertical, 8).padding(.horizontal, 4)
    }

    // Both lists' ⊕ make a new playlist, the one thing the library can be given from here.
    private func header(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Button(action: store.newPlaylist) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.pointer)
            .help("New Playlist")
        }
        .padding(.leading, 6)
        .padding(.bottom, 2)
    }

    private func row(_ title: String, _ symbol: String, _ target: Destination) -> some View {
        let isSelected = destination == target && query.isEmpty
        return Button { select(target) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .black : .white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(isSelected ? theme.studioAccent : .white.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 13, weight: .bold))
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(.rect)
        }
        .buttonStyle(StudioHoverStyle())
    }

    private func playlistRow(_ playlist: MediaItem) -> some View {
        let isSelected = destination == .playlist(playlist) && query.isEmpty
        return Button { select(.playlist(playlist)) } label: {
            HStack(spacing: 12) {
                Artwork(item: playlist, size: 30, cornerRadius: 6)
                Text(playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.studioAccent : .white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(.white.opacity(isSelected ? 0.07 : 0), in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(StudioHoverStyle())
        .itemMenu(playlist)
    }
}

// The playing song under the sidebar. Clicking it opens Now Playing.
struct StudioNowPlayingCard: View {
    let openNowPlaying: () -> Void

    @Environment(PlayerStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08))
                if let artwork = store.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.track?.title ?? "Not Playing").font(.system(size: 13, weight: .bold))
                Text(store.track?.artist ?? "Pick something to play")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if store.track != nil {
                Button(action: store.toggleFavorite) {
                    Image(systemName: store.favorited ? "heart.fill" : "heart")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pointer)
                .help("Love")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .studioPanel()
        .contentShape(.rect)
        .clickable()
        .onTapGesture(perform: openNowPlaying)
        .help("Open Now Playing")
    }
}

// MARK: Top bar

struct StudioTopBar: View {
    @Binding var query: String
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 10) {
            circle("chevron.left", enabled: canGoBack, action: back)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            circle("chevron.right", enabled: canGoForward, action: forward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                TextField("Find something to play", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.pointer)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .studioPanel(cornerRadius: 22)
        }
        .background {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private func circle(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.3))
                .frame(width: 44, height: 44)
                .studioPanel(cornerRadius: 22)
                .contentShape(.circle)
        }
        .buttonStyle(.pointer)
        .disabled(!enabled)
    }
}

// MARK: Player bar

// Transport, the song's progress and the extra buttons, each in its own flat box.
struct StudioPlayerBar: View {
    @Binding var showsSongPanel: Bool
    @AppStorage("showsLyricsCard") private var showsLyricsCard = true

    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @Environment(\.songTheme) private var theme
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                button("backward.fill", size: 15, action: store.previous).help("Previous")
                button(store.isPlaying ? "pause.fill" : "play.fill", size: 19, action: store.togglePlayPause)
                button("forward.fill", size: 15, action: store.next).help("Next")
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            .studioPanel()
            progress
                .padding(.horizontal, 18)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 64)
                .studioPanel()
            // The volume steps aside first when the window gets narrow.
            ViewThatFits(in: .horizontal) {
                extras(volume: true)
                extras(volume: false)
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            .studioPanel()
            .layoutPriority(1)
        }
        // Clicks on the boxes' empty space stop here instead of reaching the page.
        .contentShape(.rect)
        .onTapGesture {}
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = store.track?.duration ?? 0
            let position = dragValue.map { $0 * duration } ?? store.position(at: context.date)
            HStack(spacing: 14) {
                Text(SongRow.time(position)).frame(width: 36, alignment: .trailing)
                Scrubber(value: duration > 0 ? position / duration : 0) { dragValue = $0 } onCommit: { value in
                    store.seek(to: value * duration)
                    dragValue = nil
                }
                .frame(height: 12)
                Text(SongRow.time(duration)).frame(width: 36, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .environment(\.songTheme, accentTheme)
    }

    // The scrubber fills with amber rather than white when nothing has set a color.
    private var accentTheme: SongTheme {
        var accented = theme
        accented.accent = theme.studioAccent
        return accented
    }

    private func extras(volume: Bool) -> some View {
        HStack(spacing: 2) {
            if let item = store.currentItem {
                MoreButton(item: item, size: 38)
                    .help("Add to Library or a Playlist")
            }
            // Lyrics on or off in the song panel.
            button(showsLyricsCard ? "quote.bubble.fill" : "quote.bubble", size: 14, dimmed: !(showsSongPanel && showsLyricsCard)) {
                if !showsSongPanel {
                    showsSongPanel = true
                    showsLyricsCard = true
                } else {
                    showsLyricsCard.toggle()
                }
            }
            .help(showsLyricsCard ? "Hide Lyrics" : "Show Lyrics")
            button("sidebar.right", size: 14, dimmed: !showsSongPanel) { showsSongPanel.toggle() }
                .help("Song details, lyrics and Up Next")
            button("pip.enter", size: 14, action: miniPlayer.open)
                .help("Mini Player")
            if volume {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
                Slider(value: Binding(get: { store.volume }, set: store.setVolume), in: 0...1)
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 80)
                    .padding(.horizontal, 6)
            }
            OutputPicker()
        }
        .fixedSize()
    }

    private func button(_ symbol: String, size: CGFloat, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(dimmed ? 0.45 : 0.95))
                .frame(width: 38, height: 38)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pointer)
    }
}

// MARK: Song table

struct StudioSongHeader: View {
    let showsAlbum: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("Title").padding(.leading, 54).frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text("Album").frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Time").frame(width: 44 + 34 + 14, alignment: .trailing).padding(.trailing, 32 + 14)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Studio.hairline).frame(height: 1) }
    }
}

// One song in Studio's table. Plays and opens its menu the same way SongRow does.
struct StudioSongRow: View {
    let song: MediaItem
    let index: Int
    var showsArtwork = true
    var showsAlbum = true
    let play: () -> Void

    @Environment(PlayerStore.self) private var store
    @Environment(\.songTheme) private var theme
    @State private var isHovered = false
    // Apple Music doesn't say which songs are loved, so this only knows what was loved here.
    @State private var loved = false

    private var isCurrent: Bool { store.isCurrent(song) }
    private var isLoved: Bool { isCurrent ? store.favorited : loved }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(song.title).lineLimit(1)
                        if song.isExplicit { ExplicitBadge() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? theme.studioAccent : .white)
                    Text(song.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text(song.album)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            MoreButton(item: song)
                .opacity(isHovered ? 1 : 0)
            Text(SongRow.time(song.duration))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .trailing)
            Button(action: toggleLove) {
                Image(systemName: isLoved ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isLoved ? theme.studioAccent : .white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pointer)
            .help("Love")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(.white.opacity(isHovered ? 0.05 : 0))
        .overlay(alignment: .bottom) { Rectangle().fill(Studio.hairline).frame(height: 1) }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .clickable()
        .onTapGesture(perform: play)
        .itemMenu(song)
    }

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if showsArtwork {
                Artwork(item: song, size: 40, cornerRadius: 5)
                    .opacity(isHovered || isCurrent ? 0.4 : 1)
            }
            if isHovered {
                Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
            } else if isCurrent {
                // Still: a looping symbol redraws the whole window every frame.
                Image(systemName: store.isPlaying ? "waveform" : "speaker.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(showsArtwork ? .white : theme.studioAccent)
            } else if !showsArtwork {
                Text("\(song.trackNumber ?? index + 1)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 40, height: 40)
    }

    private func toggleLove() {
        if isCurrent {
            store.toggleFavorite()
        } else {
            loved.toggle()
            let value = loved ? 1 : nil as Int?
            Task { await store.catalog.rate(song, value) }
        }
    }
}

// MARK: Collection page

// An album or playlist under a banner of its songs' covers, with the songs as a table.
struct StudioCollectionPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store
    @State private var detail: MediaItem?
    @State private var tracks: [MediaItem]?
    @State private var added = false
    @State private var liked = false
    @State private var filter = ""

    var body: some View {
        let shown = detail ?? item
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                banner(shown)
                // The filter drops under the buttons when there isn't room beside them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        buttons(shown)
                        Spacer(minLength: 16)
                        filterField.frame(minWidth: 160, maxWidth: 320)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        buttons(shown)
                        filterField
                    }
                }
                if let tracks {
                    SongList(songs: tracks, collection: shown, showsArtwork: item.kind != .album, showsAlbum: item.kind != .album, filter: filter)
                        .environment(\.editablePlaylist, shown.canEdit ? shown : nil)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .id("collection-\(item.id)")
        .task(id: item.id) {
            // Home and search link to the public copy of the account's own playlists. Open the
            // library one instead, whose songs and edits belong to the account.
            let source = item.isLibrary ? item : store.libraryPlaylists.first { $0.globalID == item.id } ?? item
            let (loaded, songs) = await store.catalog.collection(source) { partial, partialTracks in
                withAnimation(.easeOut(duration: 0.3)) {
                    detail = partial
                    tracks = partialTracks
                }
            }
            withAnimation(.easeOut(duration: 0.3)) {
                detail = loaded
                tracks = songs
            }
        }
    }

    private func banner(_ shown: MediaItem) -> some View {
        ZStack(alignment: .leading) {
            CoverCollage(items: collageItems(shown))
                .overlay(Color.black.opacity(0.45))
            // The cover steps down in size when the page is too narrow for it beside the title.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 40) {
                    StackedCover(item: shown, size: 230)
                    details(shown)
                }
                HStack(spacing: 28) {
                    StackedCover(item: shown, size: 150)
                    details(shown)
                }
                details(shown)
            }
            .padding(.horizontal, 28)
        }
        .frame(height: 300)
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Studio.hairline, lineWidth: 1))
    }

    // One tile per distinct cover, so a playlist of one album doesn't look like wallpaper.
    private func collageItems(_ shown: MediaItem) -> [MediaItem] {
        var seen = Set<String>()
        let distinct = (tracks ?? []).filter { track in
            guard let artwork = track.artwork else { return false }
            return seen.insert(artwork).inserted
        }
        return distinct.isEmpty ? [shown] : Array(distinct.prefix(40))
    }

    private func details(_ shown: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.kind == .album ? "Album" : "Playlist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(shown.title)
                .font(.system(size: 36, weight: .heavy))
                .tracking(-0.8)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .yieldsWidth()
            if let summary {
                Text(summary)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .yieldsWidth()
            }
            if let byline = byline(shown) {
                Text(byline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .yieldsWidth()
            }
        }
        .foregroundStyle(.white)
    }

    // "12 Songs · 1 hour, 4 minutes"
    private var summary: String? {
        guard let tracks, !tracks.isEmpty else { return nil }
        var parts = ["\(tracks.count) Song\(tracks.count == 1 ? "" : "s")"]
        let minutes = Int(tracks.reduce(0) { $0 + $1.duration } / 60)
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = "\(hours) hour\(hours == 1 ? "" : "s")"
        let minuteText = "\(rest) minute\(rest == 1 ? "" : "s")"
        if hours > 0 {
            parts.append(rest > 0 ? "\(hourText), \(minuteText)" : hourText)
        } else if minutes > 0 {
            parts.append(minuteText)
        }
        return parts.joined(separator: " · ")
    }

    // Who made it, or when it came out.
    private func byline(_ shown: MediaItem) -> String? {
        var parts: [String] = []
        if !shown.subtitle.isEmpty { parts.append(shown.subtitle) }
        if let year = shown.releaseDate?.prefix(4), !year.isEmpty { parts.append(String(year)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func buttons(_ shown: MediaItem) -> some View {
        HStack(spacing: 10) {
            pill("Play", "play.fill") { store.play(item) }
            pill("Shuffle", "shuffle") { store.play(item, shuffle: true) }
            pill("Like", liked ? "heart.fill" : "heart") {
                liked.toggle()
                let value = liked ? 1 : nil as Int?
                Task { await store.catalog.rate(item, value) }
            }
            if !item.isLibrary {
                pill(added ? "Added" : "Add", added ? "checkmark" : "plus") {
                    guard !added else { return }
                    Task { await store.catalog.addToLibrary(item) }
                    withAnimation(.spring) { added = true }
                }
                .help("Add to Library")
            }
            MoreButton(item: item, size: 40)
                .studioOutline(in: Circle())
        }
        .fixedSize()
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .studioOutline(in: Capsule())
                .contentShape(.capsule)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pointer)
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            TextField("Filter Songs...", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)).contentShape(.rect)
                }
                .buttonStyle(.pointer)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .studioOutline(in: Capsule())
    }
}

// The cover with two blank sleeves fanned out behind it.
private struct StackedCover: View {
    let item: MediaItem
    let size: CGFloat

    var body: some View {
        ZStack {
            sleeve(Color(white: 0.72), angle: 9, offset: size * 0.1)
            sleeve(Color(white: 0.88), angle: 4.5, offset: size * 0.05)
            Artwork(item: item, size: size, cornerRadius: 14)
                .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        }
        // The sleeves stick out to the right; keep them inside the cover's own width plus a bit.
        .padding(.trailing, size * 0.12)
    }

    private func sleeve(_ color: Color, angle: Double, offset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            .rotationEffect(.degrees(angle), anchor: .bottomLeading)
            .offset(x: offset)
    }
}

// The covers tiled edge to edge on a tilt, larger than the banner so no corner shows.
private struct CoverCollage: View {
    let items: [MediaItem]

    private static let tile: CGFloat = 132
    private static let gap: CGFloat = 12
    private static let angle = 12.0

    var body: some View {
        GeometryReader { geometry in
            let radians = Self.angle * .pi / 180
            let width = geometry.size.width * cos(radians) + geometry.size.height * sin(radians)
            let height = geometry.size.width * sin(radians) + geometry.size.height * cos(radians)
            let step = Self.tile + Self.gap
            let columns = Int((width / step).rounded(.up)) + 1
            let rows = Int((height / step).rounded(.up)) + 1
            VStack(spacing: Self.gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: Self.gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            // Each row starts further along, so the same covers don't line up in columns.
                            Artwork(item: items[(row * columns + column + row * 3) % items.count], size: Self.tile, cornerRadius: 10)
                        }
                    }
                }
            }
            .fixedSize()
            .rotationEffect(.degrees(-Self.angle))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

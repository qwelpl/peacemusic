import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case recent, playlists, albums, artists, songs

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        }
    }
}

// The whole app. The current song's colors wash through everything, the navigation and
// player float on glass, and Now Playing grows out of the player.
// The whole app. The current song's colors wash through everything; navigation sits on
// the left, the song that's playing fills the right, and Now Playing grows out of the dock.
struct MusicAppView: View {
    @Environment(PlayerStore.self) private var store

    @State private var destination = Destination.home
    @State private var path: [MediaItem] = []
    // Pages left by going back, for Studio's forward button.
    @State private var forwardPath: [MediaItem] = []
    @State private var query = ""
    @State private var showsNowPlaying = false
    // True once Now Playing fully covers the window, so the browser underneath can stop drawing.
    @State private var nowPlayingCovers = false
    @AppStorage("showsSongPanel") private var showsSongPanel = true
    // Whether the window is wide enough for the song panel beside the sidebar and the page.
    @State private var songPanelFits = true
    @AppStorage("layoutStyle") private var layoutRaw = LayoutStyle.peace.rawValue
    private var layout: LayoutStyle { LayoutStyle(rawValue: layoutRaw) ?? .peace }

    @State private var songTheme = SongTheme()
    @State private var menus = MenuPresenter()

    var body: some View {
        ZStack {
            if layout == .studio {
                Studio.background.ignoresSafeArea()
            } else {
                AmbientBackground()
            }
            if store.status == .signedOut {
                SignInView()
            } else {
                browser
            }
        }
        .environment(\.songTheme, songTheme)
        .environment(\.layoutStyle, layout)
        .lyricLook()
        .tint(songTheme.accent)
        // Only the colors fade. Animating the whole window on a song change dragged every
        // other change made at the same moment (play button, titles) through the fade too.
        .onChange(of: store.accentColors) {
            let next = store.track == nil ? SongTheme() : SongTheme(accents: store.accentColors)
            withAnimation(.easeInOut(duration: 0.8)) { songTheme = next }
        }
        .onChange(of: store.track == nil) {
            songTheme = store.track == nil ? SongTheme() : SongTheme(accents: store.accentColors)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.start()
            if CommandLine.arguments.contains("--settings") { destination = .settings }
            switch ResizeBench.page {
            case "albums": destination = .library(.albums)
            case "songs": destination = .library(.songs)
            case "settings": destination = .settings
            default: break
            }
        }
        .task(id: store.status) {
            if store.status == .ok { await store.refreshLibraryPlaylists() }
        }
    }

    // Padding, sidebar, gaps, panel, and the narrowest the page should get beside them.
    private static let songPanelMinimumWidth: CGFloat = 12 + 236 + 12 + 320 + 12 + 12 + 520
    private static let studioSongPanelMinimumWidth: CGFloat = 10 + 260 + 10 + 320 + 10 + 10 + 520

    private var browser: some View {
        ZStack {
            if !nowPlayingCovers, layout == .studio {
                studio
            } else if !nowPlayingCovers {
            HStack(spacing: 12) {
                LeftSidebar(destination: $destination, query: $query, select: select)
                    .frame(width: 236)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                main
                    .frame(minWidth: 0, maxWidth: .infinity)
                    // Anything still too wide is cut off here instead of spilling over the sidebar.
                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
                if showsSongPanel, songPanelFits, store.track != nil {
                    NowPlayingPanel(openNowPlaying: openNowPlaying)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(12)
            }

            MenuLayer(presenter: menus)
                .zIndex(3)

            if showsNowPlaying {
                NowPlayingView(onClose: closeNowPlaying)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        // Sidebar, page and panel never squeeze each other off screen: when the window is too
        // narrow for all three, the panel steps aside until there's room again.
        .onGeometryChange(for: Bool.self) { [layout] in
            $0.size.width >= (layout == .studio ? Self.studioSongPanelMinimumWidth : Self.songPanelMinimumWidth)
        } action: { songPanelFits = $0 }
        .environment(\.openItem, open)
        .environment(\.menuPresenter, menus)
        .onChange(of: query) { if !query.isEmpty { path = [] } }
        .onReceive(NotificationCenter.default.publisher(for: .peaceOpenSettings)) { _ in
            if showsNowPlaying { closeNowPlaying() }
            select(.settings)
        }
        .task(id: showsNowPlaying) {
            guard showsNowPlaying else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if showsNowPlaying { nowPlayingCovers = true }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: showsSongPanel)
        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: store.track == nil)
    }

    // Studio: flat panels. Sidebar and the playing song on the left, a search bar over the
    // page, and the player along the bottom.
    private var studio: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                StudioSidebar(destination: destination, query: query, select: select)
                StudioNowPlayingCard(openNowPlaying: openNowPlaying)
            }
            .frame(width: 260)
            .layoutPriority(2)
            VStack(spacing: 10) {
                StudioTopBar(
                    query: $query,
                    canGoBack: !path.isEmpty,
                    canGoForward: !forwardPath.isEmpty,
                    back: goBack,
                    forward: goForward
                )
                pages
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: Studio.radius, style: .continuous))
                StudioPlayerBar(showsSongPanel: $showsSongPanel)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            if showsSongPanel, songPanelFits, store.track != nil {
                NowPlayingPanel(openNowPlaying: openNowPlaying)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        // The title bar's safe area already clears the window's buttons.
        .padding(.top, 8)
    }

    private var main: some View {
        ZStack(alignment: .topLeading) {
            pages
            if !path.isEmpty {
                GlassIconButton(symbol: "chevron.left", size: 38, action: goBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .padding(.leading, 18)
                    .padding(.top, 14)
                    .transition(.scale.combined(with: .opacity))
            }
            VStack {
                Spacer()
                PlayerDock(showsNowPlaying: $showsNowPlaying, showsSongPanel: $showsSongPanel)
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var pages: some View {
        ZStack {
            if let item = path.last {
                DetailPage(item: item)
                    .id(item.id + "\(path.count)")
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else if !query.isEmpty {
                SearchPage(query: query).transition(.opacity)
            } else {
                switch destination {
                case .home: HomePage().transition(.opacity)
                case .new: ShelfPage(title: "New", subtitle: "Charts and releases", id: "new") { await store.catalog.browse(update: $0) }.transition(.opacity)
                case .radio: ShelfPage(title: "Radio", subtitle: "Stations and live shows", id: "radio") { await store.catalog.radio(update: $0) }.transition(.opacity)
                case .replay: ShelfPage(title: "Replay", subtitle: "Your most played this year", id: "replay") { await store.catalog.replay(update: $0) }.transition(.opacity)
                case .library(let section): LibraryPage(section: section).transition(.opacity)
                case .playlist(let item): DetailPage(item: item).id(item.id).transition(.opacity)
                case .settings: SettingsPage().transition(.opacity)
                }
            }
        }
    }

    private func open(_ item: MediaItem) {
        if item.kind == .song {
            store.play([item], at: 0, in: nil)
        } else {
            forwardPath = []
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { path.append(item) }
        }
    }

    private func openNowPlaying() {
        guard store.track != nil else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showsNowPlaying = true }
    }

    private func closeNowPlaying() {
        nowPlayingCovers = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showsNowPlaying = false }
    }

    private func goBack() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            if let left = path.popLast() { forwardPath.append(left) }
        }
    }

    private func goForward() {
        guard let next = forwardPath.popLast() else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { path.append(next) }
    }

    private func select(_ next: Destination) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            destination = next
            path = []
            forwardPath = []
            query = ""
        }
    }
}


// MARK: Backdrop

private struct AmbientBackground: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        ZStack {
            // Kept still: a moving backdrop makes every glass panel above it redraw each frame.
            FluidBackground(colors: store.meshColors, trackID: store.track?.id, isPlaying: false, fade: 0.5)
                .opacity(0.55)
            // Darker toward the bottom so lists stay easy to read.
            LinearGradient(
                colors: [.black.opacity(0.25), .black.opacity(0.6), .black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 300, endRadius: 1100)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Pages

private struct Page<Content: View>: View {
    let id: String
    @ViewBuilder let content: Content

    @Environment(\.layoutStyle) private var layoutStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) { content }
                // Studio has no floating back button or dock over the page to make room for.
                .padding(.top, layoutStyle == .studio ? 24 : Layout.topInset)
                .padding(.bottom, layoutStyle == .studio ? 40 : Layout.bottomInset)
        }
        .scrollIndicators(.never)
        .id(id)
    }
}

private struct HomePage: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Page(id: "home") {
            PageTitle(title: greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month().day()))
            Loading(load: { await store.catalog.home(update: $0) }, isEmpty: { $0.isEmpty }) { shelves in
                VStack(alignment: .leading, spacing: 44) {
                    let recent = shelves.first { $0.title == "Recently Played" }?.items ?? []
                    if let feature = recent.first ?? shelves.first?.items.first {
                        HeroCard(item: feature, eyebrow: "Last played")
                            .padding(.horizontal, Layout.gutter)
                    }
                    ForEach(shelves) { ShelfView(shelf: $0) }
                }
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct ShelfPage: View {
    let title: String
    let subtitle: String
    let id: String
    let load: (_ update: @escaping ([Shelf]) -> Void) async -> [Shelf]

    var body: some View {
        Page(id: id) {
            PageTitle(title: title, subtitle: subtitle)
            Loading(load: load, isEmpty: { $0.isEmpty }) { shelves in
                VStack(alignment: .leading, spacing: 44) {
                    if let feature = shelves.lazy.flatMap(\.items).first(where: { $0.kind != .song }) {
                        HeroCard(item: feature, eyebrow: shelves.first { $0.items.contains(feature) }?.title ?? title)
                            .padding(.horizontal, Layout.gutter)
                    }
                    ForEach(shelves) { ShelfView(shelf: $0) }
                }
            }
        }
    }
}

private struct LibraryPage: View {
    let section: LibrarySection

    @Environment(PlayerStore.self) private var store

    var body: some View {
        Page(id: "library-\(section.rawValue)") {
            PageTitle(title: section.title, subtitle: "Library")
            switch section {
            case .recent: grid { await store.catalog.recentlyAdded(update: $0) }
            case .playlists: grid { await store.catalog.libraryPlaylists(update: $0) }
            case .albums: grid { await store.catalog.libraryAlbums(update: $0) }
            case .artists: grid { await store.catalog.libraryArtists(update: $0) }
            case .songs: LibrarySongs()
            }
        }
    }

    private func grid(_ load: @escaping (_ update: @escaping ([MediaItem]) -> Void) async -> [MediaItem]) -> some View {
        Loading(load: load, isEmpty: { $0.isEmpty }) { items in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 24, alignment: .top)], spacing: 28) {
                ForEach(items.filter { !store.removedItems.contains($0.id) }) { ItemTile(item: $0, size: 160) }
            }
            .padding(.horizontal, Layout.gutter)
        }
    }
}

private struct LibrarySongs: View {
    @Environment(PlayerStore.self) private var store
    @State private var filter = ""

    var body: some View {
        Loading(load: { await store.catalog.librarySongs(update: $0) }, isEmpty: { $0.isEmpty }) { songs in
            let shown = filter.isEmpty ? songs : songs.filter {
                $0.title.localizedCaseInsensitiveContains(filter) || $0.subtitle.localizedCaseInsensitiveContains(filter)
                    || $0.album.localizedCaseInsensitiveContains(filter)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PlayButtons(play: { store.play(shown, at: 0, in: nil) }, shuffle: {
                        guard !shown.isEmpty else { return }
                        store.play(shown.shuffled(), at: 0, in: nil)
                    })
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.white.opacity(0.6))
                        TextField("Filter \(songs.count) songs", text: $filter).textFieldStyle(.plain)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(width: 220, height: 34)
                    .songGlass(in: .capsule)
                }
                .padding(.horizontal, Layout.gutter)
                SongList(songs: shown).padding(.horizontal, Layout.gutter - 12)
            }
        }
    }
}

private struct SearchPage: View {
    let query: String

    @Environment(\.songTheme) private var theme

    @Environment(PlayerStore.self) private var store
    @State private var inLibrary = false
    @State private var shelves: [Shelf]?
    @State private var searchDone = false
    @Namespace private var selection

    var body: some View {
        Page(id: "search") {
            HStack(alignment: .bottom) {
                PageTitle(title: "“\(query)”", subtitle: "Search")
                Spacer()
                HStack(spacing: 4) {
                    scope("Apple Music", false)
                    scope("Library", true)
                }
                .padding(4)
                .songGlass(in: .capsule)
                .padding(.trailing, Layout.gutter)
            }
            if let shelves {
                if shelves.isEmpty && searchDone {
                    Text("Nothing matched. Try another spelling.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(shelves) { shelf in
                    if shelf.isSongs {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: shelf.title)
                            SongList(songs: Array(shelf.items.prefix(8))).padding(.horizontal, Layout.gutter - 12)
                        }
                    } else {
                        ShelfView(shelf: shelf)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: "\(query)|\(inLibrary)") {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            searchDone = false
            let found = await store.catalog.search(query, inLibrary: inLibrary) { partial in
                guard !Task.isCancelled, !partial.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.25)) { shelves = partial }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { shelves = found }
            searchDone = true
        }
    }

    private func scope(_ title: String, _ value: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { inLibrary = value; shelves = nil }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(inLibrary == value ? theme.onAccent : .white.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    if inLibrary == value { Capsule().fill(theme.accent).matchedGeometryEffect(id: "scope", in: selection) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.pointer)
    }
}

// Album, playlist, artist or station.
private struct DetailPage: View {
    let item: MediaItem

    @Environment(\.layoutStyle) private var layoutStyle

    var body: some View {
        switch item.kind {
        case .artist: ArtistPage(item: item)
        case .station: StationPage(item: item)
        default:
            if layoutStyle == .studio { StudioCollectionPage(item: item) } else { CollectionPage(item: item) }
        }
    }
}

private struct CollectionPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store
    @State private var detail: MediaItem?
    @State private var tracks: [MediaItem]?
    @State private var added = false

    var body: some View {
        let shown = detail ?? item
        Page(id: "collection-\(item.id)") {
            // The cover sits above the title when the page is too narrow for it alongside.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 36) {
                    Artwork(item: shown, size: 270, cornerRadius: 20, glow: 1)
                    details(shown)
                }
                VStack(alignment: .leading, spacing: 24) {
                    Artwork(item: shown, size: 200, cornerRadius: 18, glow: 1)
                    details(shown)
                }
            }
            .padding(.horizontal, Layout.gutter)

            if let tracks {
                SongList(songs: tracks, collection: shown, showsArtwork: item.kind != .album, showsAlbum: item.kind != .album)
                    .padding(.horizontal, Layout.gutter - 12)
                    .environment(\.editablePlaylist, shown.canEdit ? shown : nil)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .background(alignment: .top) { Backdrop(item: shown) }
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

    private func details(_ shown: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.kind == .album ? "Album" : "Playlist")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text(shown.title)
                .font(.system(size: 44, weight: .heavy))
                .tracking(-1)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .yieldsWidth()
            Text(shown.subtitle)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .yieldsWidth()
            Text(meta(shown))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .yieldsWidth()
            if let note = shown.note {
                Text(note.strippingTags)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3)
                    .frame(maxWidth: 560, alignment: .leading)
                    .yieldsWidth()
            }
            HStack(spacing: 10) {
                PlayButtons(item: shown, play: { store.play(item) }, shuffle: { store.play(item, shuffle: true) })
                if !item.isLibrary {
                    GlassIconButton(symbol: added ? "checkmark" : "plus", isOn: added) {
                        Task { await store.catalog.addToLibrary(item) }
                        withAnimation(.spring) { added = true }
                    }
                    .help("Add to Library")
                }
                MoreButton(item: item, size: 40, glass: true)
            }
            .padding(.top, 12)
        }
    }

    private func meta(_ shown: MediaItem) -> String {
        var parts: [String] = []
        if let year = shown.releaseDate?.prefix(4), !year.isEmpty { parts.append(String(year)) }
        if let tracks, !tracks.isEmpty {
            parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
            let minutes = Int(tracks.reduce(0) { $0 + $1.duration } / 60)
            if minutes > 0 { parts.append(minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min") }
        }
        return parts.joined(separator: " · ")
    }
}

private struct ArtistPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store
    @State private var page: MusicCatalog.ArtistPage?

    var body: some View {
        let artist = page?.artist ?? item
        Page(id: "artist-\(item.id)") {
            // The portrait sits above the name when the page is too narrow for it alongside.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 32) {
                    Artwork(item: artist, size: 210, isCircle: true, glow: 1)
                    details(artist)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Artwork(item: artist, size: 160, isCircle: true, glow: 1)
                    details(artist)
                }
            }
            .padding(.horizontal, Layout.gutter)
            if let page {
                ForEach(page.shelves) { ShelfView(shelf: $0) }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .background(alignment: .top) { Backdrop(item: artist) }
        .task(id: item.id) {
            let loaded = await store.catalog.artist(item) { partial in
                withAnimation(.easeOut(duration: 0.3)) { page = partial }
            }
            withAnimation(.easeOut(duration: 0.3)) { page = loaded }
        }
    }

    private func details(_ artist: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Artist")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text(artist.title)
                .font(.system(size: 56, weight: .heavy))
                .tracking(-1.5)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .yieldsWidth()
            if let songs = page?.shelves.first(where: { $0.isSongs })?.items {
                PlayButtons(item: artist, play: { store.play(songs, at: 0, in: nil) }, shuffle: { store.play(songs.shuffled(), at: 0, in: nil) })
            }
        }
    }
}

private struct StationPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            Artwork(item: item, size: 300, cornerRadius: 24, glow: 1)
            Text(item.title).font(.system(size: 40, weight: .heavy)).tracking(-1)
            if let note = item.note {
                Text(note.strippingTags).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            Button { store.play(item) } label: {
                Label("Listen Now", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 160, height: 44)
                    .accentFill(in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.pointer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) { Backdrop(item: item) }
    }
}

// The cover melted into the top of a page.
private struct Backdrop: View {
    let item: MediaItem

    var body: some View {
        BlurredArtwork(item: item)
            .opacity(0.6)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            .frame(height: 520)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Sign in

private struct SignInView: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 60, weight: .semibold))
                .symbolEffect(.variableColor.iterative)
            Text("Peace").font(.system(size: 54, weight: .heavy)).tracking(-1.5)
            Text("All of Apple Music, beautifully. Sign in once with your Apple Account.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button(action: store.signIn) {
                Text("Sign In")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 160, height: 44)
                    .accentFill(in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.pointer)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Player dock

private struct PlayerDock: View {
    @Binding var showsNowPlaying: Bool
    @Binding var showsSongPanel: Bool
    @AppStorage("showsLyricsCard") private var showsLyricsCard = true

    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @State private var dragValue: Double?
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // The full set of buttons whenever it fits with the song name at its minimum,
            // the shorter sets otherwise. ViewThatFits judges each row by its ideal width,
            // where the song name counts as its minimum, and nothing is remembered between
            // layouts, so a dock rebuilt after Now Playing closes picks the same row.
            ViewThatFits(in: .horizontal) {
                row(trailing: fullTrailing)
                row(trailing: compactTrailing)
                row(trailing: OutputPicker())
                // Last resort: the song shrinks to its cover.
                row(trailing: OutputPicker(), songMinimum: 50)
            }
            .padding(.horizontal, 14)
            .frame(height: 70)
            progress
        }
        // Wide enough that the full set of buttons fits beside the song once there's room.
        .frame(maxWidth: 1220)
        .songGlass(in: .rect(cornerRadius: 26, style: .continuous))
        // Clicks on the dock's empty space stop here instead of playing the song beneath.
        .contentShape(.rect(cornerRadius: 26, style: .continuous))
        .onTapGesture {}
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(.horizontal, 24)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.2)) { isHovered = hovering } }
    }

    private func openNowPlaying() {
        guard store.track != nil else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showsNowPlaying = true }
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08))
                if let artwork = store.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .shadow(color: (store.accentColors.first ?? .black).opacity(0.6), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.track?.title ?? "Not Playing")
                    .font(.system(size: 13, weight: .bold))
                Text(store.track?.artist ?? "Pick something to play")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
        }
        .contentShape(.rect)
        .clickable()
        .onTapGesture(perform: openNowPlaying)
        .help("Open Now Playing")
    }

    private var transport: some View {
        HStack(spacing: 14) {
            dockButton(store.shuffle ? "shuffle" : "shuffle", size: 13, dimmed: !store.shuffle, action: store.toggleShuffle)
            dockButton("backward.fill", size: 16, action: store.previous)
            Button(action: store.togglePlayPause) {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 46, height: 46)
                    .accentFill(in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pointer)
            dockButton("forward.fill", size: 16, action: store.next)
            dockButton(store.repeatMode == .one ? "repeat.1" : "repeat", size: 13, dimmed: store.repeatMode == .off, action: store.cycleRepeat)
        }
    }

    private func row(trailing: some View, songMinimum: CGFloat = 120) -> some View {
        HStack(spacing: 18) {
            nowPlaying
                .frame(minWidth: songMinimum, idealWidth: songMinimum, maxWidth: .infinity, alignment: .leading)
                .clipped()
            transport
            trailing
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // Drops the less used buttons when the dock gets narrow, so the song name keeps its room.
    private var compactTrailing: some View {
        HStack(spacing: 6) {
            dockButton(store.favorited ? "heart.fill" : "heart", size: 14, action: store.toggleFavorite)
                .help("Love")
            if let item = store.currentItem {
                MoreButton(item: item, size: 38)
                    .help("Add to Library or a Playlist")
            }
            dockButton("sidebar.right", size: 14, dimmed: !showsSongPanel) { showsSongPanel.toggle() }
                .help("Song details, lyrics and Up Next")
            OutputPicker()
        }
    }

    private var fullTrailing: some View {
        HStack(spacing: 6) {
            dockButton(store.favorited ? "heart.fill" : "heart", size: 14, action: store.toggleFavorite)
                .help("Love")
            if let item = store.currentItem {
                MoreButton(item: item, size: 38)
                    .help("Add to Library or a Playlist")
            }
            dockButton("waveform", size: 14, action: openNowPlaying)
                .help("Visualizer")
            // Lyrics on or off in the song panel.
            dockButton(showsLyricsCard ? "quote.bubble.fill" : "quote.bubble", size: 14, dimmed: !(showsSongPanel && showsLyricsCard)) {
                if !showsSongPanel {
                    showsSongPanel = true
                    showsLyricsCard = true
                } else {
                    showsLyricsCard.toggle()
                }
            }
            .help(showsLyricsCard ? "Hide Lyrics" : "Show Lyrics")
            dockButton("sidebar.right", size: 14, dimmed: !showsSongPanel) { showsSongPanel.toggle() }
            .help("Song details, lyrics and Up Next")
            dockButton("pip.enter", size: 14, action: miniPlayer.open)
                .help("Mini Player")
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Slider(value: Binding(get: { store.volume }, set: store.setVolume), in: 0...1)
                .controlSize(.small)
                .tint(.white)
                .frame(width: 80)
            OutputPicker()
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = store.track?.duration ?? 0
            let position = dragValue.map { $0 * duration } ?? store.position(at: context.date)
            HStack(spacing: 10) {
                Text(SongRow.time(position)).frame(width: 36, alignment: .trailing)
                Scrubber(value: duration > 0 ? position / duration : 0) { dragValue = $0 } onCommit: { value in
                    store.seek(to: value * duration)
                    dragValue = nil
                }
                .frame(height: 12)
                Text("-" + SongRow.time(max(duration - position, 0))).frame(width: 40, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .environment(\.uiTheme, .mono)
    }

    private func dockButton(_ symbol: String, size: CGFloat, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
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

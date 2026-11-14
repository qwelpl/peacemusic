import AppKit
import SwiftUI

extension EnvironmentValues {
    // Opens an album, playlist, artist or station page.
    @Entry var openItem: (MediaItem) -> Void = { _ in }
    @Entry var songTheme = SongTheme()
}

// The app's colors, taken from the cover of the song that's playing.
struct SongTheme: Equatable {
    var accent: Color = .white
    // Text and icons that sit on the accent.
    var onAccent: Color = .black
    // A faint wash of the song's color through every glass panel.
    var glass: Color = .clear

    init() {}

    init(accents: [Color]) {
        guard let first = accents.first, let color = NSColor(first).usingColorSpace(.sRGB) else { return }
        accent = Color(hue: color.hueComponent, saturation: min(color.saturationComponent, 0.7), brightness: 0.98)
        let resolved = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        let luminance = 0.2126 * resolved.redComponent + 0.7152 * resolved.greenComponent + 0.0722 * resolved.blueComponent
        onAccent = luminance > 0.6 ? .black : .white
        glass = accent.opacity(0.14)
    }
}

private struct SongGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.songTheme) private var theme

    func body(content: Content) -> some View {
        content.glassEffect(interactive ? Glass.regular.tint(theme.glass).interactive() : Glass.regular.tint(theme.glass), in: shape)
    }
}

private struct AccentFill<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.songTheme) private var theme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.onAccent)
            .background(theme.accent, in: shape)
            .shadow(color: theme.accent.opacity(0.45), radius: 12, y: 4)
    }
}

extension View {
    func songGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(SongGlass(shape: shape, interactive: interactive))
    }

    // Filled with the song's color, the way the main buttons are.
    func accentFill<S: Shape>(in shape: S) -> some View {
        modifier(AccentFill(shape: shape))
    }
}

// MARK: Artwork

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSURL, NSImage>()
    private var colors: [URL: Color] = [:]

    func image(for url: URL) -> NSImage? { images.object(forKey: url as NSURL) }
    func color(for url: URL) -> Color? { colors[url] }

    func load(_ url: URL) async -> NSImage? {
        if let cached = image(for: url) { return cached }
        guard let data = try? await URLSession.shared.data(from: url).0, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        colors[url] = Self.glow(of: image)
        return image
    }

    // The cover's most colorful tone, brightened enough to glow on black.
    private static func glow(of image: NSImage) -> Color {
        let tones = Palette.meshColors(from: image).map { NSColor($0).usingColorSpace(.sRGB) ?? .gray }
        let best = tones.max { $0.saturationComponent * $0.brightnessComponent < $1.saturationComponent * $1.brightnessComponent } ?? .gray
        return Color(hue: best.hueComponent, saturation: min(best.saturationComponent * 1.1, 0.9), brightness: max(best.brightnessComponent, 0.75))
    }
}

struct Artwork: View {
    let item: MediaItem?
    var template: String? = nil
    var size: CGFloat
    var cornerRadius: CGFloat = 12
    var isCircle = false
    // Casts a soft halo in the cover's own color.
    var glow: Double = 0

    @State private var image: NSImage?
    @State private var color: Color?

    private var url: URL? {
        let pixels = Int(size * 2)
        if let item { return item.artworkURL(pixels) }
        guard let template else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: "\(pixels)").replacingOccurrences(of: "{h}", with: "\(pixels)"))
    }

    private var shape: AnyShape {
        isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: placeholder)
                    .font(.system(size: size * 0.28, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(
            color: glow > 0 ? (color ?? .black).opacity(glow * 0.55) : .black.opacity(0.3),
            radius: glow > 0 ? 10 + glow * 22 : 5,
            y: glow > 0 ? 6 + glow * 8 : 3
        )
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ArtworkCache.shared.image(for: url) {
                image = cached
                color = ArtworkCache.shared.color(for: url)
                return
            }
            image = nil
            let loaded = await ArtworkCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.25)) {
                image = loaded
                color = ArtworkCache.shared.color(for: url)
            }
        }
    }

    private var placeholder: String {
        switch item?.kind {
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        case .station: "dot.radiowaves.left.and.right"
        default: "music.note"
        }
    }
}

// A cover melted into a blur. Blurring a small copy and scaling it up looks the same as
// blurring a big one and costs a fraction of the drawing.
struct BlurredArtwork: View {
    let item: MediaItem

    var body: some View {
        GeometryReader { geometry in
            let scale = max(geometry.size.width, geometry.size.height) / 48
            Artwork(item: item, size: 64, cornerRadius: 0)
                .blur(radius: 8, opaque: true)
                .frame(width: 64, height: 64)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .saturation(1.4)
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: Actions

extension PlayerStore {
    var catalog: MusicCatalog { MusicCatalog(engine: bridge) }

    func play(_ item: MediaItem, shuffle: Bool = false) {
        guard let key = item.kind.queueKey else { return }
        bridge.play(kind: key, id: item.queueID, shuffle: shuffle)
    }

    /// Plays a track inside the album or playlist it was picked from, so the rest follows.
    func play(_ tracks: [MediaItem], at index: Int, in collection: MediaItem?) {
        if let collection, let key = collection.kind.queueKey, collection.kind != .station {
            bridge.play(kind: key, id: collection.queueID, startWith: index)
        } else {
            bridge.play(songs: tracks.map(\.queueID), startWith: index)
        }
    }

    func playNext(_ item: MediaItem) {
        guard let key = item.kind.queueKey else { return }
        bridge.playNext(kind: key, id: item.queueID)
    }

    func playLater(_ item: MediaItem) {
        guard let key = item.kind.queueKey else { return }
        bridge.playLater(kind: key, id: item.queueID)
    }

    func isCurrent(_ item: MediaItem) -> Bool {
        guard let id = track?.id else { return false }
        return id == item.id || id == item.playID || id == item.catalogID
    }
}

// Right-click menu shared by tiles and rows.
struct ItemMenu: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store
    @Environment(\.openItem) private var openItem

    var body: some View {
        if item.isPlayable {
            Button("Play", systemImage: "play") { store.play(item) }
            if item.kind == .album || item.kind == .playlist {
                Button("Shuffle", systemImage: "shuffle") { store.play(item, shuffle: true) }
            }
            Divider()
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { store.playNext(item) }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { store.playLater(item) }
        }
        if item.kind == .album || item.kind == .playlist || item.kind == .artist {
            Button("Open", systemImage: "arrow.up.forward") { openItem(item) }
        }
        if !item.isLibrary, item.kind.ratingPath != nil {
            Divider()
            Button("Add to Library", systemImage: "plus") {
                Task { await store.catalog.addToLibrary(item) }
            }
        }
        if item.kind == .song {
            Menu("Add to Playlist") {
                Button("New Playlist…") {
                    PlaylistNamer.ask { name in
                        Task {
                            await store.catalog.createPlaylist(named: name, with: item)
                            await store.refreshLibraryPlaylists()
                        }
                    }
                }
                Divider()
                ForEach(store.libraryPlaylists) { playlist in
                    Button(playlist.title) { Task { await store.catalog.add(item, toPlaylist: playlist) } }
                }
            }
        }
        if item.kind.ratingPath != nil {
            Divider()
            Button("Love", systemImage: "heart") { Task { await store.catalog.rate(item, 1) } }
            Button("Suggest Less", systemImage: "hand.thumbsdown") { Task { await store.catalog.rate(item, -1) } }
        }
    }
}

@MainActor
enum PlaylistNamer {
    static func ask(_ completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { completion(name) }
    }
}

// MARK: Tiles

struct ItemTile: View {
    let item: MediaItem
    var size: CGFloat = 184

    @Environment(PlayerStore.self) private var store
    @Environment(\.openItem) private var openItem
    @State private var isHovered = false

    private var centered: Bool { item.kind == .artist }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            Artwork(item: item, size: size, cornerRadius: 14, isCircle: centered, glow: isHovered ? 1 : 0)
                .overlay(alignment: .bottomTrailing) {
                    if item.isPlayable, isHovered {
                        Button { store.play(item) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .songGlass(in: .circle, interactive: true)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.pointer)
                        .padding(10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .scaleEffect(isHovered ? 1.035 : 1)
            VStack(alignment: centered ? .center : .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title).lineLimit(1)
                    if item.isExplicit { ExplicitBadge() }
                }
                .font(.system(size: 13, weight: .semibold))
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(width: size, alignment: centered ? .center : .leading)
        }
        .contentShape(.rect)
        .clickable()
        .onTapGesture {
            if item.kind == .song { store.play([item], at: 0, in: nil) } else { openItem(item) }
        }
        .onHover { hovering in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { isHovered = hovering } }
        .contextMenu { ItemMenu(item: item) }
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8, weight: .heavy))
            .frame(width: 12, height: 12)
            .background(.white.opacity(0.25), in: .rect(cornerRadius: 3))
    }
}

// A large card for the first thing on a page.
struct HeroCard: View {
    let item: MediaItem
    let eyebrow: String

    @Environment(PlayerStore.self) private var store
    @Environment(\.openItem) private var openItem
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            BlurredArtwork(item: item)
                .overlay(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.1)], startPoint: .leading, endPoint: .trailing))
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(item.title)
                        .font(.system(size: 42, weight: .heavy))
                        .tracking(-0.8)
                        .lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if let note = item.note {
                        Text(note.strippingTags)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .frame(maxWidth: 460, alignment: .leading)
                    }
                    PlayButtons(item: item, play: { store.play(item) }, shuffle: { store.play(item, shuffle: true) })
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
                Artwork(item: item, size: 250, cornerRadius: 16, glow: 1)
                    .rotation3DEffect(.degrees(isHovered ? -4 : -9), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            }
            .padding(.horizontal, 44)
        }
        .frame(height: 330)
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(.rect)
        .clickable()
        .onTapGesture { openItem(item) }
        .onHover { hovering in withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { isHovered = hovering } }
        .contextMenu { ItemMenu(item: item) }
    }
}

extension String {
    var strippingTags: String {
        replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }
}

// MARK: Song rows

struct SongRow: View {
    @Environment(\.songTheme) private var theme

    let song: MediaItem
    let index: Int
    var showsArtwork = true
    var showsAlbum = true
    let play: () -> Void

    @Environment(PlayerStore.self) private var store
    @State private var isHovered = false

    private var isCurrent: Bool { store.isCurrent(song) }

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(song.title).lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }
                .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                .foregroundStyle(isCurrent ? theme.accent : .white)
                if showsArtwork {
                    Text(song.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text(song.album)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Menu {
                ItemMenu(item: song)
            } label: {
                Image(systemName: "ellipsis").frame(width: 34, height: 34).contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.pointer)
            .menuIndicator(.hidden)
            .opacity(isHovered ? 1 : 0)
            Text(Self.time(song.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: showsArtwork ? 56 : 44)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isCurrent ? 0.1 : isHovered ? 0.06 : 0))
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .clickable()
        .onTapGesture(count: 2, perform: play)
        .contextMenu { ItemMenu(item: song) }
    }

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if showsArtwork {
                Artwork(item: song, size: 40, cornerRadius: 8)
                    .opacity(isHovered || isCurrent ? 0.4 : 1)
            }
            if isHovered {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 40, height: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(.pointer)
            } else if isCurrent {
                Image(systemName: store.isPlaying ? "waveform" : "speaker.fill")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.variableColor.iterative, isActive: store.isPlaying)
            } else if !showsArtwork {
                Text("\(song.trackNumber ?? index + 1)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: showsArtwork ? 40 : 24)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SongList: View {
    let songs: [MediaItem]
    var collection: MediaItem? = nil
    var showsArtwork = true
    var showsAlbum = true

    @Environment(PlayerStore.self) private var store

    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongRow(song: song, index: index, showsArtwork: showsArtwork, showsAlbum: showsAlbum) {
                    store.play(songs, at: index, in: collection)
                }
            }
        }
    }
}

// MARK: Shelves

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .heavy))
            .tracking(-0.3)
            .padding(.horizontal, Layout.gutter)
    }
}

enum Layout {
    static let gutter: CGFloat = 34
    static let topInset: CGFloat = 64
    static let bottomInset: CGFloat = 130
}

struct ShelfView: View {
    let shelf: Shelf

    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: shelf.title)
            ScrollView(.horizontal, showsIndicators: false) {
                if shelf.isSongs {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 2), count: min(4, shelf.items.count)), spacing: 24) {
                        ForEach(Array(shelf.items.enumerated()), id: \.offset) { index, song in
                            SongRow(song: song, index: index, showsAlbum: false) {
                                store.play(shelf.items, at: index, in: nil)
                            }
                            .frame(width: 340)
                        }
                    }
                    .padding(.horizontal, Layout.gutter - 12)
                } else {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(shelf.items) { ItemTile(item: $0) }
                    }
                    .padding(.horizontal, Layout.gutter)
                    .padding(.vertical, 14)
                }
            }
            .scrollClipDisabled()
        }
    }
}

struct PageTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(title)
                .font(.system(size: 46, weight: .heavy))
                .tracking(-1.2)
        }
        .padding(.horizontal, Layout.gutter)
    }
}

// Play and Shuffle take their color from the album or playlist they belong to, so they
// stay put while songs change. Without one, they follow the playing song, or amber.
struct PlayButtons: View {
    static let defaultColor = Color(red: 1, green: 0.74, blue: 0.25)

    var item: MediaItem? = nil
    let play: () -> Void
    let shuffle: () -> Void

    @State private var color: Color?
    @Environment(\.songTheme) private var songTheme

    // Their own cover's color; otherwise the playing song's; otherwise amber.
    private var fill: Color {
        if let color { return color }
        return songTheme == SongTheme() ? Self.defaultColor : songTheme.accent
    }
    private var label: Color {
        let resolved = NSColor(fill).usingColorSpace(.sRGB) ?? .white
        let luminance = 0.2126 * resolved.redComponent + 0.7152 * resolved.greenComponent + 0.0722 * resolved.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(label)
                    .frame(width: 110, height: 40)
                    .background(fill, in: .capsule)
                    .shadow(color: fill.opacity(0.45), radius: 12, y: 4)
                    .contentShape(.capsule)
            }
            .buttonStyle(.pointer)
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 110, height: 40)
                    .glassEffect(.regular.tint(fill.opacity(0.18)).interactive(), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.pointer)
        }
        .task(id: item?.id) {
            guard let url = item?.artworkURL(128) else { color = nil; return }
            _ = await ArtworkCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.3)) { color = ArtworkCache.shared.color(for: url) }
        }
    }
}

struct GlassIconButton: View {
    @Environment(\.songTheme) private var theme

    let symbol: String
    var size: CGFloat = 40
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(isOn ? theme.onAccent : .white)
                .frame(width: size, height: size)
                .background(isOn ? theme.accent : .clear, in: .circle)
                .songGlass(in: .circle, interactive: true)
                .contentShape(.circle)
        }
        .buttonStyle(.pointer)
    }
}

// Loads once, shows a spinner meanwhile and a retry button if nothing came back.
struct Loading<Value, Content: View>: View {
    // Calls its argument with partial results as they arrive, then returns the whole thing.
    let load: (_ update: @escaping (Value) -> Void) async -> Value
    var isEmpty: (Value) -> Bool = { _ in false }
    @ViewBuilder let content: (Value) -> Content

    @State private var value: Value?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let value, !isEmpty(value) {
                content(value)
            } else if value != nil {
                VStack(spacing: 12) {
                    Text("Nothing here yet").font(.system(size: 16, weight: .bold))
                    Button { self.value = nil; attempt += 1 } label: {
                        Text("Try Again")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .songGlass(in: .capsule, interactive: true)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.pointer)
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ProgressView().controlSize(.regular).frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .task(id: attempt) {
            guard value == nil else { return }
            let loaded = await load { partial in
                guard !isEmpty(partial) else { return }
                withAnimation(.easeOut(duration: 0.3)) { value = partial }
            }
            withAnimation(.easeOut(duration: 0.3)) { value = loaded }
        }
    }
}

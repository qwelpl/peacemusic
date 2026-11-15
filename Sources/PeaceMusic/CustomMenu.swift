import AppKit
import SwiftUI

// Peace's own menu for songs, albums, playlists, artists and stations, opened from "…"
// buttons and right-clicks in place of the system menu.
@MainActor
@Observable
final class MenuPresenter {
    private(set) var item: MediaItem?
    // Where the menu opens, in window coordinates with the origin at the top left.
    private(set) var anchor: CGPoint = .zero

    func show(_ item: MediaItem, at point: CGPoint) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            self.item = item
            anchor = point
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.14)) { item = nil }
    }
}

extension EnvironmentValues {
    @Entry var menuPresenter: MenuPresenter? = nil
}

extension View {
    // Right-click (or Control-click) opens Peace's menu for the item.
    func itemMenu(_ item: MediaItem) -> some View {
        modifier(ItemMenuModifier(item: item))
    }
}

private struct ItemMenuModifier: ViewModifier {
    let item: MediaItem

    @Environment(\.menuPresenter) private var presenter

    func body(content: Content) -> some View {
        content.overlay {
            RightClickCatcher { point in presenter?.show(item, at: point) }
        }
    }
}

// Sits over a view and takes only right-clicks, so left clicks and hovers pass through.
private struct RightClickCatcher: NSViewRepresentable {
    let action: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (CGPoint) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isSecondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isSecondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { report(event) }
        override func mouseDown(with event: NSEvent) { report(event) }

        private func report(_ event: NSEvent) {
            guard let content = window?.contentView else { return }
            let point = content.convert(event.locationInWindow, from: nil)
            action(CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y))
        }
    }
}

// A "…" button that opens the menu just below the pointer.
struct MoreButton: View {
    let item: MediaItem
    var size: CGFloat = 34
    var glass = false

    @Environment(\.menuPresenter) private var presenter

    var body: some View {
        Button {
            presenter?.show(item, at: Self.pointer())
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: glass ? 14 : 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background {
                    if glass { Color.clear.songGlass(in: .circle, interactive: true) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.pointer)
    }

    // Opens at the pointer. Tracking every button's frame instead made each resize and
    // scroll update every row.
    private static func pointer() -> CGPoint {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return .zero }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return CGPoint(x: point.x - 12, y: (content.isFlipped ? point.y : content.bounds.height - point.y) + 14)
    }
}

// Draws the open menu above everything else in the window.
struct MenuLayer: View {
    let presenter: MenuPresenter

    @Environment(PlayerStore.self) private var store
    @Environment(\.openItem) private var openItem
    @Environment(\.songTheme) private var theme
    @State private var page = Page.main
    @State private var size = CGSize(width: 260, height: 300)
    @State private var newName = ""
    @FocusState private var naming: Bool

    enum Page { case main, playlists, newPlaylist }

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let item = presenter.item {
                    Color.black.opacity(0.001)
                        .onTapGesture { presenter.dismiss() }
                    panel(item)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .offset(position(in: proxy.size, origin: origin))
                        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                    Button("") { presenter.dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .onChange(of: presenter.item?.id) {
            page = .main
            newName = ""
        }
    }

    // Keeps the menu inside the window, opening upward near the bottom.
    private func position(in bounds: CGSize, origin: CGPoint) -> CGSize {
        var x = presenter.anchor.x - origin.x
        var y = presenter.anchor.y - origin.y
        x = min(max(x, 8), bounds.width - size.width - 8)
        if y + size.height > bounds.height - 8 { y = max(y - size.height - 12, 8) }
        return CGSize(width: x, height: y)
    }

    private func panel(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(item)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 1) {
                switch page {
                case .main: mainRows(item)
                case .playlists: playlistRows(item)
                case .newPlaylist: newPlaylistRows(item)
                }
            }
            .padding(6)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: page)
        }
        .frame(width: 260)
        .songGlass(in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
    }

    private func header(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            Artwork(item: item, size: 40, cornerRadius: 8, isCircle: item.kind == .artist)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func mainRows(_ item: MediaItem) -> some View {
        if item.isPlayable {
            MenuRow(title: "Play", symbol: "play.fill") { run { store.play(item) } }
            if item.kind == .album || item.kind == .playlist {
                MenuRow(title: "Shuffle", symbol: "shuffle") { run { store.play(item, shuffle: true) } }
            }
            MenuDivider()
            MenuRow(title: "Play Next", symbol: "text.line.first.and.arrowtriangle.forward") { run { store.playNext(item) } }
            MenuRow(title: "Play Last", symbol: "text.line.last.and.arrowtriangle.forward") { run { store.playLater(item) } }
        }
        if item.kind == .album || item.kind == .playlist || item.kind == .artist {
            MenuRow(title: "Open", symbol: "arrow.up.forward") { run { openItem(item) } }
        }
        if !item.isLibrary, item.kind.ratingPath != nil {
            MenuDivider()
            MenuRow(title: "Add to Library", symbol: "plus") { run { Task { await store.catalog.addToLibrary(item) } } }
        }
        if item.kind == .song {
            MenuRow(title: "Add to Playlist", symbol: "music.note.list", opensPage: true) { page = .playlists }
        }
        if item.kind.ratingPath != nil {
            MenuDivider()
            MenuRow(title: "Love", symbol: "heart") { run { Task { await store.catalog.rate(item, 1) } } }
            MenuRow(title: "Suggest Less", symbol: "hand.thumbsdown") { run { Task { await store.catalog.rate(item, -1) } } }
        }
    }

    @ViewBuilder
    private func playlistRows(_ item: MediaItem) -> some View {
        MenuRow(title: "Back", symbol: "chevron.left") { page = .main }
        MenuDivider()
        MenuRow(title: "New Playlist…", symbol: "plus") {
            page = .newPlaylist
            naming = true
        }
        ScrollView {
            VStack(spacing: 1) {
                ForEach(store.libraryPlaylists) { playlist in
                    MenuRow(title: playlist.title, artwork: playlist) {
                        run { Task { await store.catalog.add(item, toPlaylist: playlist) } }
                    }
                }
            }
        }
        .frame(maxHeight: 260)
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func newPlaylistRows(_ item: MediaItem) -> some View {
        MenuRow(title: "Back", symbol: "chevron.left") { page = .playlists }
        MenuDivider()
        HStack(spacing: 8) {
            TextField("Playlist name", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($naming)
                .onSubmit { create(with: item) }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 9, style: .continuous))
            Button { create(with: item) } label: {
                Text("Create")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .accentFill(in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.pointer)
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(4)
    }

    private func create(with item: MediaItem) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run {
            Task {
                await store.catalog.createPlaylist(named: name, with: item)
                await store.refreshLibraryPlaylists()
            }
        }
    }

    private func run(_ action: () -> Void) {
        action()
        presenter.dismiss()
    }
}

private struct MenuRow: View {
    let title: String
    var symbol: String? = nil
    var artwork: MediaItem? = nil
    var opensPage = false
    let action: () -> Void

    @Environment(\.songTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let artwork {
                    Artwork(item: artwork, size: 22, cornerRadius: 5)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 20)
                        .foregroundStyle(isHovered ? theme.onAccent : .white.opacity(0.75))
                }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if opensPage {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.5)
                }
            }
            .foregroundStyle(isHovered ? theme.onAccent : .white)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isHovered ? theme.accent.opacity(0.9) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.pointer)
        .onHover { isHovered = $0 }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 8).padding(.vertical, 4)
    }
}

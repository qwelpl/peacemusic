import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlayerStore
    let miniPlayer: MiniPlayerController
    let analyzer = MusicAnalyzer()

    override init() {
        store = PlayerStore()
        miniPlayer = MiniPlayerController(store: store, analyzer: analyzer)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        // Menu bar apps don't come to the front on launch, which leaves keys with no window.
        if !CommandLine.arguments.contains("--mini") { NSApp.activate(ignoringOtherApps: true) }
        if CommandLine.arguments.contains("--mini") {
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                miniPlayer.open()
                if CommandLine.arguments.contains("--mini-expanded") { miniPlayer.setExpanded(true) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        miniPlayer.close()
        return true
    }
}

@main
struct PeaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Peace", id: "main") {
            NowPlayingView()
                .environment(delegate.store)
                .environment(delegate.miniPlayer)
                .environment(\.musicAnalyzer, delegate.analyzer)
                .frame(minWidth: 900, minHeight: 620)
                .windowFullScreenBehavior(.enabled)
                .connectMainWindow(to: delegate.miniPlayer)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Mini Player") { delegate.miniPlayer.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Peace", systemImage: "music.note") {
            MenuBarMenu()
                .environment(delegate.store)
                .environment(delegate.miniPlayer)
                .connectMainWindow(to: delegate.miniPlayer)
        }
    }
}

private struct MenuBarMenu: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @AppStorage(LyricSettings.fontKey) private var fontRaw = LyricFont.theme.rawValue
    @AppStorage(LyricSettings.scaleKey) private var lyricScale = 1.0

    var body: some View {
        if let track = store.track {
            Text(track.title)
            Text(track.artist)
            Divider()
        }
        Button(store.isPlaying ? "Pause" : "Play", action: store.togglePlayPause)
        Button("Next", action: store.next)
        Button("Previous", action: store.previous)
        Divider()
        Button("Show Peace", action: miniPlayer.showMainWindow)
        Button(miniPlayer.isOpen ? "Hide Mini Player" : "Show Mini Player", action: miniPlayer.toggle)
        Toggle("Keep Mini Player Expanded", isOn: Binding(get: { miniPlayer.isPinned }, set: { _ in miniPlayer.togglePinned() }))
        Divider()
        Section("Font") {
            Picker("Font", selection: $fontRaw) {
                ForEach(LyricFont.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Section("Text Size · \(Int((lyricScale * 100).rounded()))%") {
            Button("Larger") { setLyricScale(lyricScale + LyricSettings.scaleStep) }
                .keyboardShortcut("+")
                .disabled(lyricScale >= LyricSettings.scaleRange.upperBound)
            Button("Smaller") { setLyricScale(lyricScale - LyricSettings.scaleStep) }
                .keyboardShortcut("-")
                .disabled(lyricScale <= LyricSettings.scaleRange.lowerBound)
            Button("Reset") { setLyricScale(1) }
                .keyboardShortcut("0")
                .disabled(lyricScale == 1)
        }
        Divider()
        Button("Quit Peace") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func setLyricScale(_ scale: Double) {
        lyricScale = LyricSettings.clampedScale(scale)
    }
}

private struct ConnectMainWindow: ViewModifier {
    let miniPlayer: MiniPlayerController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            miniPlayer.openMainWindow = { openWindow(id: "main") }
        }
    }
}

private extension View {
    func connectMainWindow(to miniPlayer: MiniPlayerController) -> some View {
        modifier(ConnectMainWindow(miniPlayer: miniPlayer))
    }
}

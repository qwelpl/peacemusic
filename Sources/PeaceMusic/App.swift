import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlayerStore
    let miniPlayer: MiniPlayerController
    let analyzer = MusicAnalyzer()
    let displays: DisplayPicker
    private let screenAwake: ScreenAwake

    override init() {
        store = PlayerStore()
        miniPlayer = MiniPlayerController(store: store, analyzer: analyzer)
        screenAwake = ScreenAwake(store: store)
        displays = DisplayPicker(miniPlayer: miniPlayer)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        screenAwake.start()
        if ResizeBench.isRequested {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if miniPlayer.isOpen { miniPlayer.close() } else { miniPlayer.showMainWindow() }
                await ResizeBench.run(label: ResizeBench.page ?? "home")
            }
        }
        // Gives the main window time to appear before moving it.
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            displays.start()
        }
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

    func openSettings() {
        if miniPlayer.isOpen { miniPlayer.close() } else { miniPlayer.showMainWindow() }
        NotificationCenter.default.post(name: .peaceOpenSettings, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clicking the Dock icon brings back the full window, from the mini player too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if miniPlayer.isOpen {
            miniPlayer.close()
        } else {
            miniPlayer.showMainWindow()
        }
        return false
    }
}

@main
struct PeaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Peace", id: "main") {
            MusicAppView()
                .environment(delegate.store)
                .environment(delegate.displays)
                .environment(delegate.miniPlayer)
                .environment(\.musicAnalyzer, delegate.analyzer)
                .frame(minWidth: 1180, minHeight: 640)
                .windowFullScreenBehavior(.enabled)
                .connectMainWindow(to: delegate.miniPlayer)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            // ⌘, opens Peace's own Settings page instead of a separate macOS window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.openSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .windowArrangement) {
                Button("Mini Player") { delegate.miniPlayer.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Peace", systemImage: "music.note") {
            MenuBarMenu(openSettings: delegate.openSettings)
                .environment(delegate.store)
                .environment(delegate.miniPlayer)
                .connectMainWindow(to: delegate.miniPlayer)
        }
    }
}

// The menu bar keeps only quick controls; everything else lives in Peace's Settings page.
private struct MenuBarMenu: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    let openSettings: () -> Void

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
        Divider()
        Button("Settings…", action: openSettings)
            .keyboardShortcut(",")
        Button("Quit Peace") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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

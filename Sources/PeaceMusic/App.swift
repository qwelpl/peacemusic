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
        if CommandLine.arguments.contains("--mini") {
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                miniPlayer.open()
                if CommandLine.arguments.contains("--mini-expanded") { miniPlayer.setExpanded(true) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !miniPlayer.isOpen
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
    }
}

import AppKit
import Observation

// Which display Peace lives on. Remembered by name, so it sticks when that display reconnects.
@MainActor
@Observable
final class DisplayPicker {
    private static let key = "display"

    private(set) var names: [String] = []
    private(set) var selected: String

    private let miniPlayer: MiniPlayerController
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(miniPlayer: MiniPlayerController) {
        self.miniPlayer = miniPlayer
        selected = UserDefaults.standard.string(forKey: Self.key) ?? NSScreen.main?.localizedName ?? ""
        refresh()
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.apply()
            }
        }
        if UserDefaults.standard.string(forKey: Self.key) != nil { apply() }
    }

    func select(_ name: String) {
        selected = name
        UserDefaults.standard.set(name, forKey: Self.key)
        apply()
    }

    private func refresh() {
        names = NSScreen.screens.map(\.localizedName)
    }

    private func apply() {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == selected }) else { return }
        miniPlayer.move(to: screen)
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }),
              window.screen != screen else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            // Moving mid-transition is ignored, so wait for full screen to finish leaving.
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                Self.center(window, on: screen)
                window.toggleFullScreen(nil)
            }
        } else {
            Self.center(window, on: screen)
        }
    }

    private static func center(_ window: NSWindow, on screen: NSScreen) {
        let area = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
        window.setFrame(NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: true)
    }
}

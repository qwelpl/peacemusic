import AppKit
import Observation

// True while a window is being dragged to a new size, so moving things can hold still.
@MainActor
@Observable
final class LiveResize {
    static let shared = LiveResize()

    private(set) var isActive = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveResize.shared.isActive = true }
        }
        center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveResize.shared.isActive = false }
        }
    }
}

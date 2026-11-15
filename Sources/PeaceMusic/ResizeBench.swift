import AppKit

// `--resize-bench`: resizes the main window step by step and writes how long each step took
// to ~/Library/Logs/Peace/resize.log. `--page <name>` picks the page first.
@MainActor
enum ResizeBench {
    static var isRequested: Bool { CommandLine.arguments.contains("--resize-bench") }

    static var page: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--page"), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func run(label: String) async {
        try? await Task.sleep(for: .seconds(10))
        let windows = NSApp.windows.map { "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height)) visible \($0.isVisible) alpha \($0.alphaValue)" }
        write("\(label) windows: \(windows.joined(separator: "; "))\n")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 900 && $0.alphaValue > 0 }) else { return }
        let start = window.frame
        var times: [Double] = []
        for step in Array(0...30) + Array((0...30).reversed()) {
            let frame = NSRect(x: start.minX, y: start.minY, width: max(start.width, 2400) - Double(step) * 25, height: max(start.height, 1100) - Double(step) * 8)
            let began = CACurrentMediaTime()
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            times.append((CACurrentMediaTime() - began) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        window.setFrame(start, display: true)
        let sorted = times.sorted()
        let line = String(format: "%@ mean %.1f ms, median %.1f ms, worst %.1f ms\n", label, times.reduce(0, +) / Double(times.count), sorted[sorted.count / 2], sorted.last ?? 0)
        write(line)
    }

    private static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Peace/resize.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

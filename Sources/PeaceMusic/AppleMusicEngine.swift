import AppKit
import OSLog
import WebKit

// Plays Apple Music through Apple's own web player, loaded in a hidden web view and
// driven through its MusicKit instance. Music.app never needs to run.
@MainActor
final class AppleMusicEngine: NSObject {
    private(set) var snapshot = PlayerSnapshot()
    private(set) var status: BridgeStatus = .loading
    var onChange: () -> Void = {}

    private var webView: WKWebView!
    private var hostWindow: NSWindow?
    private var signInWindow: NSWindow?
    private var popupWindows: [WKWebView: NSWindow] = [:]
    private var artworkURL: URL?
    private var playlistTracks: [String: [Track]] = [:]
    private var started = false

    private static let logger = WebLog()
    private static let home = URL(string: "https://music.apple.com/us/browse")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    func start() {
        guard !started else { return }
        started = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(WeakMessageHandler(self), name: "peace")
        configuration.userContentController.add(WeakMessageHandler(self), name: "peaceLog")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.navigationDelegate = self
        keepPageAwake()
        hide()
        webView.load(URLRequest(url: Self.home))
    }

    // The web view lives in an invisible window, so WebKit treats the page as on screen
    // and keeps playing at full speed.
    private func hide() {
        let window = hostWindow ?? {
            let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
            hostWindow = window
            return window
        }()
        window.contentView = webView
        window.orderBack(nil)
        setPageHidden(true)
    }

    // A full-screen visualizer covers the invisible window. WebKit would then treat the page
    // as hidden and throttle its timers, and MusicKit stops moving on to the next song.
    private func keepPageAwake() {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            Self.logger.notice("occlusion detection can't be turned off")
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(webView, selector, false)
    }

    // Apple's page keeps animating while it's hidden. Hiding its content stops the drawing
    // without touching the player underneath.
    private func setPageHidden(_ hidden: Bool) {
        let css = hidden ? "html { visibility: hidden !important; } * { animation: none !important; transition: none !important; }" : ""
        webView?.evaluateJavaScript("""
        (() => {
            let style = document.getElementById('peace-hide');
            if (!style) { style = document.createElement('style'); style.id = 'peace-hide'; document.documentElement.appendChild(style); }
            style.textContent = \(String(reflecting: css));
        })();
        """)
    }

    // MARK: Sign in

    func showSignIn() {
        let window = signInWindow ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Sign in to Apple Music"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            signInWindow = window
            return window
        }()
        window.contentView = webView
        setPageHidden(false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { try? await call("await music.authorize()") }
    }

    func signOut() {
        send("await music.unauthorize()")
        status = .signedOut
        onChange()
    }

    private func finishSignIn() {
        guard let window = signInWindow, window.isVisible else { return }
        window.orderOut(nil)
        hide()
    }

    // MARK: JavaScript

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { return nil }
        let script = "const music = MusicKit.getInstance(); \(body)"
        return try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    private func send(_ body: String, _ arguments: [String: Any] = [:]) {
        Task {
            do {
                _ = try await call(body, arguments)
            } catch {
                Self.logger.error("command failed: \(error) in \(body.prefix(120))")
            }
        }
    }

    // Calls the Apple Music API through the page's MusicKit, which carries its own token.
    // {storefront} in the path becomes the account's storefront.
    func api(_ path: String, _ parameters: [String: Any] = [:], method: String = "GET", body: Any? = nil) async -> [String: Any]? {
        // The page's MusicKit isn't ready until it has reported in and signed in.
        for _ in 0..<150 where status != .ok {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let bodyText = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        let result: Any?
        do {
            result = try await call("""
        const path = rawPath.replace('{storefront}', music.storefrontId);
        const fetchOptions = { method };
        if (bodyText) { fetchOptions.body = bodyText; fetchOptions.headers = { 'Content-Type': 'application/json' }; }
        const response = await music.api.music(path, parameters, { fetchOptions });
        return JSON.stringify(response.data ?? {});
        """, ["rawPath": path, "parameters": parameters, "method": method, "bodyText": bodyText ?? ""])
        } catch {
            Self.logger.error("api \(method) \(path): \(error)")
            result = nil
        }
        guard let text = result as? String, let data = text.data(using: .utf8) else {
            Self.logger.error("api \(method) \(path) returned nothing")
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Queue

    /// Starts playing a song, album, playlist or station. Library IDs work too.
    /// `song` is played on its own if the album or playlist won't start at it.
    func play(kind: String, id: String, startWith index: Int? = nil, song: String? = nil, shuffle: Bool = false) {
        send("""
        music.shuffleMode = shuffle ? 1 : 0;
        const options = { startPlaying: true };
        options[kind] = id;
        if (index !== null) options.startWith = index;
        try {
            await music.setQueue(options);
        } catch (error) {
            if (!song) throw error;
            console.warn('peace play fallback: ' + error);
            await music.setQueue({ song, startPlaying: true });
        }
        """, ["kind": kind, "id": id, "index": index as Any? ?? NSNull(), "song": song as Any? ?? NSNull(), "shuffle": shuffle])
    }

    func play(songs ids: [String], startWith index: Int) {
        send("music.shuffleMode = 0; await music.setQueue({ songs: ids, startWith: index, startPlaying: true })", ["ids": ids, "index": index])
    }

    func playNext(kind: String, id: String) {
        send("const options = {}; options[kind] = id; await music.playNext(options)", ["kind": kind, "id": id])
    }

    func playLater(kind: String, id: String) {
        send("const options = {}; options[kind] = id; await music.playLater(options)", ["kind": kind, "id": id])
    }

    struct QueueEntry: Identifiable, Hashable {
        let index: Int
        let title: String
        let artist: String
        let artwork: String?
        var id: Int { index }
    }

    /// Everything in the queue and where playback is in it.
    func queue() async -> (entries: [QueueEntry], position: Int) {
        let result = try? await call("""
        const items = music.queue.items.map(item => ({
            title: item.title || '',
            artist: item.artistName || '',
            artwork: (item.artwork && item.artwork.url) || null,
        }));
        return JSON.stringify({ items, position: music.queue.position });
        """)
        guard let text = result as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], 0) }
        let items = object["items"] as? [[String: Any]] ?? []
        let entries = items.enumerated().map { index, item in
            QueueEntry(index: index, title: item["title"] as? String ?? "", artist: item["artist"] as? String ?? "", artwork: item["artwork"] as? String)
        }
        return (entries, object["position"] as? Int ?? 0)
    }

    /// The songs queued after the current one.
    func upcoming(_ count: Int) async -> [Track] {
        let result = try? await call("""
        const start = music.queue.position + 1;
        return JSON.stringify(music.queue.items.slice(start, start + count).map(item => ({
            id: item.id, title: item.title || '', artist: item.artistName || '',
            album: item.albumName || '', duration: item.playbackDuration || 0,
        })));
        """, ["count": count])
        guard let text = result as? String, let data = text.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Track(
                id: id,
                title: item["title"] as? String ?? "",
                artist: item["artist"] as? String ?? "",
                album: item["album"] as? String ?? "",
                duration: (item["duration"] as? Double ?? 0) / 1000
            )
        }
    }

    func jump(toQueueIndex index: Int) {
        send("await music.changeToMediaAtIndex(index)", ["index": index])
    }

    // MARK: State from the page

    fileprivate func log(_ body: Any) {
        Self.logger.notice("page: \(String(describing: body))")
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if let authorized = message["authorized"] as? Bool {
            if (authorized ? BridgeStatus.ok : .signedOut) != status {
                Self.logger.notice("authorized: \(authorized)")
            }
            status = authorized ? .ok : .signedOut
            if authorized { finishSignIn() }
        }
        var next = snapshot
        next.state = switch message["state"] as? Int {
        case 2: .playing
        case 1, 6, 8, 9: snapshot.state == .playing ? .playing : .paused
        case 3: .paused
        default: next.track == nil ? .stopped : .paused
        }
        next.position = message["time"] as? Double ?? 0
        next.volume = message["volume"] as? Double ?? 1
        next.shuffle = (message["shuffle"] as? Int ?? 0) != 0
        next.repeatMode = switch message["repeat"] as? Int {
        case 1: .one
        case 2: .all
        default: .off
        }
        if let item = message["item"] as? [String: Any], let id = item["id"] as? String {
            if id != snapshot.track?.id { next.favorited = false; loadRating(id) }
            next.track = Track(
                id: id,
                title: item["title"] as? String ?? "",
                artist: item["artist"] as? String ?? "",
                album: item["album"] as? String ?? "",
                duration: (item["duration"] as? Double ?? 0) / 1000
            )
            artworkURL = (item["artwork"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "{w}", with: "1200").replacingOccurrences(of: "{h}", with: "1200")) }
        } else {
            next.track = nil
            artworkURL = nil
        }
        next.capturedAt = Date()
        snapshot = next
        onChange()
    }

    private func loadRating(_ id: String) {
        Task {
            let rating = await api("/v1/me/ratings/songs/\(id)")
            let value = ((rating?["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any])?["value"] as? Int
            guard snapshot.track?.id == id else { return }
            snapshot.favorited = value == 1
            onChange()
        }
    }

    // MARK: The same calls the Music.app bridge offered

    func fetchSnapshot(completion: @escaping (PlayerSnapshot?, BridgeStatus) -> Void) {
        var current = snapshot
        if current.state == .playing {
            current.position += Date().timeIntervalSince(current.capturedAt)
        }
        current.capturedAt = Date()
        completion(current, status)
    }

    func fetchCurrentArtwork(completion: @escaping (Data?) -> Void) {
        guard let artworkURL else { return completion(nil) }
        Task {
            let data = try? await URLSession.shared.data(from: artworkURL).0
            completion(data)
        }
    }

    func playPause() { send("music.isPlaying ? music.pause() : await music.play()") }
    func next() { send("await music.skipToNextItem()") }
    func previous() { send("music.currentPlaybackTime > 3 ? await music.seekToTime(0) : await music.skipToPreviousItem()") }
    func seek(to seconds: Double) { send("await music.seekToTime(seconds)", ["seconds": seconds]) }
    func setVolume(_ volume: Double) { send("music.volume = volume", ["volume": volume]) }
    func setShuffle(_ on: Bool) { send("music.shuffleMode = on ? 1 : 0", ["on": on]) }
    func setRepeat(_ mode: RepeatMode) {
        send("music.repeatMode = mode", ["mode": mode == .one ? 1 : mode == .all ? 2 : 0])
    }

    func setFavorited(_ on: Bool) {
        guard let id = snapshot.track?.id else { return }
        send("""
        const path = `/v1/me/ratings/songs/${id}`;
        if (on) {
            await music.api.music(path, {}, { fetchOptions: { method: 'PUT', body: JSON.stringify({ type: 'rating', attributes: { value: 1 } }) } });
        } else {
            await music.api.music(path, {}, { fetchOptions: { method: 'DELETE' } });
        }
        """, ["id": id, "on": on])
    }

    // Apple's own lyrics, timed syllable by syllable, as TTML. Nil when the song has none.
    func syllableLyrics(for id: String) async -> String? {
        var catalogID = id
        if !id.allSatisfy(\.isNumber) {
            let response = await api("/v1/me/library/songs/\(id)/catalog")
            guard let found = (response?["data"] as? [[String: Any]])?.first?["id"] as? String else { return nil }
            catalogID = found
        }
        let response = await api("/v1/catalog/{storefront}/songs/\(catalogID)/syllable-lyrics")
        let attributes = (response?["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any]
        return attributes?["ttml"] as? String
    }

    func fetchPlaylists(completion: @escaping ([Playlist]) -> Void) {
        Task {
            let response = await api("/v1/me/library/playlists", ["limit": 100])
            let items = response?["data"] as? [[String: Any]] ?? []
            completion(items.compactMap { item in
                guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any] else { return nil }
                return Playlist(id: id, name: attributes["name"] as? String ?? "", trackCount: 0)
            })
        }
    }

    func fetchTracks(playlistID: String, limit: Int = 300, completion: @escaping ([Track]) -> Void) {
        Task {
            var tracks: [Track] = []
            var path: String? = "/v1/me/library/playlists/\(playlistID)/tracks"
            while let current = path, tracks.count < limit {
                let response = await api(current, ["limit": 100])
                tracks += Self.tracks(in: response)
                path = response?["next"] as? String
            }
            playlistTracks[playlistID] = tracks
            completion(tracks)
        }
    }

    func search(_ query: String, limit: Int = 25, completion: @escaping ([Track]) -> Void) {
        Task {
            let response = await api("/v1/catalog/{storefront}/search", ["term": query, "types": "songs", "limit": limit])
            let songs = ((response?["results"] as? [String: Any])?["songs"] as? [String: Any])
            completion(Self.tracks(in: songs))
        }
    }

    func fetchPlaylistArtwork(playlistID: String, completion: @escaping (Data?) -> Void) {
        Task {
            let response = await api("/v1/me/library/playlists/\(playlistID)")
            let attributes = (response?["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any]
            guard let template = (attributes?["artwork"] as? [String: Any])?["url"] as? String,
                  let url = URL(string: template.replacingOccurrences(of: "{w}", with: "300").replacingOccurrences(of: "{h}", with: "300"))
            else { return completion(nil) }
            completion(try? await URLSession.shared.data(from: url).0)
        }
    }

    func play(playlistID: String) {
        send("await music.setQueue({ playlist: id, startPlaying: true })", ["id": playlistID])
    }

    func play(trackID: String, playlistID: String?) {
        if let playlistID, let index = playlistTracks[playlistID]?.firstIndex(where: { $0.id == trackID }) {
            send("await music.setQueue({ playlist: id, startWith: index, startPlaying: true })", ["id": playlistID, "index": index])
        } else {
            send("await music.setQueue({ song: id, startPlaying: true })", ["id": trackID])
        }
    }

    private static func tracks(in response: [String: Any]?) -> [Track] {
        (response?["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any] else { return nil }
            let playable = (attributes["playParams"] as? [String: Any])?["id"] as? String
            guard let id = playable ?? item["id"] as? String else { return nil }
            return Track(
                id: id,
                title: attributes["name"] as? String ?? "",
                artist: attributes["artistName"] as? String ?? "",
                album: attributes["albumName"] as? String ?? "",
                duration: (attributes["durationInMillis"] as? Double ?? 0) / 1000
            )
        }
    }

    // Waits for the page's MusicKit, then reports every change back to Peace.
    private static let consoleScript = """
    (() => {
        const send = (level, args) => {
            try { window.webkit.messageHandlers.peaceLog.postMessage(location.host + ' ' + level + ': ' + Array.from(args).map(String).join(' ')); } catch (e) {}
        };
        const error = console.error, warn = console.warn;
        console.error = function () { send('error', arguments); error.apply(console, arguments); };
        console.warn = function () { send('warn', arguments); warn.apply(console, arguments); };
        window.addEventListener('error', e => send('uncaught', [e.message]));
        window.addEventListener('message', e => send('message from ' + e.origin, [typeof e.data === 'string' ? e.data.slice(0, 200) : JSON.stringify(e.data).slice(0, 200)]));
    })();
    """

    private static let bridgeScript = """
    (() => {
        // MusicKit's currentPlaybackTime is whole seconds; the media element has the exact time.
        let logged = null;
        const preciseTime = music => {
            const rounded = music.currentPlaybackTime || 0;
            const media = document.querySelector('#apple-music-player') || document.querySelector('audio, video');
            const exact = media && isFinite(media.currentTime) ? media.currentTime : NaN;
            const id = music.nowPlayingItem && music.nowPlayingItem.id;
            if (id && logged !== id && rounded > 2) {
                logged = id;
                console.warn('peace time: musickit ' + rounded + ' media ' + exact);
            }
            return isFinite(exact) && Math.abs(exact - rounded) < 1.5 ? exact : rounded;
        };
        const post = () => {
            const music = MusicKit.getInstance();
            const item = music.nowPlayingItem;
            window.webkit.messageHandlers.peace.postMessage({
                authorized: music.isAuthorized,
                state: music.playbackState,
                time: preciseTime(music),
                volume: music.volume,
                shuffle: music.shuffleMode,
                repeat: music.repeatMode,
                item: item ? {
                    id: item.id,
                    title: item.title,
                    artist: item.artistName,
                    album: item.albumName,
                    duration: item.playbackDuration,
                    artwork: item.artwork && item.artwork.url,
                } : null,
            });
        };
        const attach = () => {
            if (!window.MusicKit || !MusicKit.getInstance || !MusicKit.getInstance()) return setTimeout(attach, 300);
            const music = MusicKit.getInstance();
            for (const name of ['playbackStateDidChange', 'nowPlayingItemDidChange', 'authorizationStatusDidChange',
                                'shuffleModeDidChange', 'repeatModeDidChange', 'playbackVolumeDidChange', 'queueItemsDidChange']) {
                music.addEventListener(name, post);
            }
            setInterval(post, 1000);
            document.addEventListener('visibilitychange', () => console.warn('peace visibility: ' + document.visibilityState));
            post();
        };
        attach();
    })();
    """
}

extension AppleMusicEngine: WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    // Apple's sign-in opens in a popup.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        Self.logger.notice("popup: \(navigationAction.request.url?.absoluteString ?? "-")")
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.navigationDelegate = self
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Apple Account"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows[popup] = window
        return popup
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView == self.webView, signInWindow?.isVisible != true { setPageHidden(true) }
        Self.logger.notice("loaded: \(webView.url?.absoluteString ?? "-") popup: \(webView != self.webView)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("failed to start: \(error.localizedDescription)")
    }

    func webViewDidClose(_ webView: WKWebView) {
        Self.logger.notice("popup closed")
        popupWindows.removeValue(forKey: webView)?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === signInWindow else { return }
        DispatchQueue.main.async { self.hide() }
    }
}

// WKUserContentController holds its handlers strongly.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var engine: AppleMusicEngine?

    init(_ engine: AppleMusicEngine) { self.engine = engine }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let name = message.name
        MainActor.assumeIsolated {
            if name == "peaceLog" { engine?.log(body) } else { engine?.receive(body) }
        }
    }
}

// Writes to ~/Library/Logs/Peace/web.log as well as the system log, so sign-in problems can be read back.
private struct WebLog {
    private let logger = Logger(subsystem: "com.qwelpl.peacemusic", category: "web")
    private static let file: URL = {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Peace", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("web.log")
    }()

    func notice(_ message: String) { write(message) }
    func error(_ message: String) { write("error: " + message) }

    private func write(_ message: String) {
        logger.notice("\(message)")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.file)
        }
    }
}

import Foundation
import Network
import Combine

/// One request from web-scrobbler's "Webhook" scrobbler
/// (`src/core/scrobbler/webhook-scrobbler.ts`). `song` is a `JSON.stringify`d
/// `Song`, so only plain fields arrive, never its getters. Everything is
/// optional and unknown keys are ignored — the extension adds fields freely
/// (`controllerTabId` isn't even in its own type).
struct WebScrobblerEvent: Decodable {
    let eventName: String
    /// Milliseconds since epoch, when the extension sent it.
    let time: Double
    let data: Payload

    struct Payload: Decodable {
        let song: Song?
    }

    struct Song: Decodable {
        let parsed: Fields?
        let processed: Fields?
        let metadata: Metadata?
    }

    struct Fields: Decodable {
        let track: String?
        let artist: String?
        let album: String?
        /// Seconds.
        let duration: Double?
        let currentTime: Double?
        let isPlaying: Bool?
        let uniqueID: String?
    }

    struct Metadata: Decodable {
        /// Seconds since epoch (unlike `time`). A replay of the same video gets a new one.
        let startTimestamp: Double?
    }
}

/// Folds the event stream into one snapshot. The extension sends no position
/// heartbeat and no "stopped" — closing the tab just goes quiet — so position
/// is projected from the last event and the track expires on its own.
struct WebScrobblerState {
    private var last: NowPlayingSnapshot?
    private var lastAt: Date = .distantPast

    static let playingGrace: TimeInterval = 30
    static let pausedTimeout: TimeInterval = 10 * 60
    /// For tracks without a duration (live streams, some connectors).
    static let unknownDurationTimeout: TimeInterval = 15 * 60

    mutating func apply(_ event: WebScrobblerEvent, now: Date) {
        guard let song = event.data.song else { return }
        let p = song.parsed, q = song.processed
        // Same precedence as web-scrobbler's own BaseSong getters: processed
        // (user edits, Last.fm corrections) for text, parsed for duration.
        let title = q?.track ?? p?.track ?? ""
        let artist = q?.artist ?? p?.artist ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return }

        let isPlaying: Bool
        switch event.eventName {
        case "paused": isPlaying = false
        case "nowplaying", "resumedplaying": isPlaying = true
        // scrobble / loved carry no transition.
        default: isPlaying = p?.isPlaying ?? last?.isPlaying ?? true
        }

        let sentAt = Date(timeIntervalSince1970: event.time / 1000)
        let lag = isPlaying ? max(0, now.timeIntervalSince(sentAt)) : 0
        let id = p?.uniqueID ?? "\(artist)|\(title)"
        let start = song.metadata?.startTimestamp.map { "@\(Int($0))" } ?? ""

        last = NowPlayingSnapshot(
            state: isPlaying ? "playing" : "paused",
            title: title,
            artist: artist,
            album: q?.album ?? p?.album ?? "",
            duration: p?.duration ?? q?.duration ?? 0,
            position: (p?.currentTime ?? 0) + lag,
            // startTimestamp in the key so a replay counts as a new play.
            persistentID: "web:\(id)\(start)",
            source: .webScrobbler
        )
        lastAt = now
    }

    func snapshot(now: Date) -> NowPlayingSnapshot? {
        guard var snap = last else { return nil }
        let elapsed = now.timeIntervalSince(lastAt)
        guard snap.isPlaying else {
            return elapsed > Self.pausedTimeout ? nil : snap
        }
        let position = snap.position + elapsed
        if snap.duration > 0 {
            if position > snap.duration + Self.playingGrace { return nil }
            snap.position = min(position, snap.duration)
        } else {
            if elapsed > Self.unknownDurationTimeout { return nil }
            snap.position = position
        }
        return snap
    }
}

/// Loopback HTTP endpoint web-scrobbler's Webhook scrobbler posts to. Kept
/// apart from `DebugServer`: that one is an opt-in debug tool, reads no
/// request bodies, and answers every origin.
@MainActor
final class WebScrobblerReceiver {
    static let shared = WebScrobblerReceiver()
    static let path = "/api/webscrobbler"
    static let defaultPort = 8766
    private static let maxRequestBytes = 1 << 20

    private var state = WebScrobblerState()
    private var listener: NWListener?
    private var listeningPort: UInt16 = 0
    private weak var monitor: PlayerMonitor?
    private var settingsSubscription: AnyCancellable?

    var snapshot: NowPlayingSnapshot? { state.snapshot(now: Date()) }

    func attach(monitor: PlayerMonitor) {
        self.monitor = monitor
        if SettingsStore.shared.string(["web_scrobbler", "token"]).isEmpty {
            SettingsStore.shared.merge(["web_scrobbler": ["token": UUID().uuidString]])
        }
        // @Published fires in willSet — hop a runloop so the new values are readable.
        settingsSubscription = SettingsStore.shared.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithSettings() }
    }

    static var port: Int {
        let p = SettingsStore.shared.int(["web_scrobbler", "port"])
        return (1024...65535).contains(p) ? p : defaultPort
    }

    /// What goes into web-scrobbler's "API URL" field.
    static var webhookURL: String {
        "http://127.0.0.1:\(port)\(path)?token=\(SettingsStore.shared.string(["web_scrobbler", "token"]))"
    }

    /// web-scrobbler's one-click flow: its content script on this page asks the
    /// user to accept, then adds the webhook itself.
    static var approvalURL: URL? {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        return URL(string: "https://webscrobbler.com/webhook?applicationName=Musique&userApiUrl=\(enc(webhookURL))")
    }

    private func syncWithSettings() {
        guard SettingsStore.shared.bool(["sources", "web_scrobbler_enabled"]) else {
            stop()
            state = WebScrobblerState()
            return
        }
        let port = UInt16(Self.port)
        if listener == nil || port != listeningPort {
            stop()
            start(port: port)
        }
    }

    private func start(port: UInt16) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: NSLog("[WebScrobbler] listening on 127.0.0.1:\(port)")
                case .failed(let err): NSLog("[WebScrobbler] listener failed: \(err)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.start(queue: .main)
            listener = l
            listeningPort = port
        } catch {
            NSLog("[WebScrobbler] start error: \(error)")
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = 0
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(on: conn, buffer: Data())
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isEOF, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if error != nil || buf.count > Self.maxRequestBytes { conn.cancel(); return }
                if let request = Self.parseRequest(buf) {
                    self.handle(request, on: conn)
                } else if isEOF {
                    conn.cancel()
                } else {
                    self.receive(on: conn, buffer: buf)
                }
            }
        }
    }

    struct Request {
        let method: String
        let target: String
        let body: Data
    }

    /// nil until the headers and the whole `Content-Length` body have arrived.
    nonisolated static func parseRequest(_ buf: Data) -> Request? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        let length = lines.dropFirst().lazy.compactMap { line -> Int? in
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2,
                  kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
            return Int(kv[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = headerEnd.upperBound
        guard buf.endIndex - bodyStart >= length else { return nil }
        return Request(method: requestLine.first.map(String.init) ?? "",
                       target: requestLine.count > 1 ? String(requestLine[1]) : "",
                       body: buf.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func handle(_ request: Request, on conn: NWConnection) {
        let url = URLComponents(string: request.target)
        let token = SettingsStore.shared.string(["web_scrobbler", "token"])

        guard url?.path == Self.path else { return respond(404, on: conn) }
        guard request.method == "POST" else { return respond(405, on: conn) }
        // Any web page can POST to localhost; the token is what keeps them out.
        guard !token.isEmpty, url?.queryItems?.first(where: { $0.name == "token" })?.value == token else {
            return respond(403, on: conn)
        }
        guard let event = try? JSONDecoder().decode(WebScrobblerEvent.self, from: request.body) else {
            return respond(400, on: conn)
        }
        NSLog("[WebScrobbler] \(event.eventName)")
        state.apply(event, now: Date())
        // web-scrobbler treats anything but exactly 200 as a failed call.
        respond(200, on: conn)
        monitor?.refresh()
    }

    private func respond(_ status: Int, on conn: NWConnection) {
        // A stale URL in the extension (old token, wrong path) only ever shows up here.
        if status != 200 { NSLog("[WebScrobbler] rejected request: \(status)") }
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

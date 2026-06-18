import Foundation
import Combine

@MainActor
final class WebhookDispatcher: ObservableObject {
    static let shared = WebhookDispatcher()

    private let settings = SettingsStore.shared
    private weak var monitor: PlayerMonitor?
    private weak var scrobbler: ScrobblerService?
    private var cancellables = Set<AnyCancellable>()

    private var lastTrackKey: String = ""
    private var lastIsPlaying: Bool = false
    private var lastFiredScrobbleKey: String = ""

    private var pausedAt: Date?
    private let pauseThreshold: TimeInterval = 120

    private var heartbeatTimer: Timer?

    func attach(monitor: PlayerMonitor, scrobbler: ScrobblerService) {
        self.monitor = monitor
        self.scrobbler = scrobbler

        monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in self?.handleSnapshot(snap) }
            .store(in: &cancellables)

        scrobbler.$hasScrobbled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scrobbled in
                guard scrobbled else { return }
                self?.handleScrobbleSuccess()
            }
            .store(in: &cancellables)

        startHeartbeat()
    }

    private func enabled() -> Bool {
        settings.bool(["webhook", "enabled"])
    }

    private func urls() -> [String] {
        (settings.value(["webhook", "urls"], [Any].self) ?? [])
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
    }

    private func isPausedTooLong() -> Bool {
        guard let pausedAt else { return false }
        return Date().timeIntervalSince(pausedAt) > pauseThreshold
    }

    private func handleSnapshot(_ snap: NowPlayingSnapshot?) {
        guard enabled() else { return }
        guard let snap, snap.hasTrack else {
            if !lastTrackKey.isEmpty {
                if lastIsPlaying && !isPausedTooLong() {
                    fire(event: "paused", rawSnap: phantomSnap(), editedSnap: nil)
                }
                pausedAt = pausedAt ?? Date()
                lastTrackKey = ""
                lastIsPlaying = false
            }
            return
        }
        let edited = EditHistoryService.shared.apply(snap)
        let key = trackKey(edited)
        let event: String
        if key != lastTrackKey {
            event = snap.isPlaying ? "nowplaying" : "paused"
        } else if snap.isPlaying != lastIsPlaying {
            event = snap.isPlaying ? "nowplaying" : "paused"
        } else {
            return
        }
        lastTrackKey = key
        lastIsPlaying = snap.isPlaying
        if snap.isPlaying {
            pausedAt = nil
        } else {
            if pausedAt == nil { pausedAt = Date() }
            if isPausedTooLong() { return }
        }
        fire(event: event, rawSnap: snap, editedSnap: edited)
    }

    private func handleScrobbleSuccess() {
        guard enabled() else { return }
        guard let snap = monitor?.snapshot, snap.hasTrack else { return }
        let edited = EditHistoryService.shared.apply(snap)
        let key = trackKey(edited)
        guard key != lastFiredScrobbleKey else { return }
        lastFiredScrobbleKey = key
        fire(event: "scrobble", rawSnap: snap, editedSnap: edited)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let interval = max(0, settings.int(["webhook", "heartbeat_seconds"]))
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatFire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func heartbeatFire() {
        guard enabled() else { return }
        guard let snap = monitor?.snapshot, snap.hasTrack else { return }
        guard !isPausedTooLong() else { return }
        let event = snap.isPlaying ? "nowplaying" : "paused"
        let edited = EditHistoryService.shared.apply(snap)
        fire(event: event, rawSnap: snap, editedSnap: edited)
    }

    private func fire(event: String, rawSnap: NowPlayingSnapshot, editedSnap: NowPlayingSnapshot?) {
        let urls = urls()
        guard !urls.isEmpty else { return }
        // A custom artwork chosen from the API carries a public URL; prefer it
        // over the looked-up cover. Local-file picks have no URL → nil.
        let customArtURL = CustomArtworkStore.shared.sourceURL(for: rawSnap)
        Task {
            let result = await ArtworkService.shared.lookup(
                title: rawSnap.title, artist: rawSnap.artist, album: rawSnap.album)
            let payload = buildPayload(event: event, rawSnap: rawSnap, editedSnap: editedSnap,
                                       artwork: result, customArtURL: customArtURL)
            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            for str in urls {
                guard let url = URL(string: str) else { continue }
                await post(url: url, body: body)
            }
        }
    }

    private func post(url: URL, body: Data) async {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            NSLog("[Webhook] error \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    private func buildPayload(event: String, rawSnap: NowPlayingSnapshot, editedSnap: NowPlayingSnapshot?, artwork: ArtworkResult, customArtURL: String? = nil) -> [String: Any] {
        let isPlaying = (event != "paused")
        let duration = Int(rawSnap.duration)
        let position = Int(rawSnap.position)
        // Custom cover from the API overrides the looked-up one. It's a still
        // image, so drop the animation URLs to avoid pairing it with a different
        // track's motion artwork.
        let hasCustom = (customArtURL?.isEmpty == false)
        let trackArtUrl = hasCustom ? customArtURL!
            : (artwork.artworkUltraURL ?? artwork.artworkURL ?? "")
        let animationUrl = hasCustom ? "" : (artwork.animationURL ?? "")
        let masterTallUrl = hasCustom ? "" : (artwork.animationTallURL ?? "")
        let song: [String: Any] = [
            "processed": [
                "artist": editedSnap?.artist ?? rawSnap.artist,
                "track": editedSnap?.title ?? rawSnap.title,
                "album": editedSnap?.album ?? rawSnap.album,
                "duration": duration,
            ],
            "parsed": [
                "artist": rawSnap.artist,
                "track": rawSnap.title,
                "duration": duration,
                "currentTime": position,
                "isPlaying": isPlaying,
            ],
            "flags": ["isValid": true],
            "metadata": [
                "label": "Musique",
                "trackArtUrl": trackArtUrl,
                "animationUrl": animationUrl,
                "masterTallUrl": masterTallUrl,
                "trackUrl": "",
                "albumUrl": "",
                "artistUrl": "",
                "primaryMediaUrl": "",
                "primaryMediaType": "",
            ],
            "connector": ["label": rawSnap.source.displayName],
        ]
        return [
            "eventName": event,
            "time": Int(Date().timeIntervalSince1970 * 1000),
            "data": ["song": song],
        ]
    }

    private func phantomSnap() -> NowPlayingSnapshot {
        NowPlayingSnapshot(state: "paused", title: "", artist: "", album: "",
                           duration: 0, position: 0, persistentID: "")
    }

    private func trackKey(_ snap: NowPlayingSnapshot) -> String {
        if !snap.persistentID.isEmpty { return snap.persistentID }
        return "\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
    }

    func reloadHeartbeat() {
        startHeartbeat()
    }
}

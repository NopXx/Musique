import Foundation
import Combine

@MainActor
final class ScrobblerService: ObservableObject {
    @Published private(set) var hasScrobbled: Bool = false
    @Published private(set) var scrobblePercent: Double = 0

    private let settings = SettingsStore.shared
    private weak var monitor: PlayerMonitor?

    private var cancellable: AnyCancellable?
    private var currentTrackKey: String = ""
    private var currentTrackStart: Date?
    private var lastScrobbledTrackKey: String = ""
    private var didSendNowPlaying: Bool = false

    func attach(monitor: PlayerMonitor) {
        self.monitor = monitor
        cancellable = monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.handle(snapshot: snap)
            }
    }

    private func handle(snapshot: NowPlayingSnapshot?) {
        guard let snap = snapshot, snap.hasTrack else {
            scrobblePercent = 0
            return
        }
        let key = trackKey(snap)
        if key != currentTrackKey {
            currentTrackKey = key
            currentTrackStart = Date()
            hasScrobbled = false
            didSendNowPlaying = false
            if key != lastScrobbledTrackKey { lastScrobbledTrackKey = "" }
        }

        let percent: Double
        if snap.duration > 0 {
            percent = min(100, max(0, snap.position / snap.duration * 100))
        } else { percent = 0 }
        scrobblePercent = percent

        let lastfmReady = credentialsConfigured()
        let sourceAllowed = isSourceEnabled(snap)

        if lastfmReady && sourceAllowed && !didSendNowPlaying && snap.isPlaying {
            didSendNowPlaying = true
            Task { await sendNowPlaying(snap) }
        }

        let threshold = max(1, settings.int(["scrobble", "percent"]))
        let minSeconds = max(1, settings.int(["scrobble", "min_seconds"]))
        if snap.isPlaying
            && !hasScrobbled
            && snap.duration > Double(minSeconds)
            && percent >= Double(threshold)
            && key != lastScrobbledTrackKey {
            hasScrobbled = true
            lastScrobbledTrackKey = key
            let startTs = currentTrackStart ?? Date()
            // The scrobble threshold drives history, notifications and webhooks
            // regardless of Last.fm. Only the Last.fm upload itself is gated.
            if lastfmReady && sourceAllowed {
                Task { await sendScrobble(snap, startTs: startTs) }
            }
        }
    }

    private func trackKey(_ snap: NowPlayingSnapshot) -> String {
        if !snap.persistentID.isEmpty { return snap.persistentID }
        return "\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
    }

    private func isSourceEnabled(_ snap: NowPlayingSnapshot) -> Bool {
        switch snap.source {
        case .appleMusic:
            return settings.value(["scrobble", "scrobble_apple_music"], Bool.self) ?? true
        case .spotify:
            return settings.value(["scrobble", "scrobble_spotify"], Bool.self) ?? true
        }
    }

    private func credentialsConfigured() -> Bool {
        let lf = settings.value(["lastfm"], [String: Any].self) ?? [:]
        let enabled = (lf["enabled"] as? Bool) ?? false
        let key = LastFMSecrets.resolveKey(lf["api_key"] as? String)
        let secret = LastFMSecrets.resolveSecret(lf["api_secret"] as? String)
        let session = (lf["session_key"] as? String) ?? ""
        return enabled && !key.isEmpty && !secret.isEmpty && !session.isEmpty
    }

    private func params(for snap: NowPlayingSnapshot) -> (params: [String: String], secret: String)? {
        let lf = settings.value(["lastfm"], [String: Any].self) ?? [:]
        let key = LastFMSecrets.resolveKey(lf["api_key"] as? String)
        let secret = LastFMSecrets.resolveSecret(lf["api_secret"] as? String)
        let session = (lf["session_key"] as? String) ?? ""
        guard !key.isEmpty, !secret.isEmpty, !session.isEmpty else { return nil }
        let params: [String: String] = [
            "api_key": key,
            "sk": session,
            "track": snap.title,
            "artist": snap.artist,
            "album": snap.album,
            "duration": String(Int(snap.duration)),
        ]
        return (params, secret)
    }

    private func sendNowPlaying(_ snap: NowPlayingSnapshot) async {
        let edited = EditHistoryService.shared.apply(snap)
        guard let (params, secret) = params(for: edited) else { return }
        _ = await LastFMClient.call(method: "track.updateNowPlaying",
                                    params: params, secret: secret, post: true)
    }

    private func sendScrobble(_ snap: NowPlayingSnapshot, startTs: Date) async {
        let edited = EditHistoryService.shared.apply(snap)
        guard var (params, secret) = params(for: edited) else { return }
        params["timestamp"] = String(Int(startTs.timeIntervalSince1970))
        let res = await LastFMClient.call(method: "track.scrobble",
                                          params: params, secret: secret, post: true)
        if res["scrobbles"] == nil {
            NSLog("[Scrobbler] scrobble failed: \(res)")
            await HistoryStore.shared.enqueuePendingScrobble(
                artist: edited.artist, track: edited.title, album: edited.album,
                duration: edited.duration, timestamp: startTs)
        }
    }
}

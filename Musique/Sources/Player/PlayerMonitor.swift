import Foundation
import Combine
import AppKit

@MainActor
final class PlayerMonitor: ObservableObject {
    @Published private(set) var snapshot: NowPlayingSnapshot?

    /// Latest per-source snapshots (only sources that are enabled, running and
    /// not stopped appear here). Drives the mini player's source picker.
    @Published private(set) var sourceSnapshots: [PlaybackSource: NowPlayingSnapshot] = [:]

    /// When the user explicitly picks a source from the mini player, we honour it
    /// as long as that source still has a track. `nil` means automatic selection.
    private(set) var selectedSource: PlaybackSource?

    private let musicBundleID = "com.apple.Music"
    private let spotifyBundleID = "com.spotify.client"
    private var musicApp: MusicApplication?
    private var spotifyApp: SpotifyApplication?

    private var basePosition: Double = 0
    private var basePositionAt: Date = .distantPast
    private var tickTimer: Timer?
    private var musicObserverToken: NSObjectProtocol?
    private var spotifyObserverToken: NSObjectProtocol?

    /// The source that most recently reported a "playing" state. Used to break ties
    /// when both players are active, falling back to the configured priority.
    private var lastActiveSource: PlaybackSource = .appleMusic

    init() {
        if let raw = SBApplication(bundleIdentifier: musicBundleID) {
            self.musicApp = unsafeBitCast(raw, to: MusicApplication.self)
            NSLog("[PlayerMonitor] MusicApplication ready")
        } else {
            NSLog("[PlayerMonitor] SBApplication(com.apple.Music) returned nil")
        }
        if let raw = SBApplication(bundleIdentifier: spotifyBundleID) {
            self.spotifyApp = unsafeBitCast(raw, to: SpotifyApplication.self)
            NSLog("[PlayerMonitor] SpotifyApplication ready")
        } else {
            NSLog("[PlayerMonitor] SBApplication(com.spotify.client) returned nil")
        }
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        musicObserverToken = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            NSLog("[PlayerMonitor] Music notification: \(note.userInfo ?? [:])")
            Task { @MainActor in self?.refresh() }
        }
        spotifyObserverToken = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            NSLog("[PlayerMonitor] Spotify notification: \(note.userInfo ?? [:])")
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        startTickTimer()
    }

    /// Pick a source explicitly from the UI. Pass `nil` to return to automatic
    /// selection. Triggers an immediate refresh.
    func selectSource(_ source: PlaybackSource?) {
        selectedSource = source
        refresh()
    }

    func refresh() {
        let settings = SettingsStore.shared
        let musicSnap = settings.bool(["sources", "apple_music_enabled"]) ? appleMusicSnapshot() : nil
        let spotifySnap = settings.bool(["sources", "spotify_enabled"]) ? spotifySnapshot() : nil

        var snaps: [PlaybackSource: NowPlayingSnapshot] = [:]
        snaps[.appleMusic] = musicSnap
        snaps[.spotify] = spotifySnap
        sourceSnapshots = snaps

        // A manual selection is only valid while that source still has a track.
        if let sel = selectedSource, snaps[sel] == nil {
            selectedSource = nil
        }

        // Track which source is actively playing so we can break ties later.
        if musicSnap?.isPlaying == true { lastActiveSource = .appleMusic }
        else if spotifySnap?.isPlaying == true { lastActiveSource = .spotify }

        let chosen = pickSnapshot(music: musicSnap, spotify: spotifySnap)

        guard let snap = chosen else {
            MusicAppController.activeSource = .appleMusic
            snapshot = nil
            return
        }
        MusicAppController.activeSource = snap.source
        NSLog("[PlayerMonitor] snap source=\(snap.source.rawValue) title=\(snap.title) artist=\(snap.artist) dur=\(snap.duration) pos=\(snap.position)")
        basePosition = snap.position
        basePositionAt = Date()
        snapshot = snap
    }

    /// Choose between two candidate snapshots. A playing source always wins over a
    /// paused one; ties are broken by the configured priority, then last-active.
    private func pickSnapshot(music: NowPlayingSnapshot?, spotify: NowPlayingSnapshot?) -> NowPlayingSnapshot? {
        // An explicit user selection wins while its source still has a track.
        if let sel = selectedSource {
            switch sel {
            case .appleMusic where music != nil: return music
            case .spotify where spotify != nil:  return spotify
            default: break
            }
        }
        switch (music, spotify) {
        case (nil, nil):           return nil
        case (let m?, nil):        return m
        case (nil, let s?):        return s
        case (let m?, let s?):
            if m.isPlaying != s.isPlaying {
                return m.isPlaying ? m : s
            }
            // Both playing or both paused: prefer the last one that started playing,
            // otherwise fall back to the configured priority.
            let priority = PlaybackSource(rawValue: SettingsStore.shared.string(["sources", "priority"])) ?? .appleMusic
            let preferred = (lastActiveSource == .spotify) ? PlaybackSource.spotify : priority
            return preferred == .spotify ? s : m
        }
    }

    private func appleMusicSnapshot() -> NowPlayingSnapshot? {
        guard isAppRunning(musicBundleID), let app = musicApp else { return nil }
        let stateStr: String
        switch app.playerState {
        case MusicEPlSPlaying, MusicEPlSFastForwarding, MusicEPlSRewinding: stateStr = "playing"
        case MusicEPlSPaused: stateStr = "paused"
        default: stateStr = "stopped"
        }
        guard stateStr != "stopped", let track = app.currentTrack else { return nil }
        return NowPlayingSnapshot(
            state: stateStr,
            title: track.name ?? "",
            artist: track.artist ?? "",
            album: track.album ?? "",
            duration: track.duration,
            position: app.playerPosition,
            persistentID: track.persistentID ?? "",
            source: .appleMusic
        )
    }

    private func spotifySnapshot() -> NowPlayingSnapshot? {
        guard isAppRunning(spotifyBundleID), let app = spotifyApp else { return nil }
        let stateStr: String
        switch app.playerState {
        case SpotifyEPlSPlaying: stateStr = "playing"
        case SpotifyEPlSPaused:  stateStr = "paused"
        default: stateStr = "stopped"
        }
        guard stateStr != "stopped", let track = app.currentTrack else { return nil }
        return NowPlayingSnapshot(
            state: stateStr,
            title: track.name ?? "",
            artist: track.artist ?? "",
            album: track.album ?? "",
            duration: Double(track.duration) / 1000.0,  // Spotify reports milliseconds
            position: app.playerPosition,
            persistentID: track.id ?? "",
            source: .spotify
        )
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard var snap = snapshot, snap.isPlaying else { return }
        let elapsed = Date().timeIntervalSince(basePositionAt)
        let newPos = basePosition + elapsed
        if snap.duration > 0 && newPos > snap.duration {
            snap.position = snap.duration
        } else {
            snap.position = newPos
        }
        snapshot = snap
    }

    func rawTrackInfo() -> [String: Any] {
        guard isAppRunning(musicBundleID), let app = musicApp else { return [:] }
        let iso = ISO8601DateFormatter()

        var application: [String: Any] = [:]
        application["name"] = app.name ?? ""
        application["version"] = app.version ?? ""
        application["playerState"] = playerStateString(app.playerState)
        application["playerStateRaw"] = app.playerState.rawValue
        application["playerPosition"] = app.playerPosition
        application["soundVolume"] = app.soundVolume
        application["mute"] = app.mute
        application["shuffleEnabled"] = app.shuffleEnabled
        application["shuffleMode"] = app.shuffleMode.rawValue
        application["songRepeat"] = app.songRepeat.rawValue
        application["EQEnabled"] = app.eqEnabled
        application["AirPlayEnabled"] = app.airPlayEnabled
        application["fullScreen"] = app.fullScreen
        application["frontmost"] = app.frontmost
        application["visualsEnabled"] = app.visualsEnabled
        application["currentStreamTitle"] = app.currentStreamTitle ?? ""
        application["currentStreamURL"] = app.currentStreamURL ?? ""

        if let pl = app.currentPlaylist {
            var playlist: [String: Any] = [:]
            playlist["name"] = pl.name ?? ""
            playlist["description"] = pl.objectDescription ?? ""
            playlist["duration"] = pl.duration
            playlist["favorited"] = pl.favorited
            playlist["disliked"] = pl.disliked
            application["currentPlaylist"] = playlist
        }

        guard let t = app.currentTrack else {
            return ["application": application]
        }

        var track: [String: Any] = [:]
        track["name"] = t.name ?? ""
        track["artist"] = t.artist ?? ""
        track["albumArtist"] = t.albumArtist ?? ""
        track["album"] = t.album ?? ""
        track["sortName"] = t.sortName ?? ""
        track["sortArtist"] = t.sortArtist ?? ""
        track["sortAlbumArtist"] = t.sortAlbumArtist ?? ""
        track["sortAlbum"] = t.sortAlbum ?? ""
        track["sortComposer"] = t.sortComposer ?? ""
        track["sortShow"] = t.sortShow ?? ""
        track["composer"] = t.composer ?? ""
        track["genre"] = t.genre ?? ""
        track["kind"] = t.kind ?? ""
        track["comment"] = t.comment ?? ""
        track["description"] = t.objectDescription ?? ""
        track["longDescription"] = t.longDescription ?? ""
        track["grouping"] = t.grouping ?? ""
        track["category"] = t.category ?? ""
        track["lyrics"] = t.lyrics ?? ""
        track["work"] = t.work ?? ""
        track["movement"] = t.movement ?? ""
        track["movementNumber"] = t.movementNumber
        track["movementCount"] = t.movementCount
        track["show"] = t.show ?? ""
        track["episodeID"] = t.episodeID ?? ""
        track["episodeNumber"] = t.episodeNumber
        track["seasonNumber"] = t.seasonNumber
        track["EQ"] = t.eq ?? ""
        track["persistentID"] = t.persistentID ?? ""
        track["databaseID"] = t.databaseID
        track["duration"] = t.duration
        track["time"] = t.time ?? ""
        track["size"] = t.size
        track["bitRate"] = t.bitRate
        track["sampleRate"] = t.sampleRate
        track["bpm"] = t.bpm
        track["rating"] = t.rating
        track["ratingKind"] = t.ratingKind.rawValue
        track["albumRating"] = t.albumRating
        track["albumRatingKind"] = t.albumRatingKind.rawValue
        track["playedCount"] = t.playedCount
        track["skippedCount"] = t.skippedCount
        track["trackNumber"] = t.trackNumber
        track["trackCount"] = t.trackCount
        track["discNumber"] = t.discNumber
        track["discCount"] = t.discCount
        track["year"] = t.year
        track["start"] = t.start
        track["finish"] = t.finish
        track["bookmark"] = t.bookmark
        track["bookmarkable"] = t.bookmarkable
        track["volumeAdjustment"] = t.volumeAdjustment
        track["favorited"] = t.favorited
        track["disliked"] = t.disliked
        track["albumFavorited"] = t.albumFavorited
        track["albumDisliked"] = t.albumDisliked
        track["compilation"] = t.compilation
        track["gapless"] = t.gapless
        track["enabled"] = t.enabled
        track["unplayed"] = t.unplayed
        track["shufflable"] = t.shufflable
        track["mediaKind"] = t.mediaKind.rawValue
        track["cloudStatus"] = t.cloudStatus.rawValue
        track["downloaderName"] = t.downloaderName ?? ""
        track["downloaderAccount"] = t.downloaderAccount ?? ""
        track["purchaserName"] = t.purchaserName ?? ""
        track["purchaserAccount"] = t.purchaserAccount ?? ""
        track["class"] = String(describing: type(of: t))

        if let date = t.dateAdded { track["dateAdded"] = iso.string(from: date) }
        if let date = t.playedDate { track["playedDate"] = iso.string(from: date) }
        if let date = t.skippedDate { track["skippedDate"] = iso.string(from: date) }
        if let date = t.releaseDate { track["releaseDate"] = iso.string(from: date) }
        if let date = t.modificationDate { track["modificationDate"] = iso.string(from: date) }

        if t.responds(to: NSSelectorFromString("location")),
           let url = t.value(forKey: "location") as? URL {
            track["location"] = url.absoluteString
        }
        if t.responds(to: NSSelectorFromString("address")),
           let addr = t.value(forKey: "address") as? String {
            track["address"] = addr
        }

        var artworks: [[String: Any]] = []
        for case let art as MusicArtwork in t.artworks() {
            var info: [String: Any] = [:]
            info["description"] = art.objectDescription ?? ""
            info["downloaded"] = art.downloaded
            info["kind"] = art.kind
            info["format"] = art.format?.intValue ?? 0
            artworks.append(info)
        }
        track["artworkCount"] = artworks.count
        track["artworks"] = artworks

        return [
            "application": application,
            "track": track,
            "capturedAt": iso.string(from: Date()),
        ]
    }

    private func playerStateString(_ raw: MusicEPlS) -> String {
        switch raw {
        case MusicEPlSPlaying: return "playing"
        case MusicEPlSPaused: return "paused"
        case MusicEPlSStopped: return "stopped"
        case MusicEPlSFastForwarding: return "fast_forwarding"
        case MusicEPlSRewinding: return "rewinding"
        default: return "unknown"
        }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        if let token = musicObserverToken { center.removeObserver(token) }
        if let token = spotifyObserverToken { center.removeObserver(token) }
        tickTimer?.invalidate()
    }
}

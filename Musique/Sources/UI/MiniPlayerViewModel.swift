import SwiftUI
import Combine
import AppKit

@MainActor
final class MiniPlayerViewModel: ObservableObject {
    @Published var snapshot: NowPlayingSnapshot?
    @Published var artwork: ArtworkResult = ArtworkResult()
    @Published var palette: ArtworkPalette = .default
    @Published var hasScrobbled: Bool = false
    @Published var scrobblePercent: Double = 0
    @Published var notificationsEnabled: Bool = true
    @Published var miniplayerAnimation: String = "full"
    @Published var miniplayerMeta: String = "artist_album"
    @Published var artworkStyle: String = "classic"
    @Published var showFullscreenAnimation: Bool = false
    @Published var animationFullscreenEnabled: Bool = false

    /// Snapshot of every tracked source, for the source picker dropdown.
    @Published var sourceSnapshots: [PlaybackSource: NowPlayingSnapshot] = [:]
    @Published var activeSource: PlaybackSource = .appleMusic

    struct SourceItem: Identifiable {
        let source: PlaybackSource
        let snapshot: NowPlayingSnapshot?
        let isActive: Bool
        var id: String { source.rawValue }
        var displayName: String { source.displayName }
        var isRunning: Bool { snapshot != nil }
    }

    /// One row per enabled source, active one first.
    var sourceItems: [SourceItem] {
        let order: [PlaybackSource] = [.appleMusic, .spotify]
        let settings = SettingsStore.shared
        return order.compactMap { src in
            let enabled = src == .appleMusic
                ? settings.bool(["sources", "apple_music_enabled"])
                : settings.bool(["sources", "spotify_enabled"])
            guard enabled else { return nil }
            return SourceItem(source: src,
                              snapshot: sourceSnapshots[src],
                              isActive: src == activeSource)
        }
    }

    func selectSource(_ source: PlaybackSource) {
        monitor?.selectSource(source)
    }

    private weak var monitor: PlayerMonitor?
    private weak var scrobbler: ScrobblerService?
    private var cancellables = Set<AnyCancellable>()
    private var lastArtworkKey: String = ""
    private var lastPaletteURL: String = ""

    init(monitor: PlayerMonitor, scrobbler: ScrobblerService) {
        self.monitor = monitor
        self.scrobbler = scrobbler
        self.notificationsEnabled = SettingsStore.shared.bool(["notifications", "enabled"])
        let anim = SettingsStore.shared.string(["miniplayer", "animation"])
        self.miniplayerAnimation = anim.isEmpty ? "full" : anim
        let meta = SettingsStore.shared.string(["miniplayer", "meta_display"])
        self.miniplayerMeta = meta.isEmpty ? "artist_album" : meta
        let style = SettingsStore.shared.string(["miniplayer", "artwork_style"])
        self.artworkStyle = style.isEmpty ? "classic" : style
        self.animationFullscreenEnabled = SettingsStore.shared.bool(["miniplayer", "animation_fullscreen"])

        SettingsStore.shared.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notificationsEnabled = SettingsStore.shared.bool(["notifications", "enabled"])
                let a = SettingsStore.shared.string(["miniplayer", "animation"])
                self.miniplayerAnimation = a.isEmpty ? "full" : a
                let m = SettingsStore.shared.string(["miniplayer", "meta_display"])
                self.miniplayerMeta = m.isEmpty ? "artist_album" : m
                let st = SettingsStore.shared.string(["miniplayer", "artwork_style"])
                self.artworkStyle = st.isEmpty ? "classic" : st
                self.animationFullscreenEnabled = SettingsStore.shared.bool(["miniplayer", "animation_fullscreen"])
            }
            .store(in: &cancellables)

        monitor.$snapshot
            .combineLatest(EditHistoryService.shared.$rules)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawSnap, _ in
                guard let self else { return }
                let edited = rawSnap.map { EditHistoryService.shared.apply($0) }
                self.snapshot = edited
                self.activeSource = edited?.source ?? .appleMusic
                self.handleTrackUpdate(edited)
            }
            .store(in: &cancellables)

        monitor.$sourceSnapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] raw in
                self?.sourceSnapshots = raw.mapValues { EditHistoryService.shared.apply($0) }
            }
            .store(in: &cancellables)

        scrobbler.$hasScrobbled
            .receive(on: DispatchQueue.main)
            .assign(to: \.hasScrobbled, on: self)
            .store(in: &cancellables)

        scrobbler.$scrobblePercent
            .receive(on: DispatchQueue.main)
            .assign(to: \.scrobblePercent, on: self)
            .store(in: &cancellables)
    }

    private func handleTrackUpdate(_ snap: NowPlayingSnapshot?) {
        guard let snap, snap.hasTrack else {
            artwork = ArtworkResult()
            palette = .default
            lastArtworkKey = ""
            lastPaletteURL = ""
            WidgetDataManager.shared.update(snapshot: nil, artwork: nil, palette: nil)
            return
        }
        // Skip transitional snapshots where Music.app hasn't fully settled
        // (artist briefly empty during a track switch).
        guard !snap.artist.isEmpty else { return }
        let key = "\(snap.persistentID)|\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
        guard key != lastArtworkKey else {
            WidgetDataManager.shared.update(snapshot: snap, artwork: artwork, palette: palette)
            return
        }
        lastArtworkKey = key
        // Do not clear artwork and palette here so the UI smoothly holds the
        // previous artwork until the new one is fetched, avoiding rapid
        // SwiftUI transitions that break NSViewRepresentables.

        // User-chosen artwork wins over the looked-up one. If this track has a
        // custom image, show it and skip the remote lookup entirely.
        if let customURL = CustomArtworkStore.shared.localURL(for: snap) {
            applyCustomArtwork(customURL)
            return
        }

        // Tell the widget immediately that the track changed, with nil artwork.
        // Otherwise it would render the new title/artist with the previous
        // track's artwork until the async lookup below completes.
        WidgetDataManager.shared.update(snapshot: snap, artwork: nil, palette: nil)

        let title = snap.title, artist = snap.artist, album = snap.album
        Task { [weak self] in
            let result = await ArtworkService.shared.lookup(title: title, artist: artist, album: album)
            await MainActor.run {
                guard let self else { return }
                guard self.lastArtworkKey == key else { return }
                self.artwork = result
                WidgetDataManager.shared.update(
                    snapshot: self.snapshot,
                    artwork: result,
                    palette: self.palette
                )
                if let url = result.artworkURL, !url.isEmpty, url != self.lastPaletteURL {
                    self.lastPaletteURL = url
                    Task { [weak self] in
                        let palette = await ColorExtractor.shared.palette(for: url)
                        await MainActor.run {
                            guard let self, self.lastPaletteURL == url else { return }
                            self.palette = palette
                            WidgetDataManager.shared.update(
                                snapshot: self.snapshot,
                                artwork: self.artwork,
                                palette: palette
                            )
                        }
                    }
                }
            }
        }
    }

    /// Show a custom image (a local file URL) as the current artwork and derive
    /// its palette. Carries the stored motion-artwork URLs so a chosen animated
    /// cover keeps playing; nil for a still local file.
    private func applyCustomArtwork(_ url: URL) {
        let urlStr = url.absoluteString
        let anim: (square: String?, tall: String?) =
            snapshot.map { CustomArtworkStore.shared.animationURLs(for: $0) } ?? (nil, nil)
        let result = ArtworkResult(artworkURL: urlStr,
                                   animationURL: anim.square,
                                   animationTallURL: anim.tall)
        artwork = result
        WidgetDataManager.shared.update(snapshot: snapshot, artwork: result, palette: palette)
        guard urlStr != lastPaletteURL else { return }
        lastPaletteURL = urlStr
        Task { [weak self] in
            let palette = await ColorExtractor.shared.palette(for: urlStr)
            await MainActor.run {
                guard let self, self.lastPaletteURL == urlStr else { return }
                self.palette = palette
                WidgetDataManager.shared.update(
                    snapshot: self.snapshot,
                    artwork: self.artwork,
                    palette: palette
                )
            }
        }
    }

    // MARK: - Custom artwork (mini player override)

    /// Whether the current track has a user-chosen artwork image.
    var hasCustomArtwork: Bool {
        guard let snap = snapshot else { return false }
        return CustomArtworkStore.shared.hasCustom(for: snap)
    }

    /// The current track's custom image, for previewing in the edit popover.
    func currentCustomArtwork() -> NSImage? {
        guard let snap = snapshot, let url = CustomArtworkStore.shared.localURL(for: snap) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Store `image` as the artwork for the current track and refresh the UI.
    func setCustomArtwork(_ image: NSImage) {
        guard let snap = snapshot else { return }
        setCustomArtwork(image, for: snap)
    }

    /// Store `image` for a specific track. Used by the artwork picker window,
    /// which captures the target track when it opens so the choice lands on the
    /// right song even if playback has since advanced. `sourceURL` is the public
    /// artwork URL when picked from the API (nil for a local file).
    func setCustomArtwork(_ image: NSImage, for snap: NowPlayingSnapshot, sourceURL: String? = nil,
                          animationURL: String? = nil, animationTallURL: String? = nil) {
        CustomArtworkStore.shared.save(image: image, for: snap, sourceURL: sourceURL,
                                       animationURL: animationURL, animationTallURL: animationTallURL)
        if let cur = snapshot,
           CustomArtworkStore.key(for: cur) == CustomArtworkStore.key(for: snap) {
            refreshArtworkForCurrentTrack()
        }
    }

    /// Drop the custom artwork for the current track and fall back to lookup.
    func removeCustomArtwork() {
        guard let snap = snapshot else { return }
        CustomArtworkStore.shared.remove(for: snap)
        refreshArtworkForCurrentTrack()
    }

    /// Force artwork re-resolution for the current track (custom or looked-up).
    private func refreshArtworkForCurrentTrack() {
        lastArtworkKey = ""
        lastPaletteURL = ""
        handleTrackUpdate(snapshot)
    }

    func playPause() {
        MusicAppController.playPause()
        monitor?.refresh()
    }

    func next() {
        MusicAppController.next()
        scheduleFallbackRefresh()
    }

    func previous() {
        MusicAppController.previous()
        scheduleFallbackRefresh()
    }

    /// Music.app posts `com.apple.Music.playerInfo` after the track actually
    /// advances; PlayerMonitor observes that and refreshes itself. We schedule
    /// a delayed refresh purely as a safety net in case the notification is
    /// missed, well after Music.app has had time to switch tracks.
    private func scheduleFallbackRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.monitor?.refresh()
        }
    }

    /// Save an edit rule for the currently playing track. Match keys use the
    /// raw snapshot from the monitor (before `apply()`), so editing is
    /// idempotent even if a rule already transforms this track.
    func saveEditForCurrentTrack(artist: String, track: String, album: String) {
        guard let raw = monitor?.snapshot, raw.hasTrack else { return }
        let trimArtist = artist.trimmingCharacters(in: .whitespaces)
        let trimTrack  = track.trimmingCharacters(in: .whitespaces)
        let trimAlbum  = album.trimmingCharacters(in: .whitespaces)
        Task {
            await EditHistoryService.shared.add(
                artistMatch: raw.artist,
                trackMatch: raw.title,
                albumMatch: "",
                artistTo: trimArtist == raw.artist ? "" : trimArtist,
                trackTo:  trimTrack  == raw.title  ? "" : trimTrack,
                albumTo:  trimAlbum  == raw.album  ? "" : trimAlbum
            )
        }
    }

    func toggleNotifications() {
        let target = !notificationsEnabled
        if target {
            Task { @MainActor in
                let granted = await NotificationService.shared.ensureAuthorized()
                guard granted else {
                    notificationsEnabled = false
                    SettingsStore.shared.merge(["notifications": ["enabled": false]])
                    return
                }
                notificationsEnabled = true
                SettingsStore.shared.merge(["notifications": ["enabled": true]])
            }
        } else {
            notificationsEnabled = false
            SettingsStore.shared.merge(["notifications": ["enabled": false]])
        }
    }
}

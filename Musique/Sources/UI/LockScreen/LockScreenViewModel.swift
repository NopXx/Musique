import SwiftUI
import Combine
import AppKit

@MainActor
final class LockScreenViewModel: ObservableObject {
    @Published var snapshot: NowPlayingSnapshot?
    @Published var artwork: ArtworkResult = ArtworkResult()
    @Published var artworkImage: NSImage?
    @Published var palette: ArtworkPalette = .default
    @Published var isLargeArtwork: Bool = false
    @Published var fullscreenAnimationActive: Bool = false

    @Published var showAlbum: Bool = true
    @Published var showProgress: Bool = true
    @Published var animatedArtwork: Bool = true
    @Published var backgroundBlur: Int = 60
    @Published var padding: Int = 32
    @Published var setSystemWallpaper: Bool = false
    @Published var clock: Bool = true
    @Published var clockFormat: String = "system"
    @Published var clockDateStyle: String = "full"

    /// True while loginwindow's password panel is on screen. The fullscreen
    /// artwork covers it completely, so it fades for as long as the panel is up.
    /// Driven by `LockScreenController`.
    @Published var lockUIVisible: Bool = false

    /// True only once the blurred artwork is *actually* the desktop picture.
    /// `setDesktopImageURL` returns immediately but WallpaperAgent repaints
    /// seconds later; until then the overlay shows its own copy so the swap
    /// doesn't look stuck on the old wallpaper.
    @Published var staticWallpaperLive: Bool = false

    /// True only once the motion wallpaper is *actually* playing on the real
    /// desktop. The overlay stops drawing its own video copy then; while this is
    /// false — activation still running, or it failed — the copy keeps the artwork
    /// on screen instead of leaving the lock screen bare.
    @Published var motionWallpaperLive: Bool = false

    private weak var monitor: PlayerMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var lastArtworkKey: String = ""
    private var lastPaletteURL: String = ""

    init(monitor: PlayerMonitor) {
        self.monitor = monitor
        readSettings()

        SettingsStore.shared.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.readSettings() }
            .store(in: &cancellables)

        monitor.$snapshot
            .combineLatest(EditHistoryService.shared.$rules)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawSnap, _ in
                guard let self else { return }
                let edited = rawSnap.map { EditHistoryService.shared.apply($0) }
                self.snapshot = edited
                self.handleTrackUpdate(edited)
            }
            .store(in: &cancellables)

        // Artwork the user picked in the mini player wins here too — otherwise
        // the lock screen shows the looked-up cover while every other surface
        // shows theirs. Re-resolve on change: the same track keeps its key, so
        // `handleTrackUpdate` would otherwise skip the work.
        NotificationCenter.default
            .publisher(for: CustomArtworkStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                lastArtworkKey = ""
                handleTrackUpdate(snapshot)
            }
            .store(in: &cancellables)
    }

    private func readSettings() {
        let s = SettingsStore.shared
        showAlbum = s.bool(["lockscreen", "show_album"])
        showProgress = s.bool(["lockscreen", "show_progress"])
        animatedArtwork = s.bool(["lockscreen", "animated_artwork"])
        let blur = s.int(["lockscreen", "background_blur"])
        backgroundBlur = blur > 0 ? blur : 60
        let pad = s.int(["lockscreen", "padding"])
        padding = pad > 0 ? pad : 32
        setSystemWallpaper = s.bool(["lockscreen", "set_system_wallpaper"])
        // `load()` deep-merges the defaults in, so a settings.json predating these
        // keys still reads their defaults — no `?? true` fallback needed.
        clock = s.bool(["lockscreen", "clock"])
        let format = s.string(["lockscreen", "clock_format"])
        clockFormat = format.isEmpty ? "system" : format
        let dateStyle = s.string(["lockscreen", "clock_date_style"])
        clockDateStyle = dateStyle.isEmpty ? "full" : dateStyle
    }

    private func handleTrackUpdate(_ snap: NowPlayingSnapshot?) {
        guard let snap, snap.hasTrack else {
            artwork = ArtworkResult()
            artworkImage = nil
            palette = .default
            lastArtworkKey = ""
            lastPaletteURL = ""
            return
        }
        // Skip transitional snapshots from Music.app where ScriptingBridge
        // returns partial state during a track switch.
        guard !snap.artist.isEmpty else { return }
        let key = "\(snap.persistentID)|\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key

        // A cover the user chose for this track wins over the looked-up one, the
        // same way it does in the mini player, the menu bar and the widget.
        if let customURL = CustomArtworkStore.shared.localURL(for: snap) {
            applyCustomArtwork(customURL, for: snap)
            return
        }

        let title = snap.title, artist = snap.artist, album = snap.album
        Task { [weak self] in
            let result = await ArtworkService.shared.lookup(title: title, artist: artist, album: album)
            let imgURLString = result.artworkUltraURL ?? result.artworkURL
            var downloadedImage: NSImage?
            if let imgURLString, let imgURL = URL(string: imgURLString) {
                if let (data, _) = try? await URLSession.shared.data(from: imgURL) {
                    downloadedImage = NSImage(data: data)
                }
            }
            await MainActor.run {
                guard let self, self.lastArtworkKey == key else { return }
                self.artwork = result
                self.artworkImage = downloadedImage
                if let url = result.artworkURL, !url.isEmpty, url != self.lastPaletteURL {
                    self.lastPaletteURL = url
                    Task { [weak self] in
                        let palette = await ColorExtractor.shared.palette(for: url)
                        await MainActor.run {
                            guard let self, self.lastPaletteURL == url else { return }
                            self.palette = palette
                        }
                    }
                }
            }
        }
    }

    /// Show a user-chosen image (a local file) as the artwork, carrying the
    /// motion-artwork URLs stored alongside it so a chosen animated cover still
    /// plays — on the lock screen *and* as the video wallpaper.
    private func applyCustomArtwork(_ url: URL, for snap: NowPlayingSnapshot) {
        let urlStr = url.absoluteString
        let anim = CustomArtworkStore.shared.animationURLs(for: snap)
        artwork = ArtworkResult(artworkURL: urlStr,
                                animationURL: anim.square,
                                animationTallURL: anim.tall)
        artworkImage = NSImage(contentsOf: url)
        guard urlStr != lastPaletteURL else { return }
        lastPaletteURL = urlStr
        Task { [weak self] in
            let palette = await ColorExtractor.shared.palette(for: urlStr)
            await MainActor.run {
                guard let self, self.lastPaletteURL == urlStr else { return }
                self.palette = palette
            }
        }
    }
}

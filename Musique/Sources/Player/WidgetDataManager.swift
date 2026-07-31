import Foundation
import WidgetKit
import AppKit
import AVFoundation
import Combine

/// Team-ID-prefixed on purpose: macOS only resolves an app-group container for a
/// *non-sandboxed* process (this app) when the identifier starts with the team id.
/// With the plain `group.` form the host's every write fell back to a temp dir the
/// sandboxed widget and wallpaper extension can't read.
let appGroupID = "H4M5HWBU2K.group.com.nopxx.musique"

struct NowPlayingWidgetData: Codable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var hasTrack: Bool
    var artworkPath: String?
    var accentR: Double
    var accentG: Double
    var accentB: Double
    var gradientStartR: Double
    var gradientStartG: Double
    var gradientStartB: Double
    var gradientMidR: Double
    var gradientMidG: Double
    var gradientMidB: Double
    var gradientEndR: Double
    var gradientEndG: Double
    var gradientEndB: Double
    var timestamp: Date
}

// MARK: - Shared file path (used by both main app and widget)

/// Where widget data lives. Normally the app group container; falls back to a
/// temp dir when that container exists but isn't writable — a test host has no
/// app-group entitlement, so every write there fails with EPERM and would spam
/// the log once per track change. Resolved once per process (global `let` is
/// lazy and thread-safe).
private let widgetContainerURL: URL = {
    let fm = FileManager.default
    if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
       (try? fm.createDirectory(at: container, withIntermediateDirectories: true)) != nil,
       fm.isWritableFile(atPath: container.path) {
        return container
    }
    let fallback = fm.temporaryDirectory.appendingPathComponent("musique_widget", isDirectory: true)
    try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
    NSLog("[WidgetDataManager] app group container unavailable — using \(fallback.path)")
    return fallback
}()

func widgetDataFileURL() -> URL {
    widgetContainerURL.appendingPathComponent("nowPlaying.json")
}

func widgetArtworkDirURL() -> URL {
    let dir = widgetContainerURL.appendingPathComponent("artwork", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Main app side: write data

@MainActor
final class WidgetDataManager {
    static let shared = WidgetDataManager()

    private let fileManager = FileManager.default
    private let artworkDir: URL

    private var lastArtworkKey: String = ""
    private var cachedArtworkPath: String? = nil
    private var lastFlushKey: String = ""
    private var cachedPalette: ArtworkPalette? = nil
    private var lastReloadSignature: String = ""
    private var lastSnapshot: NowPlayingSnapshot? = nil
    private var settingsCancellable: AnyCancellable?

    private init() {
        artworkDir = widgetArtworkDirURL()
    }

    func update(snapshot: NowPlayingSnapshot?, artwork: ArtworkResult?, palette: ArtworkPalette?) {
        guard let snap = snapshot, snap.hasTrack else {
            clearWidget()
            return
        }

        let trackKey = snap.persistentID.isEmpty
            ? "\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
            : snap.persistentID

        let artworkPath = resolveArtworkPath(artwork: artwork, key: trackKey)
        if let palette { cachedPalette = palette }
        let pal = cachedPalette ?? palette ?? .default
        lastSnapshot = snap

        writeAndReload(snap: snap, artworkPath: artworkPath, palette: pal)

        if let artwork, let urlString = artwork.artworkURL, !urlString.isEmpty,
           trackKey != lastArtworkKey {
            downloadArtworkAsync(urlString: urlString, key: trackKey, snap: snap, palette: pal)
        }
    }

    // MARK: - Private

    private func clearWidget() {
        let signature = "EMPTY"
        guard signature != lastReloadSignature else { return }

        let url = widgetDataFileURL()
        let data = NowPlayingWidgetData(
            title: "", artist: "", album: "", duration: 0, position: 0,
            isPlaying: false, hasTrack: false, artworkPath: nil,
            accentR: 0, accentG: 0, accentB: 0,
            gradientStartR: 0, gradientStartG: 0, gradientStartB: 0,
            gradientMidR: 0, gradientMidG: 0, gradientMidB: 0,
            gradientEndR: 0, gradientEndG: 0, gradientEndB: 0,
            timestamp: Date()
        )
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: url, options: .atomic)
        } catch {
            NSLog("[WidgetDataManager] clear write error: \(error)")
        }
        WidgetCenter.shared.reloadAllTimelines()
        lastFlushKey = ""
        lastArtworkKey = ""
        cachedArtworkPath = nil
        cachedPalette = nil
        lastReloadSignature = signature
        lastSnapshot = nil
    }

    private func writeAndReload(snap: NowPlayingSnapshot, artworkPath: String?, palette: ArtworkPalette?) {
        let trackKey = snap.persistentID.isEmpty
            ? "\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
            : snap.persistentID

        let pal = palette ?? cachedPalette ?? .default

        let data = NowPlayingWidgetData(
            title: snap.title,
            artist: snap.artist,
            album: snap.album,
            duration: snap.duration,
            position: snap.position,
            isPlaying: snap.isPlaying,
            hasTrack: true,
            artworkPath: artworkPath ?? cachedArtworkPath,
            accentR: Double(pal.accent.redComponent),
            accentG: Double(pal.accent.greenComponent),
            accentB: Double(pal.accent.blueComponent),
            gradientStartR: Double(pal.gradientStart.redComponent),
            gradientStartG: Double(pal.gradientStart.greenComponent),
            gradientStartB: Double(pal.gradientStart.blueComponent),
            gradientMidR: Double(pal.gradientMid.redComponent),
            gradientMidG: Double(pal.gradientMid.greenComponent),
            gradientMidB: Double(pal.gradientMid.blueComponent),
            gradientEndR: Double(pal.gradientEnd.redComponent),
            gradientEndG: Double(pal.gradientEnd.greenComponent),
            gradientEndB: Double(pal.gradientEnd.blueComponent),
            timestamp: Date()
        )

        // Always write the latest snapshot so the file stays fresh for the
        // widget's own 60-second timeline regeneration (catches seeks etc).
        do {
            let encoded = try JSONEncoder().encode(data)
            let url = widgetDataFileURL()
            try encoded.write(to: url, options: .atomic)
        } catch {
            NSLog("[WidgetDataManager] write error: \(error)")
        }
        lastFlushKey = trackKey

        // Force-reload the timeline only when something the widget can't
        // extrapolate on its own changes (track, play-state, artwork, palette,
        // animation availability, large-artwork style).
        let resolvedArtwork = artworkPath ?? cachedArtworkPath ?? ""
        let signature = [
            trackKey,
            snap.isPlaying ? "1" : "0",
            resolvedArtwork,
            String(format: "%.3f,%.3f,%.3f", pal.accent.redComponent, pal.accent.greenComponent, pal.accent.blueComponent),
        ].joined(separator: "|")

        guard signature != lastReloadSignature else { return }
        lastReloadSignature = signature
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func resolveArtworkPath(artwork: ArtworkResult?, key: String) -> String? {
        if let artwork, let urlString = artwork.artworkURL, !urlString.isEmpty {
            let filename = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
            let dest = artworkDir.appendingPathComponent("\(filename).png")
            if fileManager.fileExists(atPath: dest.path) {
                cachedArtworkPath = dest.path
                lastArtworkKey = key
                return dest.path
            }
        }
        return cachedArtworkPath
    }

    private func downloadArtworkAsync(urlString: String, key: String, snap: NowPlayingSnapshot, palette: ArtworkPalette) {
        guard let url = URL(string: urlString) else { return }
        lastArtworkKey = key

        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let filename = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
                let dest = self?.artworkDir.appendingPathComponent("\(filename).png")
                if let dest {
                    try data.write(to: dest, options: .atomic)
                    await MainActor.run {
                        guard let self else { return }
                        self.cachedArtworkPath = dest.path
                        self.writeAndReload(snap: snap, artworkPath: dest.path, palette: palette)
                    }
                }
            } catch {
                NSLog("[WidgetDataManager] artwork download error: \(error.localizedDescription)")
            }
        }
    }
}
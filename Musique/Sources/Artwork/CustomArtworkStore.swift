import Foundation
import AppKit
import CryptoKit

/// Persists user-chosen artwork images keyed by track identity. When a track
/// that has a stored image plays, the mini player shows the custom image
/// instead of the looked-up artwork.
///
/// Files live in `~/Library/Application Support/Musique/CustomArtwork/`. An
/// `index.json` maps a stable track key to its current filename. Each save
/// writes a *new* uniquely named file (and deletes the previous one) so that
/// SwiftUI `AsyncImage` / `ColorExtractor`, which cache by URL, pick up the
/// replacement instead of showing the stale image.
///
/// All access is expected on the main thread (the mini player view model and
/// the edit popover are both `@MainActor`).
@MainActor
final class CustomArtworkStore {
    static let shared = CustomArtworkStore()

    /// Posted after a track's custom artwork is set or removed, so views that
    /// resolve artwork independently (e.g. the menu bar) can refresh.
    static let didChangeNotification = Notification.Name("musique.customArtworkChanged")

    /// One stored entry: the on-disk filename plus, when the image came from the
    /// artwork API, its public source URL (so the webhook can reference it).
    private struct Entry: Codable {
        let file: String
        var sourceURL: String?
    }

    private let fm = FileManager.default
    private let dir: URL
    private let indexURL: URL
    private var index: [String: Entry]

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dir = base.appendingPathComponent("Musique/CustomArtwork", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("index.json")
        index = Self.loadIndex(from: indexURL)
    }

    private static func loadIndex(from url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        // Current format: key -> Entry.
        if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            return decoded
        }
        // Legacy format: key -> filename string.
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            return legacy.mapValues { Entry(file: $0, sourceURL: nil) }
        }
        return [:]
    }

    /// Stable key for a track. Prefers `persistentID` (survives metadata edits
    /// from `EditHistoryService`); falls back to artist|title|album.
    static func key(for snap: NowPlayingSnapshot) -> String {
        let pid = snap.persistentID.trimmingCharacters(in: .whitespaces)
        if !pid.isEmpty { return "id:\(pid)" }
        return "meta:\(snap.artist)|\(snap.title)|\(snap.album)".lowercased()
    }

    /// Local file URL of the stored image for this track, or nil if none.
    func localURL(for snap: NowPlayingSnapshot) -> URL? {
        guard let entry = index[Self.key(for: snap)] else { return nil }
        let url = dir.appendingPathComponent(entry.file)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func hasCustom(for snap: NowPlayingSnapshot) -> Bool {
        localURL(for: snap) != nil
    }

    /// Public source URL of the custom artwork, when it was chosen from the API
    /// (nil if picked from a local file). Used by the webhook payload.
    func sourceURL(for snap: NowPlayingSnapshot) -> String? {
        guard localURL(for: snap) != nil else { return nil }
        return index[Self.key(for: snap)]?.sourceURL
    }

    /// Store a PNG-encoded copy of `image` for this track. `sourceURL` is the
    /// public URL when the image came from the artwork API, else nil. Returns
    /// the file URL.
    @discardableResult
    func save(image: NSImage, for snap: NowPlayingSnapshot, sourceURL: String? = nil) -> URL? {
        guard let png = image.pngData() else { return nil }
        let key = Self.key(for: snap)
        let keyHash = Self.shortHash(key)
        // Content hash makes the filename change whenever the image changes,
        // busting URL-keyed caches downstream.
        let contentHash = Self.shortHash(png)
        let name = "\(keyHash)_\(contentHash).png"
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            if let old = index[key]?.file, old != name {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
            }
            index[key] = Entry(file: name, sourceURL: sourceURL)
            persistIndex()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: key)
            return url
        } catch {
            NSLog("[CustomArtwork] save failed: \(error)")
            return nil
        }
    }

    func remove(for snap: NowPlayingSnapshot) {
        let key = Self.key(for: snap)
        if let entry = index[key] {
            try? fm.removeItem(at: dir.appendingPathComponent(entry.file))
            index[key] = nil
            persistIndex()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: key)
        }
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func shortHash(_ string: String) -> String {
        shortHash(Data(string.utf8))
    }

    private static func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension NSImage {
    /// PNG-encoded representation, or nil if the image has no bitmap backing.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

import Foundation

/// Where the host app stages motion-artwork videos for us to play: the shared
/// app-group container, one flat directory of `<contentID>.mov`. Both sides reach
/// it by entitlement alone — no user grant to lose. The group id is team-ID
/// prefixed because the host is *not* sandboxed and macOS resolves a container for
/// such a process only in that form. Must match `MotionWallpaperStore.videosDir`.
enum WallpaperPaths {
    static var videosDir: URL? {
        AppGroup.containerURL?.appendingPathComponent("videos", isDirectory: true)
    }

    /// Names the clip the host most recently staged. Must match
    /// `MotionWallpaperStore.pointerFileName`.
    private static let pointerFileName = "current"

    /// The clip that is current. The host stages every track under its own name
    /// and records it here, so each swap is a *distinct* URL — the old scheme
    /// overwrote one fixed path and relied on AVURLAsset noticing the replaced
    /// inode, which AVFoundation doesn't promise.
    static func currentVideoURL() -> URL? {
        guard let dir = videosDir,
              let name = try? String(contentsOf: dir.appendingPathComponent(pointerFileName), encoding: .utf8)
        else { return nil }
        let url = dir.appendingPathComponent(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

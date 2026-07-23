import Foundation

/// Where the host app stages motion-artwork videos for us to play. The host (not
/// sandboxed) writes into *this extension's* container Documents; we (sandboxed)
/// read our own container freely. One flat directory of `<choiceID>.mov`.
/// (The app group can't be used: a non-sandboxed host is denied write access to
/// the group container even with the entitlement.)
enum WallpaperPaths {
    static var videosDir: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("videos", isDirectory: true)
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

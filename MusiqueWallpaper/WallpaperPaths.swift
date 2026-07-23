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

    /// Resolve a choice id (the `Configuration` blob macOS hands back in the
    /// creation request) to its staged `.mov`, if present.
    static func videoURL(forChoice choiceID: String?) -> URL? {
        guard let choiceID, !choiceID.isEmpty, let dir = videosDir else { return nil }
        let url = dir.appendingPathComponent(choiceID).appendingPathExtension("mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

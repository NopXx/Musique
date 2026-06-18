import Foundation
import CryptoKit

final class AnimatedArtworkCache {
    static let shared = AnimatedArtworkCache()

    private let fm = FileManager.default
    private let dir: URL
    private let queue = DispatchQueue(label: "musique.animated-artwork-cache", qos: .utility)
    private var inflight: Set<String> = []

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dir = base.appendingPathComponent("Musique/Videos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func localURLIfCached(for remote: URL) -> URL? {
        let path = filePath(for: remote)
        return fm.fileExists(atPath: path.path) ? path : nil
    }

    /// Returns local URL synchronously if cached; otherwise schedules a background download
    /// and invokes `completion` on the main queue once the file is on disk.
    func resolve(remote: URL, completion: @escaping (URL) -> Void) {
        let local = filePath(for: remote)
        if fm.fileExists(atPath: local.path) {
            completion(local)
            return
        }
        let key = local.lastPathComponent
        queue.async { [weak self] in
            guard let self else { return }
            if self.inflight.contains(key) { return }
            self.inflight.insert(key)
            URLSession.shared.downloadTask(with: remote) { tmp, _, err in
                defer { self.queue.async { self.inflight.remove(key) } }
                guard let tmp, err == nil else { return }
                do {
                    if self.fm.fileExists(atPath: local.path) {
                        try self.fm.removeItem(at: local)
                    }
                    try self.fm.moveItem(at: tmp, to: local)
                    DispatchQueue.main.async { completion(local) }
                } catch {
                    NSLog("[AnimatedArtworkCache] move failed: \(error)")
                }
            }.resume()
        }
    }

    private func filePath(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = remote.pathExtension.isEmpty ? "mov" : remote.pathExtension
        return dir.appendingPathComponent("lockscreen_\(hex).\(ext)")
    }
}

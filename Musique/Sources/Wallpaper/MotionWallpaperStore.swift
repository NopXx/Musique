import CryptoKit
import Foundation
import os

private let storeLog = Logger(subsystem: "com.nopxx.musique", category: "MotionWallpaper")

/// Host-app side of the motion-wallpaper feature: stages a video where the
/// sandboxed wallpaper extension can read it, then activates it as the system
/// wallpaper by rewriting macOS's wallpaper store and reloading WallpaperAgent —
/// the same end state as picking it in System Settings → Wallpaper.
///
/// This edits `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`
/// directly and runs `killall WallpaperAgent`. It replaces the *real* desktop
/// wallpaper (the lock screen follows the desktop). `deactivate()` restores the
/// wallpaper state captured the first time we activated.
enum MotionWallpaperStore {
    static let extensionBundleID = "com.nopxx.musique.wallpaper"

    /// One stable choice/file the wallpaper store points at for the whole session.
    /// Track changes overwrite this file's bytes rather than minting a new choice,
    /// so WallpaperAgent keeps hosting the same surface (no reload flash per song).
    static let stableChoiceID = "musique-motion"
    private static let stableFileName = "musique-motion.mov"

    /// Darwin notification the extension listens for; posted after the staged file
    /// is overwritten so it swaps clips on the live surface. Must match the name in
    /// `MusiqueWallpaperExtension`.
    static let switchNotification = "com.nopxx.musique.wallpaper.switch"

    // MARK: Staging

    /// The wallpaper extension's own sandbox container Documents dir. The host is
    /// not sandboxed, so it writes here directly (macOS may prompt once to allow
    /// access to another app's data). The extension reads its own Documents. The
    /// app group can't be used — a non-sandboxed host is denied write access to the
    /// group container even with the entitlement.
    private static var videosDir: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionBundleID)/Data/Documents/videos", isDirectory: true)
    }

    /// Content id for a source file = hash of its path, used only to dedup "same
    /// track, don't restage". The staged file itself always lives at a fixed path.
    static func contentID(for sourceURL: URL) -> String {
        let digest = SHA256.hash(data: Data(sourceURL.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// Overwrite the single staged clip with `sourceURL`, atomically so the
    /// extension's open reader keeps the old inode until it swaps. Returns the
    /// content id (for dedup) and the fixed staged URL, or nil on failure.
    @discardableResult
    static func stage(localVideo sourceURL: URL) -> (contentID: String, url: URL)? {
        guard let dir = videosDir else {
            storeLog.error("stage: videosDir nil (ext container path unresolved)")
            return nil
        }
        let id = contentID(for: sourceURL)
        let dest = dir.appendingPathComponent(stableFileName)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                let tmp = dir.appendingPathComponent(stableFileName + ".tmp")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: sourceURL, to: tmp)
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)   // atomic swap
            } else {
                try fm.copyItem(at: sourceURL, to: dest)
            }
            return (id, dest)
        } catch {
            storeLog.error("stage: \(error.localizedDescription, privacy: .public) src=\(sourceURL.path, privacy: .public) dest=\(dest.path, privacy: .public)")
            return nil
        }
    }

    /// Tell the extension the staged clip's bytes changed so it swaps on the live
    /// surface (no plist rewrite, no WallpaperAgent reload).
    static func announceSwitch() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(switchNotification as CFString),
            nil, nil, true)
    }

    // MARK: Wallpaper store

    private static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Backup of the user's Desktop wallpapers, kept in the host's own Application
    /// Support (always writable — no container-permission issues). Stored as
    /// `path → Desktop.Content`, *not* a copy of the whole store: restoring merges
    /// back into the live store, so a Space/Display macOS added while we were
    /// active can't be dropped by writing a stale snapshot over it.
    private static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Musique/wallpaper-desktops.backup.plist")
    }

    /// Whole-store backup written by earlier builds; deleted on sight so it can
    /// never be mistaken for current state.
    private static var legacyBackupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Musique/wallpaper-index.backup.plist")
    }

    /// Point every Desktop node at our extension's choice, then reload the agent.
    /// Backs up the original store once (on first activation) so `deactivate()`
    /// can restore it.
    /// Returns false if the store could not be read or written — the caller must
    /// not record itself as active in that case, or `deactivate()` will later
    /// "restore" a wallpaper we never replaced.
    @discardableResult
    static func activate(choiceID: String, videoURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: storeURL),
              var root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            storeLog.error("activate: wallpaper store unreadable at \(storeURL.path, privacy: .public)")
            return false
        }

        // Never replace the user's wallpaper unless we can put it back.
        guard backupOnce(root) else { return false }
        root = rewriteDesktop(in: root, choiceID: choiceID, videoURL: videoURL)

        guard let out = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else {
            storeLog.error("activate: could not serialise rewritten store")
            return false
        }
        do {
            try out.write(to: storeURL, options: .atomic)
        } catch {
            storeLog.error("activate: store write failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
        reloadWallpaperAgent()
        return true
    }

    /// Restore the user's wallpaper. Always works from the *live* store — every
    /// Desktop node still pointing at our extension gets its original `Content`
    /// back from the backup, and any node the backup doesn't cover (a Space or
    /// display macOS added while we were active, or a mixed state from a crash)
    /// falls back to its sibling Idle content. Nothing else in the store is
    /// touched, so nodes that appeared after activation survive.
    static func deactivate() {
        guard let data = try? Data(contentsOf: storeURL),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            storeLog.error("deactivate: wallpaper store unreadable — reloading agent only")
            discardBackups()
            reloadWallpaperAgent()
            return
        }

        var saved: [String: Any] = [:]
        if let backup = try? Data(contentsOf: backupURL),
           let map = (try? PropertyListSerialization.propertyList(from: backup, format: nil)) as? [String: Any] {
            saved = map
        } else {
            storeLog.info("deactivate: no backup — restoring every stuck Desktop from its Idle sibling")
        }

        let restored = restoreDesktops(in: root, saved: saved)
        if let out = try? PropertyListSerialization.data(fromPropertyList: restored, format: .binary, options: 0) {
            do {
                try out.write(to: storeURL, options: .atomic)
            } catch {
                // Leave the backup in place so the next launch can retry the restore.
                storeLog.error("deactivate: store write failed — \(error.localizedDescription, privacy: .public)")
                reloadWallpaperAgent()
                return
            }
        } else {
            storeLog.error("deactivate: could not serialise restored store")
            reloadWallpaperAgent()
            return
        }
        discardBackups()
        reloadWallpaperAgent()
    }

    /// Repair a store left pointing at us by a prior session that quit/crashed
    /// without deactivating. Idempotent: a no-op (and no agent reload) unless some
    /// Desktop node still references our extension. Call once at launch.
    static func healIfStuck() {
        guard let data = try? Data(contentsOf: storeURL),
              data.range(of: Data(extensionBundleID.utf8)) != nil
        else {
            // Store is clean, so any backup on disk is a leftover from a session
            // that crashed and whose wallpaper the user has since changed. Keeping
            // it would make the next deactivate() revert that change.
            discardBackups()
            return
        }
        deactivate()
    }

    private static func discardBackups() {
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: legacyBackupURL)
    }

    /// True if a `Desktop`/`Idle` node's Content is served by our extension.
    private static func pointsAtUs(_ node: [String: Any]) -> Bool {
        guard let content = node["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let provider = choices.first?["Provider"] as? String else { return false }
        return provider == extensionBundleID
    }

    /// Path key for a container holding a `Desktop` node, e.g.
    /// `/Spaces/<uuid>/Displays/<uuid>`. Built the same way when collecting and
    /// when restoring, so the two always line up.
    private static func pathKey(_ path: String) -> String { path.isEmpty ? "/" : path }

    /// Snapshot `path → Desktop.Content` for every Desktop node that isn't already
    /// ours. Nodes that *are* ours are skipped rather than aborting the whole
    /// snapshot, so a store left half-rewritten by a crash still backs up the
    /// nodes that survived.
    static func collectDesktopContents(in node: [String: Any], path: String = "") -> [String: Any] {
        var out: [String: Any] = [:]
        if let desktop = node["Desktop"] as? [String: Any],
           !pointsAtUs(desktop), let content = desktop["Content"] {
            out[pathKey(path)] = content
        }
        for (key, value) in node where key != "Desktop" && key != "Idle" {
            guard let child = value as? [String: Any] else { continue }
            out.merge(collectDesktopContents(in: child, path: path + "/" + key)) { current, _ in current }
        }
        return out
    }

    /// The saved Desktop content macOS itself applies to a Space or display that
    /// appears with no wallpaper of its own — i.e. the user's real desktop image.
    /// Used to restore nodes created *while* we were active, which the backup
    /// never saw (and which macOS seeded from whatever was on screen: us).
    private static func defaultDesktopContent(_ saved: [String: Any]) -> Any? {
        saved[pathKey("/SystemDefault")] ?? saved[pathKey("/AllSpacesAndDisplays")]
    }

    /// Walk the live store and put every Desktop node that points at us back to a
    /// real wallpaper. In order: the `Content` saved for that exact node, then the
    /// saved system-default desktop (for nodes created after activation), then the
    /// sibling `Idle` content as a last resort — Idle is never rewritten by us, so
    /// it always holds a real image, though it's the lock-screen one and can differ
    /// from the desktop. Everything not pointing at us is left exactly as found.
    static func restoreDesktops(in node: [String: Any], saved: [String: Any], path: String = "") -> [String: Any] {
        var result = node
        if var desktop = node["Desktop"] as? [String: Any], pointsAtUs(desktop) {
            let key = pathKey(path)
            let idleContent = (node["Idle"] as? [String: Any]).flatMap { idle in
                pointsAtUs(idle) ? nil : idle["Content"]
            }
            if let replacement = saved[key] ?? defaultDesktopContent(saved) ?? idleContent {
                desktop["Content"] = replacement
                desktop["LastSet"] = Date()
                desktop["LastUse"] = Date()
                result["Desktop"] = desktop
            } else {
                storeLog.error("restore: no saved or Idle content for \(key, privacy: .public) — left on our provider")
            }
        }
        for (key, value) in result where key != "Desktop" && key != "Idle" {
            guard let child = value as? [String: Any] else { continue }
            result[key] = restoreDesktops(in: child, saved: saved, path: path + "/" + key)
        }
        return result
    }

    /// Capture the original Desktop contents once per activation cycle. Returns
    /// false if nothing could be captured *and persisted* — the caller must then
    /// leave the wallpaper alone, since a rewrite it can't undo would strand the
    /// user's desktop on our provider.
    @discardableResult
    private static func backupOnce(_ root: [String: Any]) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backupURL.path) else { return true }

        let saved = collectDesktopContents(in: root)
        guard !saved.isEmpty else {
            storeLog.error("backup: no restorable Desktop content found — refusing to take over the wallpaper")
            return false
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0) else {
            storeLog.error("backup: could not serialise \(saved.count) Desktop node(s)")
            return false
        }
        do {
            try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: backupURL, options: .atomic)
        } catch {
            storeLog.error("backup: write failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
        storeLog.info("backup: captured \(saved.count) Desktop node(s)")
        return true
    }

    /// Replace the `Content` of every `Desktop` node with a single choice provided
    /// by our extension. Idle / screen-saver nodes are left untouched.
    /// ponytail: EncodedOptionValues (crop placement + average colour blob that
    /// System Settings normally writes) is omitted — add one here if WallpaperAgent
    /// refuses the choice without it.
    static func rewriteDesktop(in node: [String: Any], choiceID: String, videoURL: URL) -> [String: Any] {
        var result = node
        for (key, value) in node {
            guard var child = value as? [String: Any] else { continue }
            if key == "Desktop", child["Content"] is [String: Any] {
                child["Content"] = [
                    "Choices": [[
                        "Configuration": Data(choiceID.utf8),
                        "Files": [["relative": videoURL.absoluteString]],
                        "Provider": extensionBundleID,
                    ]],
                    "Shuffle": "$null",
                ]
                child["LastSet"] = Date()
                child["LastUse"] = Date()
                result[key] = child
            } else {
                result[key] = rewriteDesktop(in: child, choiceID: choiceID, videoURL: videoURL)
            }
        }
        return result
    }

    private static func reloadWallpaperAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        try? p.run()
        p.waitUntilExit()
    }
}

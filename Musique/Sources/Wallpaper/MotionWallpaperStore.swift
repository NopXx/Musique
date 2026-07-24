import AppKit
import AVFoundation
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

    /// One stable choice the wallpaper store points at for the whole session, so
    /// WallpaperAgent keeps hosting the same surface (no reload flash per song).
    /// The *file* behind it changes per track — see `stage`.
    static let stableChoiceID = "musique-motion"

    /// Names the clip that is current. Written after the clip itself, read by the
    /// extension when it's told to switch. Must match `WallpaperPaths`.
    private static let pointerFileName = "current"

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

    /// Stage `sourceURL` as the current clip, under a name of its own, and record
    /// it in the pointer file. Each track therefore gets a *distinct* URL: the
    /// previous scheme overwrote one fixed path and relied on AVURLAsset noticing
    /// the replaced inode, which is not a guarantee AVFoundation makes.
    /// Returns the content id (for dedup) and the staged URL, or nil on failure.
    @discardableResult
    static func stage(localVideo sourceURL: URL) -> (contentID: String, url: URL)? {
        guard let dir = videosDir else {
            storeLog.error("stage: videosDir nil (ext container path unresolved)")
            return nil
        }
        let id = contentID(for: sourceURL)
        let dest = dir.appendingPathComponent(id).appendingPathExtension("mov")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: sourceURL, to: dest)
            }
            // Pointer last, atomically — the extension must never read it half-written.
            try Data(dest.lastPathComponent.utf8)
                .write(to: dir.appendingPathComponent(pointerFileName), options: .atomic)
            pruneStagedVideos(in: dir, keeping: dest)
            return (id, dest)
        } catch {
            storeLog.error("stage: \(error.localizedDescription, privacy: .public) src=\(sourceURL.path, privacy: .public) dest=\(dest.path, privacy: .public)")
            return nil
        }
    }

    /// Drop clips staged for previous tracks. Unlinking one the extension still
    /// has open is safe — the inode survives until it closes.
    private static func pruneStagedVideos(in dir: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "mov" && url.lastPathComponent != current.lastPathComponent {
            try? fm.removeItem(at: url)
        }
    }

    /// Remove everything we staged, so the extension's container doesn't keep a
    /// clip around once the feature is off.
    static func clearStagedVideos() {
        guard let dir = videosDir else { return }
        try? FileManager.default.removeItem(at: dir)
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

        // Kill the black flash: the store rewrite reloads WallpaperAgent, which
        // shows nothing for our node until the extension has decoded its first
        // video frame (~1s). Set the video's own first frame as a still image
        // first, so the desktop goes real → artwork still → motion instead of
        // real → black → motion. Best-effort; skipped if the poster can't render.
        setDesktopPoster(from: videoURL)

        root = rewriteDesktop(in: root, choiceID: choiceID, videoURL: videoURL)

        // Settled == the store actually points at us.
        return writeStore(root, satisfies: { hasStuckDesktop(in: $0) })
    }

    /// Render the first frame of `videoURL` to a JPEG and set it as the desktop
    /// image on every screen through AppKit, as an instant no-black placeholder
    /// under the motion wallpaper that is about to take over.
    private static func setDesktopPoster(from videoURL: URL) {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else {
            storeLog.info("poster: could not render first frame — activating without a placeholder")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Musique/motion-poster.jpg")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: url, options: .atomic)
        } catch {
            storeLog.error("poster: write failed — \(error.localizedDescription, privacy: .public)")
            return
        }
        MainActor.assumeIsolated {
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen)
            }
        }
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
            bounceWallpaperAgent()
            return
        }

        var saved: [String: Any] = [:]
        if let backup = try? Data(contentsOf: backupURL),
           let map = (try? PropertyListSerialization.propertyList(from: backup, format: nil)) as? [String: Any] {
            saved = map
        } else {
            storeLog.info("deactivate: no backup — restoring every stuck Desktop from its Idle sibling")
        }

        // The real restore: set the wallpaper through AppKit, which updates
        // WallpaperAgent's own source of truth. Rewriting Index.plist directly is
        // not enough — the agent keeps its selection elsewhere and re-projects it
        // over the file on its next respawn, so a file-only restore reverts to us.
        // (Public API reaches only the current Space per screen; other Spaces are
        // covered best-effort by the Index.plist rewrite below and by healIfStuck
        // when the user next visits them.)
        restoreDesktopViaAppKit(saved: saved, live: root)

        let restored = restoreDesktops(in: root, saved: saved)
        // Settled == no Desktop node points at us any more.
        guard writeStore(restored, satisfies: { !hasStuckDesktop(in: $0) }) else {
            // Leave the backup in place so the next launch can retry the restore.
            return
        }

        clearStagedVideos()
        // Only drop the backup once nothing references us any more. A node we
        // couldn't restore (no saved content, no usable Idle) would otherwise be
        // stranded with the only record of the user's wallpaper deleted.
        if hasStuckDesktop(in: restored) {
            storeLog.error("deactivate: some Desktop nodes could not be restored — keeping the backup for the next launch")
        } else {
            discardBackups()
        }
    }

    /// Repair a store left pointing at us by a prior session that quit/crashed
    /// without deactivating. Idempotent: a no-op (and no agent reload) unless some
    /// Desktop node still references our extension. Call once at launch.
    static func healIfStuck() {
        guard let data = try? Data(contentsOf: storeURL),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              hasStuckDesktop(in: root)
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

    /// True if any `Desktop` node anywhere in the store is still served by us.
    /// Structural rather than a byte scan for our bundle id: that id also appears
    /// inside the staged file's path, so a raw search reports stuck stores that
    /// aren't.
    static func hasStuckDesktop(in node: [String: Any]) -> Bool {
        if let desktop = node["Desktop"] as? [String: Any], pointsAtUs(desktop) { return true }
        for (key, value) in node where key != "Desktop" && key != "Idle" {
            if let child = value as? [String: Any], hasStuckDesktop(in: child) { return true }
        }
        return false
    }

    /// True if a `Desktop`/`Idle` node's Content is served by our extension.
    private static func pointsAtUs(_ node: [String: Any]) -> Bool {
        guard let content = node["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let provider = choices.first?["Provider"] as? String else { return false }
        return provider == extensionBundleID
    }

    /// Set the desktop image through AppKit for every screen, which is the only
    /// restore that WallpaperAgent treats as authoritative. Picks the user's real
    /// image from the backup (the system-default desktop, else any saved node),
    /// falling back to the live store's Idle image — the same picture the lock
    /// screen already shows. A no-op if none can be found; the Index.plist rewrite
    /// then remains the only (weaker) restore.
    private static func restoreDesktopViaAppKit(saved: [String: Any], live: [String: Any]) {
        let content = defaultDesktopContent(saved)
            ?? saved.values.first
            ?? firstIdleContent(in: live)
        guard let content, let url = imageURL(fromContent: content) else {
            storeLog.error("restore: no real image to hand AppKit — relying on the store rewrite only")
            return
        }
        MainActor.assumeIsolated {
            for screen in NSScreen.screens {
                do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen) }
                catch { storeLog.error("restore: setDesktopImageURL failed — \(error.localizedDescription, privacy: .public)") }
            }
        }
        storeLog.info("restore: set desktop image via AppKit — \(url.lastPathComponent, privacy: .public)")
    }

    /// The image file a `Content` blob points at. Image choices store a nested
    /// binary plist in `Configuration` as `{type: imageFile, url: {relative: …}}`.
    static func imageURL(fromContent content: Any) -> URL? {
        guard let dict = content as? [String: Any],
              let choices = dict["Choices"] as? [[String: Any]],
              let cfg = choices.first?["Configuration"] as? Data,
              let inner = (try? PropertyListSerialization.propertyList(from: cfg, format: nil)) as? [String: Any],
              let urlBox = inner["url"] as? [String: Any],
              let relative = urlBox["relative"] as? String
        else { return nil }
        return URL(string: relative)
    }

    /// The first Idle (lock-screen) image anywhere in the store — a real image, as
    /// Idle is never rewritten by us. Last-resort source for the AppKit restore.
    private static func firstIdleContent(in node: [String: Any]) -> Any? {
        if let idle = node["Idle"] as? [String: Any], !pointsAtUs(idle), let c = idle["Content"] { return c }
        for (key, value) in node where key != "Idle" {
            if let child = value as? [String: Any], let found = firstIdleContent(in: child) { return found }
        }
        return nil
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

    /// Replace the wallpaper store with `root`.
    ///
    /// Order matters: WallpaperAgent owns this file while it runs and persists its
    /// own in-memory state on the way out, so writing first and killing after lets
    /// the dying agent overwrite what we just wrote. (Evidence: a `Content` we
    /// write with no `EncodedOptionValues` comes back with that key present — the
    /// agent authored it, not us.) Stop the agent, wait for it to actually go, and
    /// write into the gap; launchd respawns it and it reads our file on startup.
    /// Write, then confirm WallpaperAgent honoured it rather than clobbering it.
    ///
    /// Two hazards, both from toggling on and off quickly:
    ///  - the agent flushes its in-memory state as it dies, so we write only after
    ///    it has actually exited (`stopWallpaperAgentAndWait`);
    ///  - the *next* toggle's killall misses an agent that launchd hasn't respawned
    ///    yet, letting a stale-state agent boot and overwrite us — so we wait for
    ///    the respawn before returning, and the toggle after can always kill it.
    /// If a respawned agent still clobbers the store, retry the whole sequence.
    /// `isSatisfied` describes the intended end state (points at us / doesn't).
    private static func writeStore(_ root: [String: Any], satisfies isSatisfied: ([String: Any]) -> Bool) -> Bool {
        guard let out = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else {
            storeLog.error("store write: could not serialise")
            return false
        }
        for attempt in 1...3 {
            stopWallpaperAgentAndWait()
            do {
                try out.write(to: storeURL, options: .atomic)
            } catch {
                storeLog.error("store write failed — \(error.localizedDescription, privacy: .public)")
                bounceWallpaperAgent()
                return false
            }
            waitForWallpaperAgentRespawn()
            if let live = readStore(), isSatisfied(live) { return true }
            storeLog.error("store not settled after WallpaperAgent respawn (attempt \(attempt)) — retrying")
        }
        storeLog.error("store still not settled after 3 attempts")
        return false
    }

    private static func readStore() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// SIGTERM WallpaperAgent and wait for it to exit. launchd brings it right
    /// back, so this is a reload rather than a shutdown.
    /// ponytail: bounded busy-wait on the main thread — the agent normally goes in
    /// well under 100ms and the retry loop rarely fires, but the ceiling is a few
    /// seconds. If the stall ever shows at lock/unlock, move the whole
    /// activate/deactivate off the main actor rather than shortening the waits.
    private static func stopWallpaperAgentAndWait() {
        let pids = wallpaperAgentPIDs()
        bounceWallpaperAgent()
        guard !pids.isEmpty else { return }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(20_000)
        }
        if pids.contains(where: { kill($0, 0) == 0 }) {
            storeLog.error("agent still alive after 1s — writing anyway, it may overwrite us")
        }
    }

    /// Wait for launchd to bring WallpaperAgent back after a kill, so a subsequent
    /// toggle's killall can't miss it and let a stale agent boot over our write.
    /// It also gives the fresh agent time to load the store we just wrote.
    private static func waitForWallpaperAgentRespawn() {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, wallpaperAgentPIDs().isEmpty {
            usleep(100_000)
        }
        usleep(300_000)   // let it read the store on startup before we check
    }

    private static func wallpaperAgentPIDs() -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "WallpaperAgent"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func bounceWallpaperAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}

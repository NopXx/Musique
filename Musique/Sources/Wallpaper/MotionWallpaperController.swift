import Foundation
import os

/// Drives the *motion* desktop wallpaper: as the now-playing track changes, stage
/// its animated artwork and make it the real system wallpaper via the wallpaper
/// extension (see `MotionWallpaperStore`). Shares the one `set_system_wallpaper`
/// opt-in with the static-image wallpaper: this path runs for tracks that have
/// motion artwork, the still for the rest.
///
/// "Auto per song": the first track activates our wallpaper (rewrite the store +
/// reload WallpaperAgent, one flash). Every later track just overwrites the staged
/// clip and pings the extension, which swaps it on the live surface — no reload.
@MainActor
final class MotionWallpaperController {
    private let log = Logger(subsystem: "com.nopxx.musique", category: "MotionWallpaper")
    private var activeContentID: String?
    private var storeActivated = false
    /// Animated artwork the *current* track wants. A download that lands after the
    /// track already moved on is dropped, so a slow fetch can't overwrite a newer
    /// track's clip.
    private var desiredRemote: URL?
    /// Clip whose staging failed; skipped until a different one comes along.
    private var failedStagingSource: URL?
    /// A detached activate/deactivate is rewriting the wallpaper store. New store
    /// work is skipped while set — the two would fight over WallpaperAgent.
    private var storeBusy = false {
        didSet { if storeBusy != oldValue { onStoreBusyChange?(storeBusy) } }
    }

    /// Fires as a store rewrite starts and finishes. The rewrite kills
    /// WallpaperAgent and waits for launchd to bring it back, and while it's gone
    /// *no* desktop is drawn on *any* display — so the lock screen has a couple of
    /// seconds of black to cover on every screen it isn't already drawing on.
    var onStoreBusyChange: ((Bool) -> Void)?

    private var enabled: Bool { SettingsStore.shared.bool(["lockscreen", "set_system_wallpaper"]) }

    /// Called whenever the wallpaper starts or stops actually playing our clip, so
    /// the lock screen knows whether the real desktop is showing the artwork or it
    /// has to draw its own copy (activation is slow and can fail outright).
    var onLiveChange: ((Bool) -> Void)?

    /// Fired once a restore has actually finished. The restore puts the user's own
    /// wallpaper back, so whoever wants the desktop next — the still artwork, when
    /// the next track has no video — has to claim it *after* this, not before.
    var onRestored: (() -> Void)?

    private var isLive = false {
        didSet { if isLive != oldValue { onLiveChange?(isLive) } }
    }

    /// Reconcile the wallpaper with the current track's animated artwork.
    /// Call on track change, artwork-resolved, and settings change.
    func sync(artwork: ArtworkResult, hasTrack: Bool) {
        guard enabled, hasTrack, let remote = animatedURL(artwork) else {
            disableIfActive()
            return
        }
        desiredRemote = remote
        // Need the animated file on disk. If it's cached, use it now; otherwise
        // kick off the download and reconcile again when it lands.
        if let local = AnimatedArtworkCache.shared.localURLIfCached(for: remote) {
            activate(local: local)
        } else {
            AnimatedArtworkCache.shared.resolve(remote: remote) { [weak self] local in
                Task { @MainActor in
                    guard let self, self.enabled else { return }
                    guard self.desiredRemote == remote else {
                        self.log.info("dropped stale artwork download — track already moved on")
                        return
                    }
                    self.activate(local: local)
                }
            }
        }
    }

    /// Turn the feature off: restore the user's previous wallpaper. Runs the slow
    /// store work in the background; pass `blocking: true` only on app quit, where
    /// returning before the restore finished would leave our wallpaper behind.
    func disableIfActive(blocking: Bool = false) {
        desiredRemote = nil   // also cancels any in-flight download's effect
        isLive = false
        guard storeActivated else { return }
        activeContentID = nil
        storeActivated = false
        if blocking {
            MotionWallpaperStore.deactivate()
            log.info("motion wallpaper deactivated — restored previous wallpaper")
            return
        }
        storeBusy = true
        Task.detached(priority: .userInitiated) { [log] in
            MotionWallpaperStore.deactivate()
            log.info("motion wallpaper deactivated — restored previous wallpaper")
            await MainActor.run {
                self.storeBusy = false
                self.onRestored?()
            }
        }
    }

    private func activate(local: URL) {
        // Staging fails for the whole session when the extension's container isn't
        // writable (macOS withholds access to another app's data). `sync` runs on
        // every 1 Hz tick, so without this the failure repeats — and re-logs —
        // once a second for as long as the lock screen is up.
        guard local != failedStagingSource else { return }
        guard let staged = MotionWallpaperStore.stage(localVideo: local) else {
            failedStagingSource = local
            log.error("failed to stage motion wallpaper video — not retrying this clip")
            return
        }
        failedStagingSource = nil
        guard staged.contentID != activeContentID else { return }   // already showing this clip
        if storeActivated {
            // Live swap: file already overwritten, just tell the extension.
            activeContentID = staged.contentID
            MotionWallpaperStore.announceSwitch()
            isLive = true
            log.info("motion wallpaper swapped — content \(staged.contentID, privacy: .public)")
        } else {
            // First activation: point the store at us + reload the agent once.
            // The store work bounces WallpaperAgent and waits for the respawn —
            // seconds of blocking — so it runs detached; on the main actor it
            // froze the enlarge animation and the overlay's own video for the
            // whole wait. The overlay keeps playing its copy until `isLive`.
            // Only claim to be active if the store actually took the rewrite —
            // otherwise deactivate() would later "restore" a wallpaper we never
            // replaced, and a retry on the next track would never happen.
            guard !storeBusy else { return }   // in flight; the next sync retries
            storeBusy = true
            // Honour the lock screen's "Display on" choice: main-only limits the
            // store rewrite to the main display's nodes, like the overlay windows.
            let onlyDisplay = SettingsStore.shared.string(["lockscreen", "screens"]) == "all"
                ? nil : MotionWallpaperStore.mainDisplayUUID()
            Task.detached(priority: .userInitiated) {
                let ok = MotionWallpaperStore.activate(choiceID: MotionWallpaperStore.stableChoiceID,
                                                       videoURL: staged.url, onlyDisplayUUID: onlyDisplay)
                await MainActor.run { self.finishActivation(ok: ok, contentID: staged.contentID) }
            }
        }
    }

    /// Back on the main actor after the detached store rewrite. The user may have
    /// shrunk the artwork or unlocked while it ran — `desiredRemote` is nil then,
    /// and a takeover nobody wants any more is rolled straight back.
    private func finishActivation(ok: Bool, contentID: String) {
        storeBusy = false
        guard ok else {
            log.error("motion wallpaper activation failed — wallpaper store not rewritten")
            return
        }
        activeContentID = contentID
        storeActivated = true
        guard desiredRemote != nil else {
            log.info("motion wallpaper activated but no longer wanted — rolling back")
            disableIfActive()
            return
        }
        isLive = true
        log.info("motion wallpaper activated — content \(contentID, privacy: .public)")
    }

    private func animatedURL(_ art: ArtworkResult) -> URL? {
        let s = art.animationSquareUltraURL ?? art.animationURL ?? art.animationTallURL
        return s.flatMap(URL.init(string:))
    }
}

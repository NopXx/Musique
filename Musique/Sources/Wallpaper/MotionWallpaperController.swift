import Foundation
import os

/// Drives the *motion* desktop wallpaper: as the now-playing track changes, stage
/// its animated artwork and make it the real system wallpaper via the wallpaper
/// extension (see `MotionWallpaperStore`). Opt-in per the `desktop_animated_wallpaper`
/// setting; distinct from the lock-only static-image wallpaper (`set_system_wallpaper`).
///
/// "Auto per song": the first track activates our wallpaper (rewrite the store +
/// reload WallpaperAgent, one flash). Every later track just overwrites the staged
/// clip and pings the extension, which swaps it on the live surface — no reload.
@MainActor
final class MotionWallpaperController {
    private let log = Logger(subsystem: "com.nopxx.musique", category: "MotionWallpaper")
    private var activeContentID: String?
    private var storeActivated = false

    private var enabled: Bool { SettingsStore.shared.bool(["lockscreen", "desktop_animated_wallpaper"]) }

    /// Reconcile the wallpaper with the current track's animated artwork.
    /// Call on track change, artwork-resolved, and settings change.
    func sync(artwork: ArtworkResult, hasTrack: Bool) {
        guard enabled, hasTrack, let remote = animatedURL(artwork) else {
            disableIfActive()
            return
        }
        // Need the animated file on disk. If it's cached, use it now; otherwise
        // kick off the download and reconcile again when it lands.
        if let local = AnimatedArtworkCache.shared.localURLIfCached(for: remote) {
            activate(local: local)
        } else {
            AnimatedArtworkCache.shared.resolve(remote: remote) { [weak self] local in
                Task { @MainActor in
                    guard let self, self.enabled else { return }
                    self.activate(local: local)
                }
            }
        }
    }

    /// Turn the feature off: restore the user's previous wallpaper.
    func disableIfActive() {
        guard storeActivated else { return }
        activeContentID = nil
        storeActivated = false
        MotionWallpaperStore.deactivate()
        log.info("motion wallpaper deactivated — restored previous wallpaper")
    }

    private func activate(local: URL) {
        guard let staged = MotionWallpaperStore.stage(localVideo: local) else {
            log.error("failed to stage motion wallpaper video")
            return
        }
        guard staged.contentID != activeContentID else { return }   // already showing this clip
        if storeActivated {
            // Live swap: file already overwritten, just tell the extension.
            activeContentID = staged.contentID
            MotionWallpaperStore.announceSwitch()
            log.info("motion wallpaper swapped — content \(staged.contentID, privacy: .public)")
        } else {
            // First activation: point the store at us + reload the agent once.
            // Only claim to be active if the store actually took the rewrite —
            // otherwise deactivate() would later "restore" a wallpaper we never
            // replaced, and a retry on the next track would never happen.
            guard MotionWallpaperStore.activate(choiceID: MotionWallpaperStore.stableChoiceID, videoURL: staged.url) else {
                log.error("motion wallpaper activation failed — wallpaper store not rewritten")
                return
            }
            activeContentID = staged.contentID
            storeActivated = true
            log.info("motion wallpaper activated — content \(staged.contentID, privacy: .public)")
        }
    }

    private func animatedURL(_ art: ArtworkResult) -> URL? {
        let s = art.animationSquareUltraURL ?? art.animationURL ?? art.animationTallURL
        return s.flatMap(URL.init(string:))
    }
}

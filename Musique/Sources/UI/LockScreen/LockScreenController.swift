import AppKit
import SwiftUI
import Combine
import os

@MainActor
final class LockScreenController {
    static var shared: LockScreenController?

    private let log = Logger(subsystem: "com.nopxx.musique", category: "LockScreen")
    private let playerMonitor: PlayerMonitor
    private let viewModel: LockScreenViewModel
    private var playerWindows: [LockScreenWindow] = []
    private var cancellables = Set<AnyCancellable>()
    private var isLocked = false
    /// The screen saver runs above everything, including the lock UI and our
    /// SkyLight-pinned windows. Tracked separately from `isLocked` because the
    /// two are independent: the saver can run unlocked, and locking *through* the
    /// saver delivers `screenIsLocked` before, during or after it starts.
    private var isScreensaverActive = false
    private var raiseTimer: Timer?
    private var lastWallpaperKey: String?
    /// Motion (video) desktop wallpaper driver — separate opt-in from the
    /// static-image path in `syncWallpaper`. Auto-swaps with the track.
    private let motionWallpaper = MotionWallpaperController()
    /// Last-seen `set_system_wallpaper` value, to detect a live toggle from the
    /// on-lock card and rebuild windows (draw-own-background ⇄ desktop artwork).
    private var lastWallpaperMode: Bool?

    init(playerMonitor: PlayerMonitor) {
        self.playerMonitor = playerMonitor
        self.viewModel = LockScreenViewModel(monitor: playerMonitor)

        // Recover any desktop a prior session left stuck on our wallpaper provider.
        MotionWallpaperStore.healIfStuck()

        // The overlay draws its own video copy until the real desktop is playing
        // ours — so a slow or failed activation doesn't leave the lock screen bare.
        motionWallpaper.onLiveChange = { [weak viewModel] live in
            viewModel?.motionWallpaperLive = live
        }
        SystemWallpaperOperator.shared.onLiveChange = { [weak viewModel] live in
            viewModel?.staticWallpaperLive = live
        }
        // A motion restore paints the user's own wallpaper back. If we still want
        // artwork up there — next track has a still, screen still locked — claim
        // the desktop again now that the restore is done, not before it.
        motionWallpaper.onRestored = { [weak self] in
            self?.syncWallpaper(force: true)
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self,
                        selector: #selector(handleScreenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(handleScreenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(handleLockUIShown),
                        name: NSNotification.Name("com.apple.screenLockUIIsShown"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(handleLockUIHidden),
                        name: NSNotification.Name("com.apple.screenLockUIIsHidden"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(handleScreensaverStarted),
                        name: NSNotification.Name("com.apple.screensaver.didstart"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(handleScreensaverStopped),
                        name: NSNotification.Name("com.apple.screensaver.didstop"),
                        object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        SettingsStore.shared.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let mode = SettingsStore.shared.bool(["lockscreen", "set_system_wallpaper"])
                let flipped = self.isLocked && mode != self.lastWallpaperMode
                // On an on/off flip, capture the current desktop as the outgoing
                // image *before* syncWallpaper swaps it, then crossfade to hide
                // the instant swap.
                let outgoing = flipped ? self.currentDesktopImage() : nil
                self.syncWallpaper()
                if flipped, let outgoing { self.startCrossfade(from: outgoing) }
                self.lastWallpaperMode = mode
                self.syncMotionWallpaper()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        playerMonitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                guard let self else { return }
                if self.isLocked, snap?.hasTrack != true {
                    self.dismiss()
                } else if self.isLocked {
                    self.evaluateVisibility()
                }
                self.syncWallpaper()
                self.prewarmWallpaper()
                self.syncMotionWallpaper()
            }
            .store(in: &cancellables)

        // While locked, keep the desktop wallpaper (which the lock screen
        // renders) tracking the now-playing artwork as the track changes.
        // syncWallpaper is a no-op unless locked, so this never touches the
        // visible desktop. Artwork loads async → react to it landing.
        viewModel.$artworkImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWallpaper()
                self?.prewarmWallpaper()
                self?.syncMotionWallpaper()
            }
            .store(in: &cancellables)

        // The still wallpaper holds the desktop until the motion one is really
        // playing, so re-run the static path as that flips.
        viewModel.$motionWallpaperLive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWallpaper() }
            .store(in: &cancellables)

        // Both wallpapers are coupled to the thumbnail tap (enlarge state), so
        // activate/restore them as that flips.
        viewModel.$isLargeArtwork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWallpaper()
                self?.syncMotionWallpaper()
            }
            .store(in: &cancellables)

        // Restore the user's wallpaper on quit, and recover it if a previous
        // session died mid-playback.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                SystemWallpaperOperator.shared.restore()
                // Blocking on purpose: a detached restore wouldn't finish before
                // the process dies, leaving our wallpaper behind.
                self?.motionWallpaper.disableIfActive(blocking: true)
            }
        }
        SystemWallpaperOperator.shared.recoverIfNeeded()

        log.info("LockScreenController initialised")
        Self.shared = self
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleScreenLocked() {
        log.info("DistributedNotification: screenIsLocked")
        isLocked = true
        syncWallpaper()
        prewarmWallpaper()
        syncMotionWallpaper()
        evaluateVisibility()
    }

    /// Give the screen up to the saver rather than fighting it: it draws above
    /// our windows, so raising them just burns the raise loop. The overlay comes
    /// back when the saver stops, if we're still locked.
    @objc private func handleScreensaverStarted() {
        log.info("DistributedNotification: screensaver.didstart")
        isScreensaverActive = true
        dismiss()
    }

    @objc private func handleScreensaverStopped() {
        log.info("DistributedNotification: screensaver.didstop — locked:\(self.isLocked)")
        isScreensaverActive = false
        // Dismissing the saver while locked hands the screen back to the lock UI,
        // which draws over us on the way in — same situation as a fresh lock.
        guard isLocked else { return }
        evaluateVisibility()
        raiseAllWindows()
        startRaiseLoop()
    }

    @objc private func handleScreenUnlocked() {
        log.info("DistributedNotification: screenIsUnlocked")
        isLocked = false
        // Unlocking always tears the saver down, and a missed didstop would
        // otherwise keep the overlay suppressed for the rest of the session.
        isScreensaverActive = false
        stopRaiseLoop()
        dismiss()
        viewModel.isLargeArtwork = false   // clear tap state so next lock starts fresh
        syncWallpaper()          // isLocked == false → restores the desktop wallpaper
        syncMotionWallpaper()    // isLocked == false → deactivates the motion wallpaper
    }

    /// Set or restore the *desktop* wallpaper to match playback state. The lock
    /// screen renders the desktop wallpaper, so we only apply the artwork while
    /// locked — otherwise it would show on the user's visible desktop — and
    /// restore it the moment the screen unlocks.
    /// `force` re-applies even when the artwork hasn't changed — used after a
    /// motion restore has painted the user's wallpaper over ours.
    private func syncWallpaper(force: Bool = false) {
        let op = SystemWallpaperOperator.shared
        if force {
            lastWallpaperKey = nil
            // Nothing of ours is on the desktop now, so let the overlay draw its
            // own copy again until the re-applied still actually lands.
            op.standDown()
        }
        // The still goes up first even for tracks that have motion artwork: the
        // clip has to download and WallpaperAgent has to be bounced, seconds in
        // which the desktop would otherwise still show the user's own wallpaper.
        // Hand the desktop over only once the video is really playing — and hand
        // it over rather than restoring, which would paint over the video.
        if viewModel.motionWallpaperLive {
            if lastWallpaperKey != nil {
                SystemWallpaperOperator.shared.standDown()
                lastWallpaperKey = nil
            }
            return
        }
        // Tap-driven: show the artwork as the real wallpaper only while locked AND
        // the user has tapped the now-playing thumbnail.
        guard isLocked, viewModel.isLargeArtwork else {
            if lastWallpaperKey != nil { op.restore(); lastWallpaperKey = nil }
            return
        }
        let blur = SettingsStore.shared.int(["lockscreen", "background_blur"])
        // Key on artwork + blur so the 1 Hz position tick doesn't re-apply
        // on every snapshot update.
        if playerMonitor.snapshot?.hasTrack == true, let image = viewModel.artworkImage {
            let key = "\(viewModel.artwork.artworkURL ?? "")|\(blur)"
            guard key != lastWallpaperKey else { return }
            lastWallpaperKey = key
            op.apply(image: image, blurRadius: Double(blur), key: key)
        } else if lastWallpaperKey != nil {
            op.restore()   // nothing playing → restore
            lastWallpaperKey = nil
        }
    }

    /// Reconcile the motion (video) wallpaper. Coupled to the enlarge/tap state
    /// like the static wallpaper: it activates only while locked AND the user has
    /// tapped the now-playing thumbnail (`isLargeArtwork`), and restores on shrink
    /// or unlock — so entering the lock screen doesn't silently replace the
    /// wallpaper before the user asks for it.
    private func syncMotionWallpaper() {
        guard isLocked, viewModel.isLargeArtwork else {
            motionWallpaper.disableIfActive()
            return
        }
        motionWallpaper.sync(artwork: viewModel.artwork, hasTrack: playerMonitor.snapshot?.hasTrack == true)
    }

    /// The current real desktop wallpaper of the main screen as an image, used
    /// as the outgoing frame of a crossfade.
    private func currentDesktopImage() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Show `image` full-screen over the just-swapped desktop, then fade it out —
    /// masking the un-animatable `setDesktopImageURL` with a crossfade.
    private func startCrossfade(from image: NSImage) {
        viewModel.crossfadeImage = image
        // Let the cover frame render, then fade it away to reveal the new desktop.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.5)) { self.viewModel.crossfadeImage = nil }
        }
    }

    /// Pre-render the wallpaper file while locked so the enlarge-tap swap is
    /// instant. Runs regardless of the toggle — it only writes a file, never
    /// touches the live desktop.
    private func prewarmWallpaper() {
        // Runs while the feature is *on* — it used to be guarded on the toggle
        // being off, exactly backwards, so the tap paid for the whole blur+encode
        // and the wallpaper landed seconds late. With it off nothing ever reaches
        // the desktop, so there is nothing to warm.
        guard isLocked,
              SettingsStore.shared.bool(["lockscreen", "set_system_wallpaper"]),
              playerMonitor.snapshot?.hasTrack == true,
              let image = viewModel.artworkImage else { return }
        let blur = SettingsStore.shared.int(["lockscreen", "background_blur"])
        let key = "\(viewModel.artwork.artworkURL ?? "")|\(blur)"
        SystemWallpaperOperator.shared.prepare(image: image, blurRadius: Double(blur), key: key)
    }

    @objc private func handleLockUIShown() {
        guard !isScreensaverActive else {
            log.info("DistributedNotification: screenLockUIIsShown — screen saver up, not raising")
            return
        }
        log.info("DistributedNotification: screenLockUIIsShown — re-raising window")
        raiseAllWindows()
        startRaiseLoop()
    }

    @objc private func handleLockUIHidden() {
        log.info("DistributedNotification: screenLockUIIsHidden")
        stopRaiseLoop()
    }

    @objc private func handleScreensChanged() {
        guard isLocked, !playerWindows.isEmpty else { return }
        log.info("Screen parameters changed — rebuilding windows")
        rebuildWindows()
    }

    func setFullscreenAnimationActive(_ active: Bool) {
        viewModel.fullscreenAnimationActive = active
    }

    private func evaluateVisibility() {
        guard isLocked, !isScreensaverActive else { return }
        let s = SettingsStore.shared
        let enabled = s.bool(["lockscreen", "enabled"])
        let hasTrack = playerMonitor.snapshot?.hasTrack == true
        log.info("evaluateVisibility — enabled:\(enabled) hasTrack:\(hasTrack) windows:\(self.playerWindows.count)")
        guard enabled, hasTrack else {
            dismiss()
            return
        }
        if playerWindows.isEmpty {
            present()
        } else {
            applyScreensIfNeeded()
        }
    }

    private func present() {
        let targets = targetScreens()
        // One SkyLight window per screen — the player view hosts everything.
        log.info("present — \(targets.count) screen(s)")
        for screen in targets {
            let playerWindow = LockScreenWindow(screen: screen)
            let playerHost = NSHostingController(rootView: LockScreenPlayerView(viewModel: viewModel))
            playerHost.view.frame = NSRect(origin: .zero, size: screen.frame.size)
            playerWindow.contentViewController = playerHost
            playerWindow.setFrame(screen.frame, display: true)
            SkyLightOperator.shared.promoteAboveLockScreen(playerWindow)
            playerWindow.makeKeyAndOrderFront(nil)
            playerWindows.append(playerWindow)

            log.info("Windows shown — frame:\(NSStringFromRect(screen.frame), privacy: .public)")
        }
    }

    private func dismiss() {
        stopRaiseLoop()
        guard !playerWindows.isEmpty else { return }
        log.info("dismiss — closing \(self.playerWindows.count) window(s)")
        for window in playerWindows {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        playerWindows.removeAll()
    }

    /// Re-call `orderFrontRegardless` on every window. macOS's loginwindow
    /// often draws the lock UI ~0.5–1.5s after `screenIsLocked` fires, which
    /// can cover our window. Calling `orderFrontRegardless` again pushes us
    /// back on top.
    private func raiseAllWindows() {
        for window in playerWindows {
            window.orderFrontRegardless()
            SkyLightOperator.shared.promoteAboveLockScreen(window)
        }
    }

    /// Burst-retry raising the window for ~3s after the lock UI starts to
    /// appear. The lock UI animation can re-cover us multiple times during
    /// the transition; a short repeating timer keeps us in front until the
    /// UI settles.
    private func startRaiseLoop() {
        stopRaiseLoop()
        let start = Date()
        raiseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if Date().timeIntervalSince(start) > 3.0 || self.playerWindows.isEmpty {
                    timer.invalidate()
                    self.raiseTimer = nil
                    return
                }
                self.raiseAllWindows()
            }
        }
    }

    private func stopRaiseLoop() {
        raiseTimer?.invalidate()
        raiseTimer = nil
    }

    private func rebuildWindows() {
        dismiss()
        present()
    }

    private func applyScreensIfNeeded() {
        let targetIDs = Set(targetScreens().compactMap(screenID))
        let currentIDs = Set(playerWindows.compactMap { $0.screen.flatMap(screenID) })
        if targetIDs != currentIDs {
            rebuildWindows()
        }
    }

    private func targetScreens() -> [NSScreen] {
        let mode = SettingsStore.shared.string(["lockscreen", "screens"])
        if mode == "all" {
            return NSScreen.screens
        }
        return [NSScreen.main].compactMap { $0 }
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

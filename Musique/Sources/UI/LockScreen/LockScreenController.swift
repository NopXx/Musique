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
    private var backgroundWindows: [LockScreenBackgroundWindow] = []
    private var playerWindows: [LockScreenWindow] = []
    private var cancellables = Set<AnyCancellable>()
    private var isLocked = false
    private var raiseTimer: Timer?
    private var lastWallpaperKey: String?
    /// Motion (video) desktop wallpaper driver — separate opt-in from the
    /// lock-only static `set_system_wallpaper`. Auto-swaps with the track.
    private let motionWallpaper = MotionWallpaperController()
    /// Last-seen `set_system_wallpaper` value, to detect a live toggle from the
    /// on-lock card and rebuild windows (draw-own-background ⇄ desktop artwork).
    private var lastWallpaperMode: Bool?

    init(playerMonitor: PlayerMonitor) {
        self.playerMonitor = playerMonitor
        self.viewModel = LockScreenViewModel(monitor: playerMonitor)

        // Recover any desktop a prior session left stuck on our wallpaper provider.
        MotionWallpaperStore.healIfStuck()

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
                self.applySkyLevel()
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
                self?.motionWallpaper.disableIfActive()
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

    @objc private func handleScreenUnlocked() {
        log.info("DistributedNotification: screenIsUnlocked")
        isLocked = false
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
    private func syncWallpaper() {
        let op = SystemWallpaperOperator.shared
        // Tap-driven: show the static artwork as the real wallpaper only while
        // locked AND the user has tapped the now-playing thumbnail. When the motion
        // (video) wallpaper is the active choice, let it own the wallpaper instead
        // of painting a still over it.
        let motionOwnsWallpaper = SettingsStore.shared.bool(["lockscreen", "desktop_animated_wallpaper"]) && hasMotionArtwork
        guard isLocked, viewModel.isLargeArtwork, !motionOwnsWallpaper else {
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
    /// Whether the current track has usable motion artwork (and the animated
    /// artwork feature is on) — i.e. tapping would show a video, not a still.
    private var hasMotionArtwork: Bool {
        guard viewModel.animatedArtwork else { return false }
        let s = viewModel.artwork.animationSquareUltraURL ?? viewModel.artwork.animationURL ?? viewModel.artwork.animationTallURL
        return s?.isEmpty == false
    }

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
        guard isLocked,
              SettingsStore.shared.bool(["lockscreen", "set_system_wallpaper"]) == false,
              playerMonitor.snapshot?.hasTrack == true,
              let image = viewModel.artworkImage else { return }
        let blur = SettingsStore.shared.int(["lockscreen", "background_blur"])
        let key = "\(viewModel.artwork.artworkURL ?? "")|\(blur)"
        SystemWallpaperOperator.shared.prepare(image: image, blurRadius: Double(blur), key: key)
    }

    @objc private func handleLockUIShown() {
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
        guard isLocked else { return }
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

    /// Push the user-chosen SkyLight space level. Live: re-composites any
    /// currently-attached overlay window without a rebuild.
    private func applySkyLevel() {
        let lvl = SettingsStore.shared.int(["lockscreen", "sky_level"])
        SkyLightOperator.shared.setBackgroundLevel(lvl > 0 ? Int32(lvl) : 400)
    }

    private func present() {
        let targets = targetScreens()
        // Always attach the background window; `ArtworkLockScreenView.shouldShow`
        // keeps it transparent in system-wallpaper mode (real desktop shows
        // through) and fades it in otherwise. Attaching it unconditionally means
        // toggling the mode live needs no window rebuild.
        log.info("present — \(targets.count) screen(s)")
        for screen in targets {
            let bgWindow = LockScreenBackgroundWindow(screen: screen)
            let bgHost = NSHostingController(rootView: ArtworkLockScreenView(viewModel: viewModel))
            bgHost.view.frame = NSRect(origin: .zero, size: screen.frame.size)
            bgWindow.contentViewController = bgHost
            bgWindow.setFrame(screen.frame, display: true)
            SkyLightOperator.shared.promoteBackground(bgWindow)
            bgWindow.makeKeyAndOrderFront(nil)
            backgroundWindows.append(bgWindow)

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
        guard !backgroundWindows.isEmpty || !playerWindows.isEmpty else { return }
        log.info("dismiss — closing \(self.backgroundWindows.count + self.playerWindows.count) window(s)")
        for window in backgroundWindows {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        for window in playerWindows {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        backgroundWindows.removeAll()
        playerWindows.removeAll()
    }

    /// Re-call `orderFrontRegardless` on every window. macOS's loginwindow
    /// often draws the lock UI ~0.5–1.5s after `screenIsLocked` fires, which
    /// can cover our window. Calling `orderFrontRegardless` again pushes us
    /// back on top.
    private func raiseAllWindows() {
        for window in backgroundWindows {
            window.orderFrontRegardless()
            SkyLightOperator.shared.promoteBackground(window)
        }
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

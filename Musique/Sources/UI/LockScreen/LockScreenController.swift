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
    /// Stand-ins over the screens the overlay doesn't cover, shown only while a
    /// wallpaper-store rewrite has WallpaperAgent killed. See `setDesktopFiller`.
    private var fillerWindows: [LockScreenWindow] = []
    private var cancellables = Set<AnyCancellable>()
    private var isLocked = false
    private var raiseTimer: Timer?
    private var lastWallpaperKey: String?
    /// Motion (video) desktop wallpaper driver — separate opt-in from the
    /// static-image path in `syncWallpaper`. Auto-swaps with the track.
    private let motionWallpaper = MotionWallpaperController()

    /// The desktop-wallpaper takeover — `SystemWallpaperOperator`,
    /// `MotionWallpaperController`, the `MusiqueWallpaper` appex — is off. The
    /// SkyLight overlay draws the fullscreen artwork itself now, so hijacking the
    /// real desktop bought nothing and cost a WallpaperAgent bounce, an
    /// `Index.plist` rewrite, and a whole class of stuck-wallpaper bugs.
    ///
    /// This gates *activation only*. `MotionWallpaperStore.healIfStuck()`,
    /// `SystemWallpaperOperator.recoverIfNeeded()` and the willTerminate restore
    /// stay unconditional — a desktop an older build left hijacked still has to be
    /// handed back.
    ///
    /// ponytail: a constant, not a setting, so re-enabling is a one-word edit.
    /// Ceiling — if the overlay is still the only path at the next release, delete
    /// `Sources/Wallpaper/`, `SystemWallpaperOperator` and the MusiqueWallpaper
    /// target outright.
    private static let wallpaperTakeoverEnabled = false

    /// True when the user is at the machine and loginwindow's password panel is
    /// (about to be) on screen. The fullscreen artwork covers it completely, so it
    /// fades while this holds.
    ///
    /// ponytail: driven by the screen saver stopping/starting, which is the only
    /// "the user just touched this machine" signal we get while locked.
    /// `com.apple.screenLockUIIsShown` looks like the right notification and isn't
    /// — it fires ~1s after every lock and its `…IsHidden` partner only fires at
    /// unlock, so it means "the lock screen is up", not "the password panel is up".
    /// Wiring the fade to it made the window click-through for the whole lock
    /// session and the enlarge tap never landed. Ceiling: if the saver is off
    /// entirely the fade never fires — click-anywhere-to-shrink and blind typing
    /// still unlock, they're just the only ways.
    private var lockUIVisible = false {
        didSet {
            guard lockUIVisible != oldValue else { return }
            viewModel.lockUIVisible = lockUIVisible
            applyMouseTransparency()
        }
    }

    /// Hand the mouse to loginwindow while the artwork is up but faded. A window
    /// that isn't ignoring the mouse swallows the click even where it draws
    /// nothing — AppKit hit-tests by frame, not by pixel alpha, so
    /// `allowsHitTesting(false)` in the view would make the click vanish rather
    /// than reach the password field.
    ///
    /// Gated on `isLargeArtwork` as well: with nothing covering the screen there is
    /// nothing to see past, and going click-through would only kill the card's own
    /// taps — which is exactly how the enlarge stopped working.
    ///
    /// The keyboard needs nothing: `LockScreenWindow` is borderless, so
    /// `canBecomeKey` is false and focus never leaves loginwindow. That's this
    /// feature's safety valve — even if the fade never fires, the user can type
    /// their password blind and press Return. Covering the field is never a lockout.
    private func applyMouseTransparency() {
        let clickThrough = lockUIVisible && viewModel.isLargeArtwork
        for window in playerWindows { window.ignoresMouseEvents = clickThrough }
    }

    init(playerMonitor: PlayerMonitor) {
        self.playerMonitor = playerMonitor
        self.viewModel = LockScreenViewModel(monitor: playerMonitor)

        // Recover any desktop a prior session left stuck on our wallpaper provider.
        // Runs unconditionally — see `wallpaperTakeoverEnabled`.
        MotionWallpaperStore.healIfStuck()

        // The overlay draws its own video copy until the real desktop is playing
        // ours — so a slow or failed activation doesn't leave the lock screen bare.
        motionWallpaper.onLiveChange = { [weak viewModel] live in
            viewModel?.motionWallpaperLive = live
        }
        SystemWallpaperOperator.shared.onLiveChange = { [weak viewModel] live in
            viewModel?.staticWallpaperLive = live
        }
        motionWallpaper.onStoreBusyChange = { [weak self] busy in
            self?.setDesktopFiller(busy)
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
                self.syncWallpaper()
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

        viewModel.$isLargeArtwork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] large in
                guard let self else { return }
                self.log.info("isLargeArtwork -> \(large) (lockUIVisible:\(self.lockUIVisible))")
                // The tap is the user saying "show me the artwork" — it overrides a
                // stale fade rather than enlarging into an invisible layer.
                if large { self.lockUIVisible = false }
                self.applyMouseTransparency()
                self.syncWallpaper()
                self.syncMotionWallpaper()
            }
            .store(in: &cancellables)

        // Restore the user's wallpaper on quit, and recover it if a previous
        // session died mid-playback. Deliberately NOT behind
        // `wallpaperTakeoverEnabled`: an older build may have left the desktop
        // hijacked, and only this hands it back.
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
        // Also unconditional, and for the same reason as `healIfStuck` above.
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
        lockUIVisible = false   // a fresh lock starts clean
        syncWallpaper()
        prewarmWallpaper()
        syncMotionWallpaper()
        evaluateVisibility()
    }

    /// macOS 26 unifies the screen saver with the lock screen: the saver *is* the
    /// locked background, and our SkyLight overlay draws on it exactly as on the
    /// plain lock screen. So don't tear the overlay down for the saver (the old
    /// legacy-macOS behaviour, where the saver drew above everything) — keep it up
    /// and fight to stay raised, like the lock UI appearing.
    @objc private func handleScreensaverStarted() {
        log.info("DistributedNotification: screensaver.didstart")
        guard isLocked else { return }
        // The machine went idle — nobody is looking at a password field, so put
        // the artwork back.
        lockUIVisible = false
        evaluateVisibility()
        raiseAllWindows()
        startRaiseLoop()
    }

    @objc private func handleScreensaverStopped() {
        log.info("DistributedNotification: screensaver.didstop — locked:\(self.isLocked)")
        // Dismissing the saver while locked hands the screen back to the lock UI,
        // which draws over us on the way in — same situation as a fresh lock.
        guard isLocked else { return }
        // Somebody woke the machine, so the password panel is what they want to
        // see, not the artwork. Fade until they tap or it idles out again.
        lockUIVisible = true
        evaluateVisibility()
        raiseAllWindows()
        startRaiseLoop()
    }

    @objc private func handleScreenUnlocked() {
        log.info("DistributedNotification: screenIsUnlocked")
        isLocked = false
        lockUIVisible = false
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
        // Returning empty is safe: with the takeover off nothing in this session
        // can ever have put artwork on the desktop, so there is nothing of ours to
        // restore either. Cross-session leftovers are handled by
        // `recoverIfNeeded()` at init and by the willTerminate restore.
        guard Self.wallpaperTakeoverEnabled else { return }
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
        // A motion track's desktop belongs to the *motion* wallpaper. Putting the
        // still on the real desktop here as well raced the motion store rewrite: a
        // late setDesktopImageURL landed after WallpaperAgent respawned and knocked
        // the video back off, leaving the still frozen there. The overlay draws its
        // own blurred cover until the video is live, so nothing of ours needs to
        // touch the real desktop meanwhile — stand the still down and let motion own
        // it. Same gate the motion path activates on (feature on + animated URL).
        if SettingsStore.shared.bool(["lockscreen", "set_system_wallpaper"]), trackHasMotionArtwork {
            if lastWallpaperKey != nil { op.standDown(); lastWallpaperKey = nil }
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

    /// Whether the current track has animated artwork — the same URLs the motion
    /// wallpaper drives from, so the still knows when to yield the desktop to it.
    private var trackHasMotionArtwork: Bool {
        let a = viewModel.artwork
        return (a.animationSquareUltraURL ?? a.animationURL ?? a.animationTallURL) != nil
    }

    /// Reconcile the motion (video) wallpaper. Coupled to the enlarge/tap state
    /// like the static wallpaper: it activates only while locked AND the user has
    /// tapped the now-playing thumbnail (`isLargeArtwork`), and restores on shrink
    /// or unlock — so entering the lock screen doesn't silently replace the
    /// wallpaper before the user asks for it.
    private func syncMotionWallpaper() {
        guard Self.wallpaperTakeoverEnabled else { return }
        guard isLocked, viewModel.isLargeArtwork else {
            motionWallpaper.disableIfActive()
            return
        }
        motionWallpaper.sync(artwork: viewModel.artwork, hasTrack: playerMonitor.snapshot?.hasTrack == true)
    }

    /// Pre-render the wallpaper file while locked so the enlarge-tap swap is
    /// instant. Runs regardless of the toggle — it only writes a file, never
    /// touches the live desktop.
    private func prewarmWallpaper() {
        // Runs while the feature is *on* — it used to be guarded on the toggle
        // being off, exactly backwards, so the tap paid for the whole blur+encode
        // and the wallpaper landed seconds late. With it off nothing ever reaches
        // the desktop, so there is nothing to warm.
        guard Self.wallpaperTakeoverEnabled else { return }
        guard isLocked,
              SettingsStore.shared.bool(["lockscreen", "set_system_wallpaper"]),
              playerMonitor.snapshot?.hasTrack == true,
              let image = viewModel.artworkImage else { return }
        let blur = SettingsStore.shared.int(["lockscreen", "background_blur"])
        let key = "\(viewModel.artwork.artworkURL ?? "")|\(blur)"
        SystemWallpaperOperator.shared.prepare(image: image, blurRadius: Double(blur), key: key)
    }

    @objc private func handleLockUIShown() {
        log.info("DistributedNotification: screenLockUIIsShown — re-raising window")
        // Deliberately does NOT drive `lockUIVisible` — see its doc comment. This
        // fires right after every lock, so fading here blanked the artwork and made
        // the window click-through for the entire lock session.
        evaluateVisibility()
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
            // A rebuild can land mid-fade, so new windows inherit the state.
            playerWindow.ignoresMouseEvents = lockUIVisible && viewModel.isLargeArtwork
            SkyLightOperator.shared.promoteAboveLockScreen(playerWindow)
            playerWindow.makeKeyAndOrderFront(nil)
            playerWindows.append(playerWindow)

            log.info("Windows shown — frame:\(NSStringFromRect(screen.frame), privacy: .public)")
        }
    }

    /// Hold each screen's current desktop picture in front of it while the
    /// wallpaper store is being rewritten. That rewrite kills WallpaperAgent, and
    /// until launchd brings it back nothing draws the desktop on *any* display —
    /// which reads as every screen going black for a couple of seconds. Screens
    /// the player overlay already covers need nothing; the rest get a still of
    /// what they were showing, so the swap is invisible.
    private func setDesktopFiller(_ visible: Bool) {
        guard visible else {
            for window in fillerWindows {
                window.orderOut(nil)
                window.contentView = nil
            }
            fillerWindows.removeAll()
            return
        }
        guard isLocked, fillerWindows.isEmpty else { return }
        // Every screen, including the ones the player overlay is on: that overlay
        // is transparent wherever it isn't drawing the card, so the black shows
        // straight through it — most visibly on the way *out* of full screen,
        // where nothing of ours is covering the screen any more.
        for screen in NSScreen.screens {
            let window = LockScreenWindow(screen: screen)
            let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.imageScaling = .scaleAxesIndependently
            view.image = fillerImage(for: screen)
            window.contentView = view
            window.ignoresMouseEvents = true
            SkyLightOperator.shared.promoteAboveLockScreen(window)
            window.orderFrontRegardless()
            fillerWindows.append(window)
        }
        // Fillers went up last, so put the cards back in front of them.
        raiseAllWindows()
        log.info("desktop filler — covering \(self.fillerWindows.count) screen(s) while the store is rewritten")
    }

    /// What to hold in front of `screen` while the desktop isn't being drawn: the
    /// wallpaper it had before we took over (what a restore is about to put back),
    /// else whatever the desktop currently reports, else the artwork. Anything but
    /// nothing — the point is to not show black.
    private func fillerImage(for screen: NSScreen) -> NSImage? {
        let original = SystemWallpaperOperator.shared.originalWallpaper(for: screen)
        let current = NSWorkspace.shared.desktopImageURL(for: screen)
        return [original, current].compactMap { $0 }.compactMap { NSImage(contentsOf: $0) }.first
            ?? viewModel.artworkImage
    }

    private func dismiss() {
        setDesktopFiller(false)
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

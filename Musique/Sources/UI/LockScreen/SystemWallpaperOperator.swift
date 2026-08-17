import AppKit
import CoreImage
import os

/// Swaps the macOS desktop wallpaper to the now-playing artwork while the
/// screen is locked, then restores the user's original on unlock. The lock
/// screen renders the desktop wallpaper, so changing it is what shows the
/// artwork behind the lock UI.
///
/// Uses the supported `NSWorkspace.setDesktopImageURL(_:for:)` API — it forces
/// an immediate repaint, unlike rewriting the private wallpaper store + bouncing
/// `WallpaperAgent`, which writes the file but never re-renders.
///
/// `apply` must only ever run *while locked* (the caller enforces this) and
/// `restore` before the desktop is visible again, otherwise the artwork would
/// show on the user's real desktop. The original per-display URLs are backed up
/// to disk so a crash mid-lock is recovered on next launch instead of leaving
/// the artwork stuck as the wallpaper.
@MainActor
final class SystemWallpaperOperator {
    static let shared = SystemWallpaperOperator()

    private let log = Logger(subsystem: "com.nopxx.musique", category: "Wallpaper")
    private let fm = FileManager.default
    private let backupURL: URL
    /// Two artwork files we alternate between. `setDesktopImageURL` caches by
    /// URL and won't re-read a path it already shows, so each apply must hand it
    /// a *different* URL — hence A/B ping-pong instead of one fixed filename.
    private let artworkA: URL
    private let artworkB: URL
    /// Blur + jpeg encode run here so a large artwork doesn't stall main.
    private let renderQueue = DispatchQueue(label: "com.nopxx.musique.wallpaper")
    /// Reused — building a CIContext per render costs more than the render.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Called as the artwork wallpaper becomes (or stops being) the picture the
    /// desktop is really showing. False while WallpaperAgent is still catching up,
    /// so the lock screen can cover the gap with its own copy.
    var onLiveChange: ((Bool) -> Void)?
    private var isLive = false {
        didSet { if isLive != oldValue { onLiveChange?(isLive) } }
    }
    private var landWatch: Timer?

    /// Original desktop image URL per display, captured before the first swap.
    /// Mirrored to `backupURL` on disk for crash recovery.
    private var savedURLs: [CGDirectDisplayID: URL] = [:]

    /// Last pre-rendered wallpaper file + the key it was rendered for. Lets
    /// `apply` skip the (slow) blur+encode when the artwork is already prepared.
    private var readyURL: URL?
    private var readyKey: String?

    /// The file actually on the desktop right now (last one handed to `setAll`).
    /// The A/B pick is made against *this*, not `readyURL`: `prepare` advances
    /// `readyURL` without touching the desktop, so choosing off it could land the
    /// next apply back on the file already showing — and `setDesktopImageURL`
    /// no-ops on a repeat URL, which is why the third track's wallpaper froze.
    private var lastAppliedURL: URL?

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Musique", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        backupURL = dir.appendingPathComponent("wallpaper-backup.plist")
        artworkA = dir.appendingPathComponent("lockscreen-wallpaper-a.jpg")
        artworkB = dir.appendingPathComponent("lockscreen-wallpaper-b.jpg")
    }

    /// A backup left on disk means a previous session swapped the wallpaper but
    /// never restored it (crash / force-quit while locked). Call once at launch.
    func recoverIfNeeded() {
        guard savedURLs.isEmpty else { return }
        if let disk = loadBackup() {
            log.info("Stale wallpaper backup found — restoring user's wallpaper")
            savedURLs = disk
            restore()
            return
        }
        // No backup, but a session that died mid-swap can still have left our
        // artwork on the desktop with no record of what it replaced. Fall back to
        // the image macOS's own wallpaper store holds, so the desktop isn't
        // stranded on a blurred still forever.
        let stranded = NSScreen.screens.filter { screen in
            NSWorkspace.shared.desktopImageURL(for: screen).map(isOurArtwork) == true
        }
        guard !stranded.isEmpty else { return }
        guard let real = MotionWallpaperStore.realImageFromStore() else {
            log.error("Desktop stranded on our artwork and no backup or store image to recover from")
            return
        }
        log.info("Desktop stranded on our artwork — recovering \(stranded.count) screen(s) from the wallpaper store")
        for screen in stranded { setDesktop(real, for: screen) }
    }

    /// Pre-render the wallpaper file for `key` in the background so a later
    /// `apply(key:)` is instant. Cheap no-op if already prepared for `key`.
    /// Call while locked as the artwork lands, before the user taps.
    func prepare(image: NSImage, blurRadius: Double = 0, key: String) {
        guard key != readyKey else { return }
        render(image, blurRadius: blurRadius, key: key)
    }

    /// Set the desktop wallpaper of every screen to `image` (optionally blurred).
    /// Uses the pre-rendered file when `key` matches `prepare`, so the swap lands
    /// with the enlarge animation instead of after a blur+encode delay.
    func apply(image: NSImage, blurRadius: Double = 0, key: String) {
        // Never replace the wallpaper unless the real one is recorded — otherwise
        // a restore would have nothing to put back and the user's picture is gone.
        guard captureOriginalsIfNeeded() else {
            log.error("apply — no restorable wallpaper captured; leaving the desktop alone")
            return
        }
        if key == readyKey, let url = readyURL {
            setAll(to: url)
        } else {
            log.info("apply — nothing prepared for this artwork; rendering on the tap")
            render(image, blurRadius: blurRadius, key: key) { [weak self] url in
                self?.setAll(to: url)
            }
        }
    }

    /// Downscale → blur → jpeg-encode `image` to the next A/B file off-main, then
    /// cache it as `readyURL`/`readyKey`. `setDesktopImageURL` caches by URL and
    /// won't re-read a path it already shows, so we alternate two filenames.
    ///
    /// Scaling to the screen first is what makes this fast: artwork comes back at
    /// up to 3000², and a wide Gaussian over that many pixels — plus a full-size
    /// TIFF→bitmap→jpeg round trip — took seconds. The blur radius scales with the
    /// image, so the result looks the same. It all stays in Core Image, which
    /// writes the jpeg directly.
    private func render(_ image: NSImage, blurRadius: Double, key: String,
                        completion: ((URL) -> Void)? = nil) {
        // Alternate the two files so setDesktopImageURL — which caches by URL and
        // won't re-read a path it already shows — always sees a new path. Pick the
        // buffer that ISN'T the one currently on the desktop, so the swap can never
        // resolve to the URL already showing (a silent no-op that froze the third
        // track's wallpaper). Chosen against `lastAppliedURL`, not `readyURL`: a
        // prewarm render advances `readyURL` without changing the desktop.
        let dest = (lastAppliedURL == artworkA) ? artworkB : artworkA
        // NSScreen is main-only — read the target size before hopping off.
        let target = targetPixelSize
        renderQueue.async { [weak self] in
            guard let self else { return }
            let started = Date()
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.log.error("render — artwork has no CGImage")
                return
            }
            var ci = CIImage(cgImage: cg)
            // Crop to the screen's aspect first — macOS fills the desktop with
            // this image, so the overhang is decoded and thrown away. A square
            // 3000² artwork on a 16:10 screen is a third of the pixels wasted.
            ci = ci.cropped(to: Self.aspectFill(ci.extent, aspect: target.width / target.height))
            // Then match the screen's pixel count; never upscale.
            let scale = min(1, target.width / ci.extent.width)
            if scale < 1 {
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            if blurRadius > 0 {
                let extent = ci.extent
                let blur = CIFilter(name: "CIGaussianBlur")
                blur?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
                blur?.setValue(blurRadius * scale, forKey: kCIInputRadiusKey)
                // Clamp first so edges don't fade out, then crop back.
                if let out = blur?.outputImage { ci = out.cropped(to: extent) }
            }
            do {
                try self.ciContext.writeJPEGRepresentation(
                    of: ci, to: dest, colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
            } catch {
                self.log.error("render — jpeg write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            self.log.info("render — \(Int(ci.extent.width))×\(Int(ci.extent.height)) in \(ms)ms")
            DispatchQueue.main.async {
                self.readyURL = dest
                self.readyKey = key
                completion?(dest)
            }
        }
    }

    /// The largest centred sub-rect of `extent` with the given width/height ratio —
    /// the part of the artwork that actually ends up on screen.
    private static func aspectFill(_ extent: CGRect, aspect: CGFloat) -> CGRect {
        var size = extent.size
        if size.width / size.height > aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        return CGRect(x: extent.midX - size.width / 2, y: extent.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Backing-pixel size of the largest target screen — what the wallpaper is
    /// rendered at. Anything bigger is detail macOS throws away.
    private var targetPixelSize: CGSize {
        let screens = targetScreens.isEmpty ? NSScreen.screens : targetScreens
        return screens.reduce(CGSize(width: 1920, height: 1080)) { biggest, screen in
            let px = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)
            return px.width * px.height > biggest.width * biggest.height ? px : biggest
        }
    }

    /// The wallpaper this screen had before we touched it, when we recorded one.
    /// What the desktop will show again after a restore — so it's also the right
    /// thing to hold in front of the screen while WallpaperAgent is down.
    func originalWallpaper(for screen: NSScreen) -> URL? {
        displayID(screen).flatMap { savedURLs[$0] }
    }

    /// The motion wallpaper took the desktop over — stop tracking ours *without*
    /// putting the user's picture back, which would paint over the video. The
    /// captured originals stay, so unlock still restores.
    func standDown() {
        landWatch?.invalidate()
        landWatch = nil
        isLive = false
    }

    /// Put every display's original wallpaper back, if we changed it.
    func restore() {
        landWatch?.invalidate()
        landWatch = nil
        isLive = false
        guard !savedURLs.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let id = displayID(screen), let url = savedURLs[id] else { continue }
            setDesktop(url, for: screen)
        }
        savedURLs.removeAll()
        try? fm.removeItem(at: backupURL)
        log.info("Wallpaper restored")
    }

    // MARK: - Internals

    /// Record each display's real wallpaper before the first swap. Returns false if
    /// nothing restorable was found, in which case the caller must not swap.
    ///
    /// Screens already showing one of *our* artwork files are skipped: a session
    /// that died without restoring leaves them there, and capturing that as the
    /// "original" is how the user's real picture gets lost for good — restore then
    /// puts our own blurred artwork back forever.
    @discardableResult
    private func captureOriginalsIfNeeded() -> Bool {
        guard savedURLs.isEmpty else { return true }
        var captured: [CGDirectDisplayID: URL] = [:]
        // Only the screens we're about to change: restore writes back whatever it
        // captured, and rewriting an untouched display would replace its
        // current-Space wallpaper with the one AppKit reports for it.
        for screen in targetScreens {
            guard let id = displayID(screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            guard !isOurArtwork(url) else {
                log.error("capture — display \(id) already shows our artwork; a prior session never restored it")
                continue
            }
            captured[id] = url
        }
        guard !captured.isEmpty else { return false }
        savedURLs = captured
        writeBackup(savedURLs)
        // The still lands before the motion wallpaper does, so snapshot the
        // wallpaper store now too: a backup taken later would find our own artwork
        // on every Desktop node and fall back to the lock-screen image.
        MotionWallpaperStore.primeBackup()
        return true
    }

    /// True if `url` is a file Musique wrote (an artwork still, a staged motion
    /// clip) rather than a real user wallpaper. Whole-directory rather than just
    /// the A/B pair, so a still left by an older build — or the motion wallpaper —
    /// can't be captured as the "original" either.
    private func isOurArtwork(_ url: URL) -> Bool {
        MotionWallpaperStore.isMusiqueFile(url)
    }

    /// Screens the artwork wallpaper should cover — the same `lockscreen.screens`
    /// choice the overlay windows follow, so "main display only" doesn't still
    /// repaint every desktop.
    private var targetScreens: [NSScreen] {
        SettingsStore.shared.string(["lockscreen", "screens"]) == "all"
            ? NSScreen.screens
            : [NSScreen.main].compactMap { $0 }
    }

    private func setAll(to url: URL) {
        let started = Date()
        lastAppliedURL = url
        for screen in targetScreens { setDesktop(url, for: screen) }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let kb = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
        log.info("setDesktopImageURL — \(kb / 1024)KB in \(ms)ms")
        waitForDesktopToLand(url, since: started)
    }

    /// `setDesktopImageURL` returns in a millisecond but WallpaperAgent takes
    /// *seconds* to repaint the desktop the lock screen shows. Report the gap so
    /// the overlay can cover it with its own copy instead of leaving the old
    /// wallpaper on screen. WallpaperAgent records the picture in the wallpaper
    /// store once it's up; poll for *our file* appearing there, and give up
    /// (assume landed) after a cap so a missed write can't pin our copy over the
    /// native clock forever.
    private func waitForDesktopToLand(_ url: URL, since started: Date) {
        landWatch?.invalidate()
        let deadline = Date().addingTimeInterval(6)
        landWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let landed = MotionWallpaperStore.desktopShows(url)
                guard landed || Date() > deadline else { return }
                timer.invalidate()
                self.landWatch = nil
                self.log.info("desktop wallpaper landed after \(Int(Date().timeIntervalSince(started) * 1000))ms\(landed ? "" : " (timed out — assuming it did)")")
                self.isLive = true
            }
        }
    }

    private func setDesktop(_ url: URL, for screen: NSScreen) {
        do {
            try NSWorkspace.shared.setDesktopImageURL(
                url, for: screen, options: MotionWallpaperStore.fillScreenOptions)
        } catch {
            log.error("setDesktopImageURL failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // Backup is a plain [displayID: fileURLString] plist.
    private func writeBackup(_ map: [CGDirectDisplayID: URL]) {
        let plain = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value.absoluteString) })
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plain, format: .binary, options: 0) else { return }
        try? data.write(to: backupURL)
    }

    private func loadBackup() -> [CGDirectDisplayID: URL]? {
        guard let data = try? Data(contentsOf: backupURL),
              let plain = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: String] else { return nil }
        var map: [CGDirectDisplayID: URL] = [:]
        for (k, v) in plain {
            if let id = CGDirectDisplayID(k), let url = URL(string: v) { map[id] = url }
        }
        return map.isEmpty ? nil : map
    }
}

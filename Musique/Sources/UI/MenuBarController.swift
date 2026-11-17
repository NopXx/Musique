import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let playerMonitor: PlayerMonitor
    private let viewModel: MiniPlayerViewModel
    private let animationFullscreenController: AnimationFullscreenController
    private let desktopFullscreenController: DesktopFullscreenController
    private let desktopMiniPlayerController: DesktopMiniPlayerController
    private var cancellables = Set<AnyCancellable>()

    private var dynamicIslandModel: MenuBarDynamicIslandModel?
    private var islandCancellable: AnyCancellable?
    /// Where the play/pause glyph sits in the current island image (top-left
    /// origin); `.zero` when it isn't drawn.
    private var islandPlayRect: CGRect = .zero
    private var rightClickMonitors: [Any] = []
    private var lastRightClickAt: TimeInterval = 0
    private var currentStyle: String = ""

    init(playerMonitor: PlayerMonitor, scrobbler: ScrobblerService) {
        self.playerMonitor = playerMonitor
        self.viewModel = MiniPlayerViewModel(monitor: playerMonitor, scrobbler: scrobbler)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.animationFullscreenController = AnimationFullscreenController(viewModel: self.viewModel)
        self.desktopFullscreenController = DesktopFullscreenController(viewModel: self.viewModel)
        self.desktopMiniPlayerController = DesktopMiniPlayerController(viewModel: self.viewModel)
        self.popover.behavior = .transient
        self.popover.contentSize = NSSize(width: 320, height: 505)
        self.popover.contentViewController = NSHostingController(rootView: MiniPlayerView(viewModel: viewModel))

        // Left-click opens the popover via the button action (only left-mouse
        // events are delivered to a status button on macOS 26+).
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleButtonClick)
            button.sendAction(on: [.leftMouseUp])
        }
        // Right-click is handled by an event monitor (the button action never
        // receives right-mouse events). See installRightClickMonitor().
        installRightClickMonitor()

        playerMonitor.$snapshot
            .combineLatest(EditHistoryService.shared.$rules)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] raw, _ in
                let edited = raw.map { EditHistoryService.shared.apply($0) }
                self?.updateTitle(edited)
            }
            .store(in: &cancellables)

        SettingsStore.shared.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyStyle()
                self?.updateTitle(self?.currentEditedSnap())
                self?.renderIsland()
            }
            .store(in: &cancellables)

        applyStyle()
        updateTitle(currentEditedSnap())
    }

    private func currentEditedSnap() -> NowPlayingSnapshot? {
        playerMonitor.snapshot.map { EditHistoryService.shared.apply($0) }
    }

    private func applyStyle() {
        let style = SettingsStore.shared.string(["menubar", "style"])
        let resolved = style.isEmpty ? "text" : style
        if resolved == currentStyle { return }
        currentStyle = resolved

        guard let button = statusItem.button else { return }

        islandCancellable = nil
        dynamicIslandModel = nil
        islandPlayRect = .zero
        button.image = nil

        if resolved == "dynamic_island" {
            MusicAudioLevelMonitor.shared.start()
            let model = MenuBarDynamicIslandModel(monitor: playerMonitor)
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            self.dynamicIslandModel = model
            // objectWillChange fires before the value lands; hop a turn to read it.
            islandCancellable = model.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.renderIsland() }
            renderIsland()
        } else {
            button.imagePosition = .noImage   // .imageOnly would hide the text title
        }
        statusItem.length = NSStatusItem.variableLength
    }

    private func renderIsland() {
        guard let model = dynamicIslandModel, let button = statusItem.button else { return }
        let (image, playRect) = MenuBarIslandRenderer.render(
            snapshot: model.snapshot, artwork: model.artwork, accent: model.accent,
            bands: model.bands, showState: SettingsStore.shared.bool(["menubar", "show_state"]))
        button.image = image
        islandPlayRect = playRect
    }

    private func updateTitle(_ snap: NowPlayingSnapshot?) {
        guard currentStyle == "text" else { return }
        guard let button = statusItem.button else { return }
        let s = SettingsStore.shared
        let showIcon   = s.bool(["menubar", "show_icon"])
        let showTrack  = s.bool(["menubar", "show_track"])
        let showArtist = s.bool(["menubar", "show_artist"])
        let showState  = s.bool(["menubar", "show_state"])
        let maxLength  = max(8, s.int(["menubar", "max_length"]))

        var parts: [String] = []
        if showIcon { parts.append("♪") }

        if let snap, snap.hasTrack {
            if showState { parts.append(snap.isPlaying ? "▶" : "❙❙") }
            var info: [String] = []
            if showTrack { info.append(snap.title) }
            if showArtist { info.append(snap.artist) }
            let infoStr = info.joined(separator: " — ")
            if !infoStr.isEmpty { parts.append(infoStr) }
        } else if !showIcon {
            parts.append("Musique")
        }

        var label = parts.joined(separator: " ")
        if label.isEmpty { label = "♪ Musique" }
        if label.count > maxLength {
            label = String(label.prefix(maxLength)) + "…"
        }
        button.title = label
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let desktop = NSMenuItem(title: L10n.miniplayerDesktopEnabled,
                                 action: #selector(toggleDesktopMiniPlayerAction), keyEquivalent: "")
        desktop.target = self
        desktop.state = desktopMiniPlayerController.isEnabled ? .on : .off
        menu.addItem(desktop)

        let settings = NSMenuItem(title: L10n.tr("ตั้งค่า…", "Settings…"),
                                  action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.tr("ออกจาก Musique", "Quit Musique"),
                              action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Driven by the mini player's fullscreen button and `musique://fullscreen`.
    func toggleDesktopFullscreen() {
        desktopFullscreenController.toggle()
    }

    var desktopFullscreenPresented: Bool { desktopFullscreenController.isPresented }

    @objc private func handleButtonClick() {
        // In dynamic-island style, a left-click landing on the play/pause icon
        // toggles playback; clicks anywhere else on the pill open the popover.
        if currentStyle == "dynamic_island",
           let button = statusItem.button,
           handleIslandClick(in: button) {
            return
        }
        showPopover()
    }

    /// Toggle the mini-player popover (left-click).
    private func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Right-click handling

    private func installRightClickMonitor() {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseUp]) { [weak self] event in
            self?.handleRightMouse(event)
            return event
        }
        if let local { rightClickMonitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseUp]) { [weak self] event in
            self?.handleRightMouse(event)
        }
        if let global { rightClickMonitors.append(global) }
    }

    private func handleRightMouse(_ event: NSEvent) {
        guard let button = statusItem.button, let window = button.window else { return }

        // The same physical right-click can be reported by both the local and the
        // global monitor. Debounce on the (monotonic) event timestamp so the menu
        // is shown only once per click.
        if event.timestamp - lastRightClickAt < 0.3 { return }

        // Is the right-click over our status item? `event.window` is set for the
        // local monitor (event delivered to us); for the global monitor compare
        // the screen-space mouse location against the button's on-screen frame.
        let hit: Bool
        if event.window === window {
            hit = true
        } else {
            let frameInWindow = button.convert(button.bounds, to: nil)
            let frameOnScreen = window.convertToScreen(frameInWindow)
            hit = frameOnScreen.contains(NSEvent.mouseLocation)
        }
        guard hit else { return }

        lastRightClickAt = event.timestamp
        showStatusMenu(button)
    }

    private func showStatusMenu(_ button: NSStatusBarButton) {
        // Opened on rightMouseUp, not down: a menu opened on mouse-down is closed
        // by that same click's mouse-up. Async: leave the monitor callback before
        // the menu's tracking loop starts.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.buildContextMenu().popUp(positioning: nil,
                                          at: NSPoint(x: 0, y: button.bounds.height + 4),
                                          in: button)
        }
    }

    @objc private func toggleDesktopMiniPlayerAction() {
        desktopMiniPlayerController.toggle()
    }

    @objc private func openSettingsAction() {
        AppDelegate.shared?.openSettings()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    /// Hit-test the play/pause glyph against where the renderer drew it.
    private func handleIslandClick(in button: NSStatusBarButton) -> Bool {
        guard islandPlayRect != .zero, let window = button.window, let image = button.image else { return false }

        // `NSApp.currentEvent.locationInWindow` from a status-button action is
        // always the button centre, not the real click — so use the live cursor.
        let inButton = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        // The image is centred in the button; map the click into image space
        // (top-left origin, like the renderer).
        let origin = CGPoint(x: (button.bounds.width - image.size.width) / 2,
                             y: (button.bounds.height - image.size.height) / 2)
        let y = button.isFlipped ? inButton.y - origin.y
                                 : button.bounds.height - inButton.y - origin.y
        let point = CGPoint(x: inButton.x - origin.x, y: y)

        // Pad the hit target slightly so the small icon stays comfortably tappable.
        if islandPlayRect.insetBy(dx: -6, dy: -6).contains(point) {
            MusicAppController.playPause()
            return true
        }
        return false
    }
}


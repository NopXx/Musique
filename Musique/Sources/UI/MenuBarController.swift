import AppKit
import SwiftUI
import Combine

/// A hosting view that is transparent to hit-testing so the underlying
/// `NSStatusBarButton` receives the click (which opens the status item's menu).
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let playerMonitor: PlayerMonitor
    private let viewModel: MiniPlayerViewModel
    private let animationFullscreenController: AnimationFullscreenController
    private let desktopFullscreenController: DesktopFullscreenController
    private var cancellables = Set<AnyCancellable>()

    private var dynamicIslandModel: MenuBarDynamicIslandModel?
    private var hostingView: PassthroughHostingView<MenuBarDynamicIslandView>?
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

        hostingView?.removeFromSuperview()
        hostingView = nil
        dynamicIslandModel = nil

        if resolved == "dynamic_island" {
            MusicAudioLevelMonitor.shared.start()
            let model = MenuBarDynamicIslandModel(monitor: playerMonitor)
            let host = PassthroughHostingView(rootView: MenuBarDynamicIslandView(model: model))
            host.translatesAutoresizingMaskIntoConstraints = false
            button.title = ""
            button.image = nil
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                host.topAnchor.constraint(equalTo: button.topAnchor),
                host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            self.dynamicIslandModel = model
            self.hostingView = host
            statusItem.length = NSStatusItem.variableLength
        } else {
            statusItem.length = NSStatusItem.variableLength
        }
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
        let local = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            self?.handleRightMouse(event)
            return event
        }
        if let local { rightClickMonitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
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
        let menu = buildContextMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func openSettingsAction() {
        AppDelegate.shared?.openSettings()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    /// Hit-test the play/pause icon using its real rendered frame (reported by the
    /// SwiftUI layout in window coordinates) instead of hard-coded pixel offsets.
    /// macOS 26 changed status-item geometry, which broke the old fixed-offset math.
    private func handleIslandClick(in button: NSStatusBarButton) -> Bool {
        guard SettingsStore.shared.bool(["menubar", "show_state"]) else { return false }
        guard let iconFrame = dynamicIslandModel?.iconFrame, iconFrame != .zero else { return false }
        guard let window = button.window else { return false }

        // `NSApp.currentEvent.locationInWindow` from a status-button action is
        // always the button centre, not the real click — so use the live cursor
        // position (`NSEvent.mouseLocation`, screen space, bottom-left origin).
        // Map it into the window, then flip to top-left to match `iconFrame`
        // (reported by SwiftUI's `.frame(in: .global)`).
        let mouse = NSEvent.mouseLocation
        let localX = mouse.x - window.frame.origin.x
        let localY = mouse.y - window.frame.origin.y
        let point = CGPoint(x: localX, y: window.frame.height - localY)

        // Pad the hit target slightly so the small icon stays comfortably tappable.
        if iconFrame.insetBy(dx: -6, dy: -6).contains(point) {
            MusicAppController.playPause()
            return true
        }
        return false
    }
}


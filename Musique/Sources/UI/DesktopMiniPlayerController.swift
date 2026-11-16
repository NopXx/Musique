import AppKit
import SwiftUI
import Combine

/// The mini player as a free-standing panel on the desktop, apart from the
/// menu bar popover, on the same view model. Driven entirely by
/// `miniplayer.desktop_enabled` / `desktop_level` / `desktop_style` — the style
/// picks the square `DesktopPlayerView` card, the `DesktopCompactPlayerView` glass
/// bar, or the popover's own `MiniPlayerView`.
@MainActor
final class DesktopMiniPlayerController {
    /// Borderless panels refuse key by default; the edit overlay's text fields need it.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let viewModel: MiniPlayerViewModel
    private var panel: NSPanel?
    private var style = ""
    /// How far the window grew to the left for the card's lyrics panel, so it
    /// shrinks back from that side and a design switch starts where the card is.
    private var leftGrowth: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: MiniPlayerViewModel) {
        self.viewModel = viewModel
        SettingsStore.shared.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    var isEnabled: Bool { SettingsStore.shared.bool(["miniplayer", "desktop_enabled"]) }

    func toggle() {
        SettingsStore.shared.merge(["miniplayer": ["desktop_enabled": !isEnabled]])
    }

    private func sync() {
        guard isEnabled else {
            panel?.close()
            panel = nil
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let raw = SettingsStore.shared.string(["miniplayer", "desktop_style"])
        let wanted = raw.isEmpty ? "card" : raw  // never "", or a fresh panel would stay empty
        if wanted != style { applyStyle(wanted, to: panel) }
        panel.level = Self.level(SettingsStore.shared.string(["miniplayer", "desktop_level"]))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func level(_ raw: String) -> NSWindow.Level {
        switch raw {
        // One above the icons: at the icon level itself Finder's desktop takes the clicks.
        case "desktop": return NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case "normal":  return .normal
        default:        return .floating
        }
    }

    private static let autosaveName = "MusiqueDesktopPlayer"

    private func makePanel() -> NSPanel {
        let size = NSSize(width: DesktopPlayerView.size, height: DesktopPlayerView.size)
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Only the origin matters from here: `applyStyle` sets the size, keeping the top edge.
        if !panel.setFrameUsingName(Self.autosaveName),
           let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24,
                                         y: visible.maxY - size.height - 24))
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    private func applyStyle(_ raw: String, to panel: NSPanel) {
        style = raw
        let root: AnyView
        let size: NSSize
        if raw == "classic" {
            root = AnyView(MiniPlayerView(viewModel: viewModel, onDesktop: true)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            size = NSSize(width: 320, height: 505)
        } else if raw == "compact" {
            size = NSSize(width: DesktopCompactPlayerView.width, height: DesktopCompactPlayerView.height)
            root = AnyView(DesktopCompactPlayerView(
                viewModel: viewModel,
                onLyricsShown: lyricsResizer(panel, style: raw, base: size,
                                             extra: NSSize(width: 0,
                                                           height: DesktopCompactPlayerView.lyricsHeight))))
        } else {
            size = NSSize(width: DesktopPlayerView.size, height: DesktopPlayerView.size)
            root = AnyView(DesktopPlayerView(
                viewModel: viewModel,
                onLyricsShown: lyricsResizer(panel, style: raw, base: size,
                                             extra: NSSize(width: DesktopPlayerView.lyricsWidth,
                                                           height: 0))))
        }
        // SwiftUI swallows background drags, so isMovableByWindowBackground alone
        // never fires; buttons and the seek bar still win over this.
        // This controller owns the window size. A hosting view that *is* the
        // window's content view pushes its min/max size onto the window on every
        // update — `sizingOptions = []` didn't stop that — and with the lyrics
        // column updating every frame and the strip growing and shrinking, AppKit
        // threw on the constraint-pass loop. Inside a plain autoresizing container
        // it's just a subview and leaves the window alone.
        let host = NSHostingView(rootView: root.gesture(WindowDragGesture()))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        container.addSubview(host)
        // Read the corner first, so the content swap can't move the top edge.
        let topLeft = NSPoint(x: panel.frame.minX + leftGrowth, y: panel.frame.maxY)
        leftGrowth = 0
        panel.contentView = container
        place(panel, topLeft: topLeft, size: size)
    }

    /// Grows the window by the lyrics area and back, for the style that asked —
    /// downward for the glass bar, sideways for the card. The player never moves
    /// on screen: the card grows right, or left when the right has no room, and
    /// the returned flag tells the view which side its panel goes on.
    private func lyricsResizer(_ panel: NSPanel, style raw: String, base: NSSize,
                               extra: NSSize) -> (Bool) -> Bool {
        { [weak self, weak panel] on in
            guard let self, let panel else { return false }
            var growLeft = false
            if on, extra.width > 0, self.leftGrowth == 0,
               let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
                growLeft = panel.frame.minX + base.width + extra.width > visible.maxX
            }
            if on, self.leftGrowth > 0 { growLeft = true }  // already open on the left
            // Next turn of the run loop: this fires inside a SwiftUI update, and
            // resizing the window there re-enters layout (AppKit logs it).
            DispatchQueue.main.async {
                guard self.style == raw else { return }
                let size = NSSize(width: base.width + (on ? extra.width : 0),
                                  height: base.height + (on ? extra.height : 0))
                // Keep the card's own left edge where it is on screen.
                let cardX = panel.frame.minX + self.leftGrowth
                self.leftGrowth = growLeft ? extra.width : 0
                self.place(panel, topLeft: NSPoint(x: cardX - self.leftGrowth,
                                                   y: panel.frame.maxY), size: size)
            }
            return growLeft
        }
    }

    private func place(_ panel: NSPanel, topLeft: NSPoint, size: NSSize) {
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height,
                           width: size.width, height: size.height)
        // A saved spot on a display that's gone (or a bad frame from before) — back
        // to the top-right corner of the main screen rather than nowhere.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }),
           let visible = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: visible.maxX - size.width - 24,
                                   y: visible.maxY - size.height - 24)
        }
        guard frame != panel.frame else { return }
        // Lay SwiftUI out before and right after the move, so the window never
        // shows a frame of the old layout at the new origin — growing left, the
        // card jumped by the panel's width and slid back.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.display()
    }
}

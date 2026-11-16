import AppKit
import SwiftUI
import Combine

/// The mini player as a free-standing panel on the desktop, apart from the
/// menu bar popover, on the same view model. Driven entirely by
/// `miniplayer.desktop_enabled` / `desktop_level` / `desktop_style` — the style
/// picks the square `DesktopPlayerView` card or the popover's own `MiniPlayerView`.
@MainActor
final class DesktopMiniPlayerController {
    /// Borderless panels refuse key by default; the edit overlay's text fields need it.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let viewModel: MiniPlayerViewModel
    private var panel: NSPanel?
    private var style = ""
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
            root = AnyView(MiniPlayerView(viewModel: viewModel)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            size = NSSize(width: 320, height: 505)
        } else {
            root = AnyView(DesktopPlayerView(viewModel: viewModel) { [weak self, weak panel] on in
                // Next turn of the run loop: this fires inside a SwiftUI update, and
                // resizing the window there re-enters layout (AppKit logs it).
                DispatchQueue.main.async {
                    guard let self, let panel, self.style != "classic" else { return }
                    let extra = on ? DesktopPlayerView.lyricsHeight : 0
                    self.resize(panel, to: NSSize(width: DesktopPlayerView.size,
                                                  height: DesktopPlayerView.size + extra))
                }
            })
            size = NSSize(width: DesktopPlayerView.size, height: DesktopPlayerView.size)
        }
        // SwiftUI swallows background drags, so isMovableByWindowBackground alone
        // never fires; buttons and the seek bar still win over this.
        let host = NSHostingController(rootView: root.gesture(WindowDragGesture()))
        host.sizingOptions = []  // the controller owns the window size (lyrics strip grows it)
        // Read the corner first: assigning a content view controller resizes the
        // window to that view's (still empty) size, and a top edge read after it
        // put the panel somewhere off screen.
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.contentViewController = host
        place(panel, topLeft: topLeft, size: size)
    }

    /// Resizes keeping the top edge put, so the lyrics strip grows downward.
    private func resize(_ panel: NSPanel, to size: NSSize) {
        place(panel, topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY), size: size)
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
        panel.setFrame(frame, display: true)
    }
}

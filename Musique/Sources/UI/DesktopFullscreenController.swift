import AppKit
import SwiftUI
import OSLog

/// Fullscreen artwork as a *desktop of its own*: a native-fullscreen window, so
/// macOS gives it a Space the user can swipe away from while the clip keeps
/// playing. That Space is the point of the mode — the mini player's
/// tap-the-artwork route (`AnimationFullscreenController`) stays a floating
/// window over the current desktop.
///
/// The price of the Space is the notch: macOS parks a fullscreen window below it
/// (frame lands at y = -39) and paints that strip itself, so no safe-area
/// opt-out reaches it — verified by giving the window a red background and
/// watching the strip stay black. Only a window above `.mainMenu` gets those
/// pixels, and such a window can't have a Space.
///
/// Same view as the tap-the-artwork overlay, so the two can't drift.
@MainActor
final class DesktopFullscreenController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: MiniPlayerViewModel
    private let log = Logger(subsystem: "com.nopxx.musique", category: "DesktopFullscreen")

    var isPresented: Bool { window != nil }

    init(viewModel: MiniPlayerViewModel) {
        self.viewModel = viewModel
    }

    func toggle() {
        isPresented ? dismiss() : present()
    }

    private func present() {
        // The screen the user is on — the one under the pointer that just hit the
        // button. `NSScreen.main` is the *focused* screen, which is whatever was
        // clicked last and not necessarily where the mini player is.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard window == nil, let screen else { return }

        // Titled, not borderless: a borderless window can't enter native
        // fullscreen and can't become key (which would kill Esc).
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // AppKit still hairlines the bottom of the titlebar on a .titled window,
        // which draws a line straight across the artwork under the top controls.
        win.titlebarSeparatorStyle = .none
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.hasShadow = false
        win.animationBehavior = .none
        // No `.canJoinAllSpaces` — a window that lives on every Space is the
        // opposite of one that owns its own.
        win.collectionBehavior = [.fullScreenPrimary]
        win.delegate = self

        let rootView = AnimationFullscreenView(viewModel: viewModel) { [weak self] in
            self?.dismiss()
        }
        let host = NSHostingController(rootView: rootView)
        host.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        win.contentViewController = host

        // contentRect is a *content* rect: AppKit adds the titlebar on top of it
        // and fullscreen keeps that origin, leaving an extra strip of black where
        // the titlebar hung off-screen. Set the frame rect to the screen instead.
        win.setFrame(screen.frame, display: false)
        self.window = win

        // An .accessory app doesn't reliably get a fullscreen Space; go .regular
        // for as long as the window is up and hand the policy back on close.
        AppDelegate.setRegularPolicyForFullscreen()
        win.makeKeyAndOrderFront(nil)
        win.toggleFullScreen(nil)

        LockScreenController.shared?.setFullscreenAnimationActive(true)
        log.info("present — screen:\(String(describing: screen.frame)) hasTrack:\(self.viewModel.snapshot?.hasTrack == true)")
    }

    private func dismiss() {
        guard let win = window else { return }
        // Closing a window that is still fullscreen leaves its Space behind as a
        // black one. Drop out first, close in windowDidExitFullScreen.
        if win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        } else {
            win.close()
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // macOS enters fullscreen keeping the pre-fullscreen origin, which lands
        // the window 39pt low on a notched display. Push it back onto the screen.
        guard let win = window, let f = win.screen?.frame else { return }
        if win.frame != f { win.setFrame(f, display: true) }
        log.info("didEnterFullScreen — window:\(String(describing: win.frame)) screen:\(String(describing: f))")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        LockScreenController.shared?.setFullscreenAnimationActive(false)
        AppDelegate.applyDockVisibility()
    }
}

import AppKit
import SwiftUI
import Combine

@MainActor
final class AnimationFullscreenController {
    private var window: NSWindow?
    private let viewModel: MiniPlayerViewModel
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: MiniPlayerViewModel) {
        self.viewModel = viewModel

        viewModel.$showFullscreenAnimation
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] show in
                show ? self?.present() : self?.dismiss()
            }
            .store(in: &cancellables)
    }

    deinit {
        guard let win = window else { return }
        win.orderOut(nil)
        win.contentViewController = nil
        self.window = nil
    }

    private func present() {
        guard window == nil else { return }
        guard let screen = NSScreen.main else { return }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.isOpaque = false
        win.alphaValue = 0
        win.backgroundColor = .clear
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.hasShadow = false
        win.isMovable = false
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.animationBehavior = .none

        let rootView = AnimationFullscreenView(viewModel: viewModel, dismissOnTap: true) { [weak self] in
            self?.viewModel.showFullscreenAnimation = false
        }
        let host = NSHostingController(rootView: rootView)
        host.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        win.contentViewController = host
        win.setFrame(screen.frame, display: true)
        win.makeKeyAndOrderFront(nil)
        self.window = win

        LockScreenController.shared?.setFullscreenAnimationActive(true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard let win = window else { return }
        self.window = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
        }, completionHandler: {
            LockScreenController.shared?.setFullscreenAnimationActive(false)
            win.orderOut(nil)
            win.contentViewController = nil
        })
    }
}
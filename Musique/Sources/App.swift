import SwiftUI
import AppKit

@main
struct MusiqueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private(set) var menuBarController: MenuBarController?
    private(set) var lockScreenController: LockScreenController?
    let playerMonitor = PlayerMonitor()
    let scrobbler = ScrobblerService()
    let nowPlaying = NowPlayingService()
    private(set) var settingsWindow = SettingsWindowController()

    /// Show or hide the Dock icon. The app ships as `LSUIElement`, which also
    /// keeps it out of the Force Quit list and the app switcher; `.regular` puts
    /// it in all three. Safe to call repeatedly — setting the policy it already
    /// has is a no-op.
    static func applyDockVisibility() {
        let showInDock = SettingsStore.shared.bool(["general", "show_in_dock"])
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        // Becoming .regular from an agent doesn't bring the app forward on its
        // own, which leaves the new Dock icon looking inert until it's clicked.
        if showInDock { NSApp.activate() }
    }

    /// Native fullscreen from an `.accessory` app is unreliable — go `.regular`
    /// while the desktop fullscreen window is up. `applyDockVisibility()` puts
    /// the policy back from the setting when it closes, so nothing to remember.
    static func setRegularPolicyForFullscreen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        AppDelegate.applyDockVisibility()
        scrobbler.attach(monitor: playerMonitor)
        nowPlaying.attach(monitor: playerMonitor)
        NotificationService.shared.attach(monitor: playerMonitor, scrobbler: scrobbler)
        WebhookDispatcher.shared.attach(monitor: playerMonitor, scrobbler: scrobbler)
        HistoryRecorder.shared.attach(monitor: playerMonitor, scrobbler: scrobbler)
        PendingScrobbleQueue.shared.start()
        DebugServer.shared.attach(monitor: playerMonitor)
        if SettingsStore.shared.bool(["debug", "server_enabled"]) {
            let port = UInt16(SettingsStore.shared.int(["debug", "server_port"]))
            DebugServer.shared.start(port: port == 0 ? 8765 : port)
        }
        menuBarController = MenuBarController(playerMonitor: playerMonitor, scrobbler: scrobbler)
        lockScreenController = LockScreenController(playerMonitor: playerMonitor)
        playerMonitor.start()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleWidgetCommand(_:)),
            name: NSNotification.Name("com.nopxx.musique.WidgetCommand"),
            object: nil
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        handleURL(url)
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "musique" else { return }
        guard let host = url.host else { return }
        executeCommand(host)
    }

    @objc private func handleWidgetCommand(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        executeCommand(command)
    }

    private func executeCommand(_ command: String) {
        switch command {
        case "play":       MusicAppController.play()
        case "pause":      MusicAppController.pause()
        case "playpause":  MusicAppController.playPause()
        case "next":       MusicAppController.next()
        case "previous":   MusicAppController.previous()
        case "fullscreen": menuBarController?.toggleDesktopFullscreen()
        default: break
        }
        playerMonitor.refresh()
    }

    func openSettings() { settingsWindow.show() }
}

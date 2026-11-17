import Foundation
import UserNotifications
import Combine
import AppKit

@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()
    /// A notification carrying this in `userInfo` opens that URL when clicked.
    nonisolated static let openURLKey = "open_url"

    private let settings = SettingsStore.shared
    private weak var monitor: PlayerMonitor?
    private weak var scrobbler: ScrobblerService?
    private var cancellables = Set<AnyCancellable>()

    private var lastNotifiedTrackKey: String = ""
    private var lastNotifiedScrobbleKey: String = ""
    private var authorized: Bool = false

    func attach(monitor: PlayerMonitor, scrobbler: ScrobblerService) {
        self.monitor = monitor
        self.scrobbler = scrobbler

        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationIfNeeded()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAuthorizationStatus()
        }

        monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in self?.handleSnapshot(snap) }
            .store(in: &cancellables)

        scrobbler.$hasScrobbled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scrobbled in
                guard scrobbled else { return }
                self?.handleScrobble()
            }
            .store(in: &cancellables)
    }

    private func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] s in
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in self?.authorized = true }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self?.authorized = granted }
                }
            default:
                Task { @MainActor in self?.authorized = false }
            }
        }
    }

    /// Returns the current authorization state. If status is `.notDetermined`, prompts the
    /// user; if `.denied`, returns false so the caller can surface a message.
    func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            self.authorized = true
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            self.authorized = granted
            return granted
        default:
            self.authorized = false
            return false
        }
    }

    private func enabled() -> Bool {
        authorized && settings.bool(["notifications", "enabled"])
    }

    private func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let ok: Bool
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: ok = true
            default: ok = false
            }
            Task { @MainActor in self?.authorized = ok }
        }
    }

    private func handleSnapshot(_ snap: NowPlayingSnapshot?) {
        guard enabled(), settings.bool(["notifications", "on_play"]) else { return }
        guard let snap, snap.hasTrack, snap.isPlaying else { return }
        // Skip transitional snapshots from Music.app where fields update
        // out-of-sync during a track switch.
        guard !snap.artist.isEmpty else { return }
        let edited = EditHistoryService.shared.apply(snap)
        let key = trackKey(edited)
        guard key != lastNotifiedTrackKey else { return }
        lastNotifiedTrackKey = key
        Task { await postNotification(id: "play-\(key)",
                                      title: edited.title,
                                      subtitle: edited.artist,
                                      body: edited.album,
                                      artworkLookup: (edited.title, edited.artist, edited.album)) }
    }

    private func handleScrobble() {
        guard enabled(), settings.bool(["notifications", "on_scrobble"]) else { return }
        guard let snap = monitor?.snapshot, snap.hasTrack else { return }
        let edited = EditHistoryService.shared.apply(snap)
        let key = trackKey(edited)
        guard key != lastNotifiedScrobbleKey else { return }
        lastNotifiedScrobbleKey = key
        Task { await postNotification(id: "scrobble-\(key)",
                                      title: "Scrobbled to Last.fm",
                                      subtitle: edited.title,
                                      body: edited.artist,
                                      artworkLookup: (edited.title, edited.artist, edited.album)) }
    }

    private func postNotification(id: String, title: String, subtitle: String, body: String,
                                  artworkLookup: (String, String, String)?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if !body.isEmpty { content.body = body }
        content.sound = nil

        if let (t, a, alb) = artworkLookup,
           let attachment = await artworkAttachment(title: t, artist: a, album: alb) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(request) }
        catch { NSLog("[Notifications] add error: \(error.localizedDescription)") }
    }

    private func artworkAttachment(title: String, artist: String, album: String) async -> UNNotificationAttachment? {
        let result = await ArtworkService.shared.lookup(title: title, artist: artist, album: album)
        guard let urlString = result.artworkURL ?? result.artworkUltraURL,
              let url = URL(string: urlString) else {
            NSLog("[Notifications] no artwork URL for \(title) - \(artist)")
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:]) else {
                NSLog("[Notifications] cannot decode artwork (\(data.count) bytes) from \(urlString)")
                return nil
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MusiqueNotificationArtwork", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("\(UUID().uuidString).png")
            try pngData.write(to: fileURL, options: .atomic)
            return try UNNotificationAttachment(identifier: "artwork", url: fileURL,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"])
        } catch {
            NSLog("[Notifications] artwork attachment error: \(error.localizedDescription)")
            return nil
        }
    }

    private func trackKey(_ snap: NowPlayingSnapshot) -> String {
        "\(snap.persistentID)|\(snap.title)|\(snap.artist)|\(snap.album)".lowercased()
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo[Self.openURLKey] as? String,
           let url = URL(string: s) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}

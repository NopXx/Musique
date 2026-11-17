import AppKit
import UserNotifications

/// Checks GitHub for a newer release of Musique. At most once a day in the
/// background (`updates.auto_check`; the last check's time is saved, so
/// relaunching doesn't check again), posting a notification once per new version, and on
/// demand from the menu bar or Settings, answering with an alert either way.
/// Nothing is downloaded or installed: the release page opens in the browser,
/// since the DMG is signed for development and not notarized.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    /// The latest release, set only when it's newer than this build.
    @Published private(set) var available: Release?
    @Published private(set) var checking = false

    private static let latestURL = URL(string: "https://api.github.com/repos/NopXx/Musique/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private let settings = SettingsStore.shared
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() { schedule() }

    /// Fires when a day has passed since the last check — a few seconds after
    /// launch at the earliest, so nothing at startup waits on GitHub.
    private func schedule() {
        let last = TimeInterval(settings.int(["updates", "last_check"]))
        let wait = max(10, last + Self.interval - Date().timeIntervalSince1970)
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.bool(["updates", "auto_check"]) {
                    await self.check(userInitiated: false)
                } else {
                    self.markChecked()  // off: just look again tomorrow
                }
                self.schedule()
            }
        }
    }

    private func markChecked() {
        settings.merge(["updates": ["last_check": Int(Date().timeIntervalSince1970)]])
    }

    /// `userInitiated` answers with an alert whatever the outcome; a background
    /// check stays silent unless there's a version it hasn't announced yet.
    func check(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let release: Release
        do {
            var request = URLRequest(url: Self.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Musique/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            release = try JSONDecoder().decode(Release.self, from: data)
            markChecked()
        } catch {
            // A failed background check counts too, or a day offline would retry every launch.
            if !userInitiated { markChecked() }
            NSLog("[Update] check failed: \(error.localizedDescription)")
            if userInitiated {
                alert(L10n.tr("ตรวจสอบอัปเดตไม่สำเร็จ", "Couldn't check for updates"),
                      error.localizedDescription)
            }
            return
        }

        let newer = Self.isNewer(release.version, than: Self.currentVersion)
        available = newer ? release : nil

        if userInitiated {
            if newer { offer(release) } else {
                alert(L10n.tr("Musique เป็นเวอร์ชันล่าสุดแล้ว", "Musique is up to date"),
                      L10n.tr("เวอร์ชัน \(Self.currentVersion)", "Version \(Self.currentVersion)"))
            }
        } else if newer, settings.string(["updates", "notified_version"]) != release.version {
            settings.merge(["updates": ["notified_version": release.version]])
            await notify(release)
        }
    }

    func openReleasePage() {
        if let available { NSWorkspace.shared.open(available.htmlURL) }
    }

    /// Dotted numeric comparison: "1.10.0" is newer than "1.9.2", "1.5" equals "1.5.0".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func notify(_ release: Release) async {
        guard await NotificationService.shared.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("มี Musique เวอร์ชันใหม่", "A new version of Musique is available")
        content.body = L10n.tr("\(release.version) พร้อมแล้ว (ใช้อยู่ \(Self.currentVersion)) คลิกเพื่อดาวน์โหลด",
                               "\(release.version) is out (you have \(Self.currentVersion)). Click to download.")
        content.userInfo = [NotificationService.openURLKey: release.htmlURL.absoluteString]
        let request = UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func offer(_ release: Release) {
        let a = NSAlert()
        a.messageText = L10n.tr("มี Musique \(release.version) แล้ว", "Musique \(release.version) is available")
        a.informativeText = L10n.tr("ใช้อยู่ \(Self.currentVersion)", "You have \(Self.currentVersion).")
        a.addButton(withTitle: L10n.tr("ดาวน์โหลด", "Download"))
        a.addButton(withTitle: L10n.tr("ไว้ทีหลัง", "Later"))
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}

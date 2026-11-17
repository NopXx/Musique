import AppKit
import UserNotifications

/// Checks GitHub for a newer release of Musique. At most once a day in the
/// background (`updates.auto_check`; the last check's time is saved, so
/// relaunching doesn't check again), posting a notification once per new version, and on
/// demand from the menu bar or Settings, answering with an alert either way.
/// "Install" downloads the release DMG, checks the app inside is signed by the
/// same team with the same bundle id and a newer version, swaps it in for the
/// running bundle and relaunches. Any failure before the swap leaves the
/// current app untouched.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL
        var assets: [Asset] = []

        struct Asset: Decodable, Equatable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try c.decode(String.self, forKey: .tagName)
            htmlURL = try c.decode(URL.self, forKey: .htmlURL)
            assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

        /// The release DMG: `Musique-<version>.dmg` if present, else the only other `.dmg`.
        var dmg: Asset? {
            let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
            return dmgs.first { $0.name == "Musique-\(version).dmg" } ?? (dmgs.count == 1 ? dmgs[0] : nil)
        }
    }

    /// What has to match between the running app and the downloaded one.
    struct Signature: Equatable {
        let bundleID: String?
        let teamID: String?
        let version: String?
    }

    enum InstallError: LocalizedError, Equatable {
        case noAsset
        case notSigned
        case bundleMismatch(String?)
        case teamMismatch(String?)
        case notNewer(String?)
        case invalidSignature(Int32)
        case appNotFound
        case translocated
        case tool(String, Int32)

        var errorDescription: String? {
            switch self {
            case .noAsset: return L10n.tr("ไม่พบไฟล์ DMG ในรีลีสนี้", "This release has no DMG to install.")
            case .notSigned: return L10n.tr("Musique ที่ใช้อยู่ไม่ได้ sign ด้วย team จึงยืนยันไฟล์อัปเดตไม่ได้",
                                            "This copy of Musique isn't team-signed, so the update can't be verified.")
            case .bundleMismatch(let id): return L10n.tr("แอปในไฟล์อัปเดตไม่ใช่ Musique (\(id ?? "-"))",
                                                         "The downloaded app isn't Musique (\(id ?? "none")).")
            case .teamMismatch(let t): return L10n.tr("ไฟล์อัปเดต sign โดย team อื่น (\(t ?? "-"))",
                                                      "The downloaded app is signed by a different team (\(t ?? "none")).")
            case .notNewer(let v): return L10n.tr("ไฟล์อัปเดต (\(v ?? "-")) ไม่ใหม่กว่าที่ใช้อยู่",
                                                  "The downloaded app (\(v ?? "unknown")) isn't newer than this one.")
            case .invalidSignature(let s): return L10n.tr("ลายเซ็นของไฟล์อัปเดตไม่ถูกต้อง (\(s))",
                                                          "The downloaded app's code signature is invalid (\(s)).")
            case .appNotFound: return L10n.tr("ไม่พบ Musique.app ในไฟล์ DMG", "Musique.app wasn't found in the DMG.")
            case .translocated: return L10n.tr("ย้าย Musique ไปไว้ในโฟลเดอร์ Applications ก่อน แล้วลองใหม่",
                                               "Move Musique to the Applications folder first, then try again.")
            case .tool(let name, let code): return "\(name) failed (\(code))."
            }
        }
    }

    /// The latest release, set only when it's newer than this build.
    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var installing = false

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

    /// The menu item, Settings button and notification all land here.
    func offerAvailable() {
        if let available { offer(available) } else { Task { await check(userInitiated: true) } }
    }

    /// Accepts `candidate` only if it's the same app from the same team and a newer version.
    nonisolated static func verify(_ candidate: Signature, against current: Signature) throws {
        guard let team = current.teamID, current.bundleID != nil else { throw InstallError.notSigned }
        guard candidate.bundleID == current.bundleID else { throw InstallError.bundleMismatch(candidate.bundleID) }
        guard candidate.teamID == team else { throw InstallError.teamMismatch(candidate.teamID) }
        guard let v = candidate.version, isNewer(v, than: current.version ?? "0") else {
            throw InstallError.notNewer(candidate.version)
        }
    }

    func install(_ release: Release) async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        do {
            guard let asset = release.dmg else { throw InstallError.noAsset }
            let app = Bundle.main.bundleURL
            try await Task.detached { try await Self.download(asset.url, andReplace: app) }.value
            Self.relaunch(app)
        } catch {
            NSLog("[Update] install failed: \(error.localizedDescription)")
            alert(L10n.tr("ติดตั้งอัปเดตไม่สำเร็จ", "Couldn't install the update"),
                  error.localizedDescription + "\n\n" + L10n.tr("Musique ที่ใช้อยู่ยังไม่ถูกเปลี่ยน",
                                                                 "Your current Musique is unchanged."))
        }
    }

    /// Download → mount → copy beside the running bundle → verify → swap. The
    /// swap is the only step that touches the installed app, and it's the last.
    nonisolated private static func download(_ url: URL, andReplace app: URL) async throws {
        if app.path.contains("/AppTranslocation/") { throw InstallError.translocated }
        let current = try signature(of: app)
        guard current.teamID != nil, current.bundleID != nil else { throw InstallError.notSigned }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("musique-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: tmp, to: dmg)

        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-quiet",
                                     "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) }

        let found = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == current.bundleID }
        guard let source = found else { throw InstallError.appNotFound }

        // Same volume as the installed app, so the swap is a rename.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [source.path, staged.path])

        try verify(try signature(of: staged), against: current)
        // Not notarized: a quarantined copy would be refused by Gatekeeper on relaunch.
        // Safe to drop only because the signature was just checked against our own team.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        _ = try fm.replaceItemAt(app, withItemAt: staged)
    }

    /// Validates the bundle's whole signature (nested appexes included), then reads who signed it.
    nonisolated static func signature(of bundle: URL) throws -> Signature {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw InstallError.invalidSignature(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { throw InstallError.invalidSignature(status) }
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dict = info as? [String: Any] else { throw InstallError.invalidSignature(status) }
        let plist = dict[kSecCodeInfoPList as String] as? [String: Any]
        return Signature(bundleID: plist?["CFBundleIdentifier"] as? String,
                         teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String,
                         version: plist?["CFBundleShortVersionString"] as? String)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw InstallError.tool(URL(fileURLWithPath: tool).lastPathComponent, p.terminationStatus)
        }
    }

    /// A detached shell waits for this process to exit, then opens the new bundle.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
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
        content.body = L10n.tr("\(release.version) พร้อมแล้ว (ใช้อยู่ \(Self.currentVersion)) คลิกเพื่อติดตั้ง",
                               "\(release.version) is out (you have \(Self.currentVersion)). Click to install.")
        content.userInfo = [NotificationService.offerUpdateKey: true]
        let request = UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func offer(_ release: Release) {
        let a = NSAlert()
        a.messageText = L10n.tr("มี Musique \(release.version) แล้ว", "Musique \(release.version) is available")
        a.informativeText = L10n.tr("ใช้อยู่ \(Self.currentVersion)", "You have \(Self.currentVersion).")
        a.informativeText += "\n\n" + L10n.tr("Musique จะปิดและเปิดใหม่หลังติดตั้ง",
                                               "Musique will quit and reopen after installing.")
        a.addButton(withTitle: L10n.tr("ติดตั้ง", "Install"))
        a.addButton(withTitle: L10n.tr("ไว้ทีหลัง", "Later"))
        a.addButton(withTitle: L10n.tr("ดูรายละเอียด", "Release Notes"))
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install(release) }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.htmlURL)
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}

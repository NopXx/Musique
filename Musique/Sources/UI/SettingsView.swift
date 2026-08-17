import SwiftUI
import AppKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var apiKey: String
    @Published var apiSecret: String
    @Published var lastfmEnabled: Bool
    @Published var sessionUser: String
    @Published var hasPendingToken: Bool
    @Published var connecting: Bool = false
    @Published var statusMessage: String = ""

    @Published var scrobblePercent: Int
    @Published var scrobbleMinSeconds: Int
    @Published var scrobbleAppleMusic: Bool
    @Published var scrobbleSpotify: Bool

    @Published var notificationsEnabled: Bool
    @Published var notifOnPlay: Bool
    @Published var notifOnScrobble: Bool

    @Published var miniplayerMeta: String
    @Published var miniplayerAnimation: String
    @Published var miniplayerArtworkStyle: String
    @Published var animationFullscreen: Bool

    @Published var menubarStyle: String
    @Published var menubarShowIcon: Bool
    @Published var menubarShowTrack: Bool
    @Published var menubarShowArtist: Bool
    @Published var menubarShowState: Bool
    @Published var menubarMaxLength: Int

    @Published var webhookEnabled: Bool
    @Published var webhookHeartbeat: Int
    @Published var webhookUrls: [String]
    @Published var newWebhookUrl: String = ""

    @Published var lockscreenEnabled: Bool
    @Published var lockscreenShowAlbum: Bool
    @Published var lockscreenShowProgress: Bool
    @Published var lockscreenAnimatedArtwork: Bool
    @Published var lockscreenBackgroundBlur: Double
    @Published var lockscreenPadding: Int
    @Published var lockscreenScreens: String
    /// ponytail: kept without a UI row — the desktop-wallpaper takeover is off
    /// behind `LockScreenController.wallpaperTakeoverEnabled`, and leaving the
    /// property/load/save intact makes re-enabling a pure revert without churning
    /// anyone's settings.json.
    @Published var lockscreenSetSystemWallpaper: Bool
    @Published var lockscreenClock: Bool
    @Published var lockscreenClockFormat: String
    @Published var lockscreenClockDateStyle: String

    @Published var language: String
    @Published var launchAtLogin: Bool
    @Published var showInDock: Bool

    @Published var debugServerEnabled: Bool
    @Published var debugServerPort: Int

    @Published var sourceAppleMusicEnabled: Bool
    @Published var sourceSpotifyEnabled: Bool
    @Published var sourcePriority: String

    private let store = SettingsStore.shared
    private var pollTask: Task<Void, Never>?

    init() {
        let lf = store.value(["lastfm"], [String: Any].self) ?? [:]
        self.apiKey = (lf["api_key"] as? String) ?? ""
        self.apiSecret = ""
        self.lastfmEnabled = (lf["enabled"] as? Bool) ?? false
        self.sessionUser = (lf["username"] as? String) ?? ""
        self.hasPendingToken = !((lf["pending_token"] as? String) ?? "").isEmpty

        self.scrobblePercent = store.int(["scrobble", "percent"])
        self.scrobbleMinSeconds = store.int(["scrobble", "min_seconds"])
        self.scrobbleAppleMusic = store.value(["scrobble", "scrobble_apple_music"], Bool.self) ?? true
        self.scrobbleSpotify = store.value(["scrobble", "scrobble_spotify"], Bool.self) ?? true

        self.notificationsEnabled = store.bool(["notifications", "enabled"])
        self.notifOnPlay = store.bool(["notifications", "on_play"])
        self.notifOnScrobble = store.bool(["notifications", "on_scrobble"])

        let meta = store.string(["miniplayer", "meta_display"])
        self.miniplayerMeta = meta.isEmpty ? "artist_album" : meta
        let anim = store.string(["miniplayer", "animation"])
        self.miniplayerAnimation = anim.isEmpty ? "full" : anim
        let style = store.string(["miniplayer", "artwork_style"])
        self.miniplayerArtworkStyle = style.isEmpty ? "classic" : style
        self.animationFullscreen = store.bool(["miniplayer", "animation_fullscreen"])

        let mbStyle = store.string(["menubar", "style"])
        self.menubarStyle = mbStyle.isEmpty ? "text" : mbStyle
        self.menubarShowIcon = store.bool(["menubar", "show_icon"])
        self.menubarShowTrack = store.bool(["menubar", "show_track"])
        self.menubarShowArtist = store.bool(["menubar", "show_artist"])
        self.menubarShowState = store.bool(["menubar", "show_state"])
        let ml = store.int(["menubar", "max_length"])
        self.menubarMaxLength = ml > 0 ? ml : 40

        self.webhookEnabled = store.bool(["webhook", "enabled"])
        self.webhookHeartbeat = store.int(["webhook", "heartbeat_seconds"])
        self.webhookUrls = (store.value(["webhook", "urls"], [Any].self) ?? [])
            .compactMap { $0 as? String }

        self.lockscreenEnabled = store.bool(["lockscreen", "enabled"])
        self.lockscreenShowAlbum = store.bool(["lockscreen", "show_album"])
        self.lockscreenShowProgress = store.bool(["lockscreen", "show_progress"])
        self.lockscreenAnimatedArtwork = store.bool(["lockscreen", "animated_artwork"])
        let blur = store.int(["lockscreen", "background_blur"])
        self.lockscreenBackgroundBlur = Double(blur > 0 ? blur : 60)
        let pad = store.int(["lockscreen", "padding"])
        self.lockscreenPadding = pad > 0 ? pad : 32
        let scr = store.string(["lockscreen", "screens"])
        self.lockscreenScreens = scr.isEmpty ? "main" : scr
        self.lockscreenSetSystemWallpaper = store.bool(["lockscreen", "set_system_wallpaper"])
        self.lockscreenClock = store.bool(["lockscreen", "clock"])
        let clockFormat = store.string(["lockscreen", "clock_format"])
        self.lockscreenClockFormat = clockFormat.isEmpty ? "system" : clockFormat
        let clockDate = store.string(["lockscreen", "clock_date_style"])
        self.lockscreenClockDateStyle = clockDate.isEmpty ? "full" : clockDate

        let lang = store.string(["language"])
        self.language = lang.isEmpty ? "th" : lang

        let systemLaunchAtLogin = LaunchAtLoginService.isEnabled
        self.launchAtLogin = systemLaunchAtLogin
        if store.bool(["general", "launch_at_login"]) != systemLaunchAtLogin {
            store.merge(["general": ["launch_at_login": systemLaunchAtLogin]])
        }
        self.showInDock = store.bool(["general", "show_in_dock"])

        self.debugServerEnabled = store.bool(["debug", "server_enabled"])
        let dport = store.int(["debug", "server_port"])
        self.debugServerPort = dport > 0 ? dport : 8765

        self.sourceAppleMusicEnabled = store.bool(["sources", "apple_music_enabled"])
        self.sourceSpotifyEnabled = store.bool(["sources", "spotify_enabled"])
        let prio = store.string(["sources", "priority"])
        self.sourcePriority = prio.isEmpty ? "apple_music" : prio
    }

    var hasSession: Bool {
        let lf = store.value(["lastfm"], [String: Any].self) ?? [:]
        return !((lf["session_key"] as? String) ?? "").isEmpty
    }

    func saveKeys() {
        var lf: [String: Any] = ["api_key": apiKey, "enabled": lastfmEnabled]
        if !apiSecret.isEmpty { lf["api_secret"] = apiSecret }
        store.merge(["lastfm": lf])
    }

    func connect() {
        saveKeys()
        let lf = store.value(["lastfm"], [String: Any].self) ?? [:]
        let key = LastFMSecrets.resolveKey(lf["api_key"] as? String)
        let secret = LastFMSecrets.resolveSecret(lf["api_secret"] as? String)
        guard !key.isEmpty, !secret.isEmpty else {
            statusMessage = L10n.lastfmNeedKeys
            return
        }
        statusMessage = ""
        connecting = true
        Task { [weak self] in
            let res = await LastFMClient.call(method: "auth.getToken",
                                              params: ["api_key": key], secret: secret)
            await MainActor.run {
                guard let self else { return }
                guard let token = res["token"] as? String else {
                    self.connecting = false
                    self.statusMessage = (res["message"] as? String) ?? L10n.lastfmTokenFail
                    return
                }
                self.store.merge(["lastfm": ["pending_token": token]])
                self.hasPendingToken = true
                let authURL = URL(string: "https://www.last.fm/api/auth/?api_key=\(key)&token=\(token)")
                if let authURL { NSWorkspace.shared.open(authURL) }
                self.startPolling()
            }
        }
    }

    func cancelConnect() {
        pollTask?.cancel()
        pollTask = nil
        connecting = false
        store.merge(["lastfm": ["session_key": "", "username": "",
                                "pending_token": "", "enabled": false]])
        hasPendingToken = false
        sessionUser = ""
        lastfmEnabled = false
    }

    func disconnect() {
        cancelConnect()
        statusMessage = L10n.lastfmDisconnected
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<48 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                let lf = await SettingsStore.shared.value(["lastfm"], [String: Any].self) ?? [:]
                let token = (lf["pending_token"] as? String) ?? ""
                let key = LastFMSecrets.resolveKey(lf["api_key"] as? String)
                let secret = LastFMSecrets.resolveSecret(lf["api_secret"] as? String)
                guard !token.isEmpty else { continue }
                let res = await LastFMClient.call(method: "auth.getSession",
                                                  params: ["api_key": key, "token": token],
                                                  secret: secret)
                if let session = res["session"] as? [String: Any],
                   let sk = session["key"] as? String,
                   let name = session["name"] as? String {
                    await MainActor.run {
                        self.store.merge(["lastfm": [
                            "session_key": sk, "username": name,
                            "pending_token": "", "enabled": true,
                        ]])
                        self.sessionUser = name
                        self.lastfmEnabled = true
                        self.hasPendingToken = false
                        self.connecting = false
                        self.statusMessage = L10n.lastfmConnectedAs(name)
                    }
                    return
                }
            }
            await MainActor.run {
                self?.connecting = false
                self?.hasPendingToken = false
                self?.statusMessage = L10n.lastfmTimeout
            }
        }
    }

    func saveScrobbleRules() {
        store.merge(["scrobble": [
            "percent": scrobblePercent,
            "min_seconds": scrobbleMinSeconds,
            "scrobble_apple_music": scrobbleAppleMusic,
            "scrobble_spotify": scrobbleSpotify,
        ]])
    }

    func saveSources() {
        store.merge(["sources": [
            "apple_music_enabled": sourceAppleMusicEnabled,
            "spotify_enabled": sourceSpotifyEnabled,
            "priority": sourcePriority,
        ]])
        Task { @MainActor in AppDelegate.shared?.playerMonitor.refresh() }
    }

    func saveNotifications() {
        store.merge(["notifications": [
            "enabled": notificationsEnabled,
            "on_play": notifOnPlay,
            "on_scrobble": notifOnScrobble,
        ]])
    }

    func toggleNotifications(to newValue: Bool) {
        if newValue {
            Task { @MainActor in
                let granted = await NotificationService.shared.ensureAuthorized()
                if !granted {
                    notificationsEnabled = false
                    statusMessage = L10n.notifPermissionDenied
                }
                saveNotifications()
            }
        } else {
            saveNotifications()
        }
    }

    func saveWebhook() {
        store.merge(["webhook": [
            "enabled": webhookEnabled,
            "urls": webhookUrls,
            "heartbeat_seconds": webhookHeartbeat,
        ]])
        Task { @MainActor in WebhookDispatcher.shared.reloadHeartbeat() }
    }

    func addWebhookUrl() {
        let trimmed = newWebhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
        guard !webhookUrls.contains(trimmed) else { return }
        webhookUrls.append(trimmed)
        newWebhookUrl = ""
        saveWebhook()
    }

    func removeWebhookUrl(_ url: String) {
        webhookUrls.removeAll { $0 == url }
        saveWebhook()
    }

    func saveMenubar() {
        store.merge(["menubar": [
            "style": menubarStyle,
            "show_icon": menubarShowIcon,
            "show_track": menubarShowTrack,
            "show_artist": menubarShowArtist,
            "show_state": menubarShowState,
            "max_length": menubarMaxLength,
        ]])
    }

    func saveMiniplayer() {
        store.merge(["miniplayer": [
            "meta_display": miniplayerMeta,
            "animation": miniplayerAnimation,
            "artwork_style": miniplayerArtworkStyle,
            "animation_fullscreen": animationFullscreen,
        ]])
    }

    func saveLockscreen() {
        store.merge(["lockscreen": [
            "enabled": lockscreenEnabled,
            "show_album": lockscreenShowAlbum,
            "show_progress": lockscreenShowProgress,
            "animated_artwork": lockscreenAnimatedArtwork,
            "background_blur": Int(lockscreenBackgroundBlur),
            "padding": lockscreenPadding,
            "screens": lockscreenScreens,
            "set_system_wallpaper": lockscreenSetSystemWallpaper,
            "clock": lockscreenClock,
            "clock_format": lockscreenClockFormat,
            "clock_date_style": lockscreenClockDateStyle,
        ]])
    }

    func saveLanguage() {
        store.merge(["language": language])
    }

    func saveDebugServer() {
        let port = max(1024, min(65535, debugServerPort))
        debugServerPort = port
        store.merge(["debug": ["server_enabled": debugServerEnabled, "server_port": port]])
        DebugServer.shared.stop()
        if debugServerEnabled {
            DebugServer.shared.start(port: UInt16(port))
        }
    }

    func openDebugServer() {
        let port = debugServerPort > 0 ? debugServerPort : 8765
        if let url = URL(string: "http://127.0.0.1:\(port)/") {
            NSWorkspace.shared.open(url)
        }
    }

    func saveLaunchAtLogin() {
        let ok = LaunchAtLoginService.setEnabled(launchAtLogin)
        if !ok {
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
        store.merge(["general": ["launch_at_login": launchAtLogin]])
    }

    func saveShowInDock() {
        store.merge(["general": ["show_in_dock": showInDock]])
        AppDelegate.applyDockVisibility()
    }
}

// MARK: - Settings tab enum

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, sources, lastfm, scrobble, notifications, webhooks, menubar, miniplayer, lockscreen, editRules, history, debug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return L10n.tr("ทั่วไป", "General")
        case .sources: return L10n.tr("แหล่งเพลง", "Music Sources")
        case .lastfm: return "Last.fm"
        case .scrobble: return "Scrobble"
        case .notifications: return L10n.tabNotifications
        case .webhooks: return "Webhooks"
        case .menubar: return "Menu Bar"
        case .miniplayer: return "Mini Player"
        case .lockscreen: return "Lock Screen"
        case .editRules: return "Edit Rules"
        case .history: return L10n.tabHistory
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .sources: return "music.note.house"
        case .lastfm: return "music.note.list"
        case .scrobble: return "checkmark.seal"
        case .notifications: return "bell"
        case .webhooks: return "link"
        case .menubar: return "menubar.rectangle"
        case .miniplayer: return "play.rectangle"
        case .lockscreen: return "lock.display"
        case .editRules: return "pencil.and.list.clipboard"
        case .history: return "clock.arrow.circlepath"
        case .debug: return "ladybug"
        }
    }

    var tint: Color {
        switch self {
        case .general:       return Color(red: 0.45, green: 0.48, blue: 0.55)
        case .sources:       return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .lastfm:        return Color(red: 0.85, green: 0.18, blue: 0.18)
        case .scrobble:      return .orange
        case .notifications: return .red
        case .webhooks:      return .purple
        case .menubar:       return .blue
        case .miniplayer:    return .pink
        case .lockscreen:    return .indigo
        case .editRules:     return .teal
        case .history:       return Color(red: 0.55, green: 0.40, blue: 0.30)
        case .debug:         return Color(red: 0.30, green: 0.55, blue: 0.45)
        }
    }
}

// MARK: - Root view

struct SettingsView: View {
    @StateObject var vm = SettingsViewModel()
    @State private var selection: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                HStack(spacing: 10) {
                    SidebarTile(icon: tab.icon, tint: tab.tint)
                    Text(tab.label)
                        .font(.callout)
                }
                .padding(.vertical, 2)
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case .general:       GeneralTab(vm: vm)
                case .sources:       SourcesTab(vm: vm)
                case .lastfm:        LastfmTab(vm: vm)
                case .scrobble:      ScrobbleTab(vm: vm)
                case .notifications: NotificationsTab(vm: vm)
                case .webhooks:      WebhooksTab(vm: vm)
                case .menubar:       MenubarTab(vm: vm)
                case .miniplayer:    MiniplayerTab(vm: vm)
                case .lockscreen:    LockscreenTab(vm: vm)
                case .editRules:     EditRulesTab()
                case .history:       HistoryTab()
                case .debug:         DebugTab(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsTokens.pageBackground)
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 560)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var vm: SettingsViewModel

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "gearshape",
                iconTint: SettingsTab.general.tint,
                title: LocalizedStringKey(L10n.tr("ทั่วไป", "General")),
                subtitle: LocalizedStringKey(L10n.tr("ตั้งค่าทั่วไปของแอพ", "General app settings"))
            ) {
                CardRow(label: LocalizedStringKey(L10n.tr("เปิดอัตโนมัติเมื่อล็อกอิน", "Launch at login"))) {
                    Toggle("", isOn: $vm.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.launchAtLogin) { _, _ in vm.saveLaunchAtLogin() }
                }

                CardRow(label: LocalizedStringKey(L10n.tr("แสดงใน Dock", "Show in Dock"))) {
                    Toggle("", isOn: $vm.showInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.showInDock) { _, _ in vm.saveShowInDock() }
                }

                CardRow(label: LocalizedStringKey(L10n.languageTitle)) {
                    Picker("", selection: $vm.language) {
                        Text(L10n.languageThai).tag("th")
                        Text(L10n.languageEnglish).tag("en")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: vm.language) { _, _ in vm.saveLanguage() }
                }
            }

            SettingsCard(
                icon: "info.circle",
                iconTint: .gray,
                title: LocalizedStringKey(L10n.tr("เกี่ยวกับ", "About"))
            ) {
                CardRow(label: LocalizedStringKey(L10n.tr("เวอร์ชัน", "Version"))) {
                    Text(appVersion)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Music Sources

private struct SourcesTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "music.note.house",
                iconTint: SettingsTab.sources.tint,
                title: LocalizedStringKey(L10n.tr("แหล่งเพลง", "Music Sources")),
                subtitle: LocalizedStringKey(L10n.tr("เลือกแอพเล่นเพลงที่ Musique จะติดตาม", "Choose which players Musique follows"))
            ) {
                SettingsToggleRow(label: "Apple Music", isOn: $vm.sourceAppleMusicEnabled)
                    .onChange(of: vm.sourceAppleMusicEnabled) { _, _ in vm.saveSources() }

                SettingsToggleRow(label: "Spotify", isOn: $vm.sourceSpotifyEnabled)
                    .onChange(of: vm.sourceSpotifyEnabled) { _, _ in vm.saveSources() }

                Divider().opacity(0.4)

                CardRow(label: LocalizedStringKey(L10n.tr("ลำดับความสำคัญ", "Priority when both play"))) {
                    Picker("", selection: $vm.sourcePriority) {
                        Text("Apple Music").tag("apple_music")
                        Text("Spotify").tag("spotify")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: vm.sourcePriority) { _, _ in vm.saveSources() }
                }

                CardFooter(text: LocalizedStringKey(L10n.tr(
                    "ครั้งแรกที่ควบคุม Spotify macOS จะถามสิทธิ์ Automation — อนุญาตที่ System Settings › Privacy & Security › Automation",
                    "The first time Musique controls Spotify, macOS asks for Automation permission — allow it in System Settings › Privacy & Security › Automation.")))
            }
        }
    }
}

// MARK: - Debug

private struct DebugTab: View {
    @ObservedObject var vm: SettingsViewModel

    private var serverURL: String { "http://127.0.0.1:\(vm.debugServerPort)/" }

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "ladybug",
                iconTint: SettingsTab.debug.tint,
                title: "Debug Server",
                subtitle: "Local HTTP endpoint for inspecting player snapshot, raw track data, audio bands, settings, and pending scrobbles."
            ) {
                CardRow(label: "Enable server") {
                    Toggle("", isOn: $vm.debugServerEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.debugServerEnabled) { _, _ in vm.saveDebugServer() }
                }

                CardRow(label: "Port") {
                    TextField("", value: $vm.debugServerPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit { vm.saveDebugServer() }
                }

                CardRow(label: "URL") {
                    HStack(spacing: 8) {
                        Text(serverURL)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Open") { vm.openDebugServer() }
                            .disabled(!vm.debugServerEnabled)
                    }
                }
            }

            SettingsCard(
                icon: "list.bullet.rectangle",
                iconTint: .gray,
                title: "Endpoints"
            ) {
                CardRow(label: "/") { Text("HTML dashboard (auto-refresh)").foregroundStyle(.secondary).font(.callout) }
                CardRow(label: "/api/all") { Text("snapshot + raw + audio + settings").foregroundStyle(.secondary).font(.callout) }
                CardRow(label: "/api/snapshot") { Text("PlayerMonitor snapshot").foregroundStyle(.secondary).font(.callout) }
                CardRow(label: "/api/raw") { Text("Raw Music.app track fields").foregroundStyle(.secondary).font(.callout) }
                CardRow(label: "/api/audio") { Text("FFT band levels").foregroundStyle(.secondary).font(.callout) }
                CardRow(label: "/api/pending") { Text("Pending scrobble queue").foregroundStyle(.secondary).font(.callout) }
                CardRow(label: "/api/settings") { Text("Settings (api_secret stripped)").foregroundStyle(.secondary).font(.callout) }
            }
        }
    }
}

// MARK: - Last.fm

private struct LastfmTab: View {
    @ObservedObject var vm: SettingsViewModel

    private var needsManualKeys: Bool {
        LastFMSecrets.bundledAPIKey.isEmpty || LastFMSecrets.bundledAPISecret.isEmpty
    }

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "music.note.list",
                iconTint: SettingsTab.lastfm.tint,
                title: LocalizedStringKey(L10n.lastfmTitle),
                subtitle: LocalizedStringKey(L10n.lastfmSubtitle)
            ) {
                if vm.hasSession {
                    HStack(spacing: 10) {
                        StatusBadge(text: L10n.lastfmConnected, tone: .success)
                        Text(vm.sessionUser).font(.callout.weight(.semibold))
                        Spacer()
                    }
                    SettingsToggleRow(label: LocalizedStringKey(L10n.lastfmEnableScrobbling),
                                      isOn: $vm.lastfmEnabled)
                        .onChange(of: vm.lastfmEnabled) { _, _ in vm.saveKeys() }
                    HStack {
                        Spacer()
                        Button(L10n.lastfmDisconnect, role: .destructive) { vm.disconnect() }
                    }
                } else {
                    HStack(spacing: 10) {
                        StatusBadge(text: L10n.lastfmNotConnected, tone: .neutral)
                        Spacer()
                    }
                }
                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.hasSession {
                SettingsCard(
                    icon: "dot.radiowaves.left.and.right",
                    iconTint: SettingsTab.lastfm.tint,
                    title: LocalizedStringKey(L10n.scrobbleSources),
                    subtitle: nil
                ) {
                    SettingsToggleRow(label: LocalizedStringKey(L10n.scrobbleAppleMusic),
                                      isOn: $vm.scrobbleAppleMusic)
                        .onChange(of: vm.scrobbleAppleMusic) { _, _ in vm.saveScrobbleRules() }

                    Divider().opacity(0.4)

                    SettingsToggleRow(label: LocalizedStringKey(L10n.scrobbleSpotify),
                                      isOn: $vm.scrobbleSpotify)
                        .onChange(of: vm.scrobbleSpotify) { _, _ in vm.saveScrobbleRules() }
                }
            }

            if !vm.hasSession && needsManualKeys {
                SettingsCard(
                    icon: "key.fill",
                    iconTint: .orange,
                    title: "API Credentials",
                    subtitle: LocalizedStringKey(L10n.lastfmGetApiKey)
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("", text: $vm.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { vm.saveKeys() }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shared Secret").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SecureField("", text: $vm.apiSecret)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { vm.saveKeys() }
                    }
                    Link(L10n.lastfmGetApiKey,
                         destination: URL(string: "https://www.last.fm/api/account/create")!)
                        .font(.caption)
                }
            }

            if !vm.hasSession {
                SettingsCard(
                    icon: "link",
                    iconTint: .blue,
                    title: "Connect",
                    subtitle: nil
                ) {
                    HStack {
                        Spacer()
                        if vm.connecting {
                            Button(L10n.lastfmCancel) { vm.cancelConnect() }
                            Button(L10n.lastfmWaiting) {}.disabled(true)
                        } else {
                            Button("Connect with Last.fm") {
                                vm.saveKeys()
                                vm.connect()
                            }
                            .buttonStyle(PrimaryGradientButtonStyle(tint: SettingsTab.lastfm.tint))
                            .keyboardShortcut(.defaultAction)
                            .disabled(LastFMSecrets.resolveKey(vm.apiKey).isEmpty
                                      || LastFMSecrets.resolveSecret(vm.apiSecret).isEmpty)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Scrobble

private struct ScrobbleTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "checkmark.seal",
                iconTint: SettingsTab.scrobble.tint,
                title: LocalizedStringKey(L10n.scrobbleTitle),
                subtitle: LocalizedStringKey(L10n.scrobbleSubtitle)
            ) {
                CardRow(label: LocalizedStringKey(L10n.scrobblePlayedThrough)) {
                    SettingsNumberField(value: $vm.scrobblePercent,
                                        range: 25...100,
                                        suffix: "%",
                                        onCommit: { vm.saveScrobbleRules() })
                }

                Divider().opacity(0.4)

                CardRow(label: LocalizedStringKey(L10n.scrobbleMinLength)) {
                    SettingsNumberField(value: $vm.scrobbleMinSeconds,
                                        range: 10...120,
                                        suffix: L10n.scrobbleSeconds,
                                        onCommit: { vm.saveScrobbleRules() })
                }

                CardFooter(text: LocalizedStringKey(L10n.scrobbleFooter))
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "bell",
                iconTint: SettingsTab.notifications.tint,
                title: LocalizedStringKey(L10n.notifTitle),
                subtitle: LocalizedStringKey(L10n.notifSubtitle)
            ) {
                SettingsToggleRow(label: LocalizedStringKey(L10n.notifEnable),
                                  isOn: $vm.notificationsEnabled)
                    .onChange(of: vm.notificationsEnabled) { _, new in vm.toggleNotifications(to: new) }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: SettingsTokens.Spacing.md) {
                    SettingsToggleRow(label: LocalizedStringKey(L10n.notifOnPlay),
                                      isOn: $vm.notifOnPlay)
                        .onChange(of: vm.notifOnPlay) { _, _ in vm.saveNotifications() }

                    SettingsToggleRow(label: LocalizedStringKey(L10n.notifOnScrobble),
                                      isOn: $vm.notifOnScrobble)
                        .onChange(of: vm.notifOnScrobble) { _, _ in vm.saveNotifications() }
                }
                .disabled(!vm.notificationsEnabled)
                .opacity(vm.notificationsEnabled ? 1.0 : 0.45)
                .animation(.easeInOut(duration: 0.18), value: vm.notificationsEnabled)

                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Webhooks

private struct WebhooksTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "link",
                iconTint: SettingsTab.webhooks.tint,
                title: LocalizedStringKey(L10n.webhookTitle),
                subtitle: LocalizedStringKey(L10n.webhookSubtitle)
            ) {
                SettingsToggleRow(label: LocalizedStringKey(L10n.webhookEnable),
                                  isOn: $vm.webhookEnabled)
                    .onChange(of: vm.webhookEnabled) { _, _ in vm.saveWebhook() }

                Divider().opacity(0.4)

                CardRow(label: "Heartbeat") {
                    SettingsNumberField(value: $vm.webhookHeartbeat,
                                        range: 0...3600,
                                        width: 70,
                                        suffix: "s",
                                        onCommit: { vm.saveWebhook() })
                        .disabled(!vm.webhookEnabled)
                }
                .opacity(vm.webhookEnabled ? 1.0 : 0.45)
                .animation(.easeInOut(duration: 0.18), value: vm.webhookEnabled)

                CardFooter(text: LocalizedStringKey(L10n.webhookFooter))
            }

            SettingsCard(
                icon: "antenna.radiowaves.left.and.right",
                iconTint: .indigo,
                title: LocalizedStringKey(L10n.webhookDestination)
            ) {
                if vm.webhookUrls.isEmpty {
                    Text(L10n.webhookNoUrl)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(vm.webhookUrls, id: \.self) { url in
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(url)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    vm.removeWebhookUrl(url)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("https://example.com/webhook", text: $vm.newWebhookUrl)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.addWebhookUrl() }
                    Button(L10n.webhookAdd) { vm.addWebhookUrl() }
                        .buttonStyle(PrimaryGradientButtonStyle(tint: SettingsTab.webhooks.tint))
                        .disabled(vm.newWebhookUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Menu Bar

private struct MenubarTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "menubar.rectangle",
                iconTint: SettingsTab.menubar.tint,
                title: "Menu Bar",
                subtitle: LocalizedStringKey(L10n.menubarSubtitle)
            ) {
                CardRow(label: LocalizedStringKey(L10n.menubarStyle)) {
                    Picker("", selection: $vm.menubarStyle) {
                        Text(L10n.menubarStyleText).tag("text")
                        Text(L10n.menubarStyleDynamicIsland).tag("dynamic_island")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: vm.menubarStyle) { _, _ in vm.saveMenubar() }
                }

                CardFooter(text: LocalizedStringKey(vm.menubarStyle == "dynamic_island" ? L10n.menubarFooterIsland : L10n.menubarFooter))
            }

            if vm.menubarStyle == "text" {
                SettingsCard(
                    icon: "textformat",
                    iconTint: .blue,
                    title: "Text Format"
                ) {
                    SettingsToggleRow(label: LocalizedStringKey(L10n.menubarShowIcon),
                                      isOn: $vm.menubarShowIcon)
                        .onChange(of: vm.menubarShowIcon) { _, _ in vm.saveMenubar() }

                    SettingsToggleRow(label: LocalizedStringKey(L10n.menubarShowState),
                                      isOn: $vm.menubarShowState)
                        .onChange(of: vm.menubarShowState) { _, _ in vm.saveMenubar() }

                    SettingsToggleRow(label: LocalizedStringKey(L10n.menubarShowTrack),
                                      isOn: $vm.menubarShowTrack)
                        .onChange(of: vm.menubarShowTrack) { _, _ in vm.saveMenubar() }

                    SettingsToggleRow(label: LocalizedStringKey(L10n.menubarShowArtist),
                                      isOn: $vm.menubarShowArtist)
                        .onChange(of: vm.menubarShowArtist) { _, _ in vm.saveMenubar() }

                    Divider().opacity(0.4)

                    CardRow(label: LocalizedStringKey(L10n.menubarMaxLength)) {
                        SettingsNumberField(value: $vm.menubarMaxLength,
                                            range: 10...120,
                                            suffix: L10n.menubarChars,
                                            onCommit: { vm.saveMenubar() })
                    }
                }
            } else {
                SettingsCard(
                    icon: "rectangle.on.rectangle",
                    iconTint: .blue,
                    title: "Dynamic Island"
                ) {
                    SettingsToggleRow(label: LocalizedStringKey(L10n.menubarShowState),
                                      isOn: $vm.menubarShowState)
                        .onChange(of: vm.menubarShowState) { _, _ in vm.saveMenubar() }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: vm.menubarStyle)
    }
}

// MARK: - Mini Player

private struct MiniplayerTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "play.rectangle",
                iconTint: SettingsTab.miniplayer.tint,
                title: "Appearance",
                subtitle: LocalizedStringKey(L10n.miniplayerSubtitle)
            ) {
                CardRow(label: LocalizedStringKey(L10n.miniplayerArtworkStyle)) {
                    Picker("", selection: $vm.miniplayerArtworkStyle) {
                        Text(L10n.miniplayerClassic).tag("classic")
                        Text(L10n.miniplayerImmersive).tag("fullbleed")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: vm.miniplayerArtworkStyle) { _, _ in vm.saveMiniplayer() }
                }

                Divider().opacity(0.4)

                CardRow(label: LocalizedStringKey(L10n.miniplayerMetaDisplay)) {
                    Picker("", selection: $vm.miniplayerMeta) {
                        Text(L10n.miniplayerArtist).tag("artist")
                        Text(L10n.miniplayerAlbum).tag("album")
                        Text(L10n.miniplayerArtistAlbum).tag("artist_album")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: vm.miniplayerMeta) { _, _ in vm.saveMiniplayer() }
                }
            }

            SettingsCard(
                icon: "sparkles",
                iconTint: .pink,
                title: "Animation"
            ) {
                CardRow(label: "Animated artwork") {
                    Picker("", selection: $vm.miniplayerAnimation) {
                        Text(L10n.miniplayerAnimOff).tag("off")
                        Text(L10n.miniplayerAnimArt).tag("art")
                        Text(L10n.miniplayerAnimFull).tag("full")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: vm.miniplayerAnimation) { _, _ in vm.saveMiniplayer() }
                }

                Divider().opacity(0.4)

                SettingsToggleRow(label: LocalizedStringKey(L10n.miniplayerAnimFullscreen),
                                  isOn: $vm.animationFullscreen)
                    .onChange(of: vm.animationFullscreen) { _, _ in vm.saveMiniplayer() }
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockscreenTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "lock.display",
                iconTint: SettingsTab.lockscreen.tint,
                title: "Lock Screen",
                subtitle: LocalizedStringKey(L10n.lockscreenSubtitle)
            ) {
                SettingsToggleRow(label: LocalizedStringKey(L10n.lockscreenEnable),
                                  isOn: $vm.lockscreenEnabled)
                    .onChange(of: vm.lockscreenEnabled) { _, _ in vm.saveLockscreen() }

                Text(L10n.lockscreenDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                SettingsCard(
                    icon: "rectangle.stack",
                    iconTint: .indigo,
                    title: LocalizedStringKey(L10n.lockscreenDisplay)
                ) {
                    SettingsToggleRow(label: LocalizedStringKey(L10n.lockscreenShowAlbum),
                                      isOn: $vm.lockscreenShowAlbum)
                        .onChange(of: vm.lockscreenShowAlbum) { _, _ in vm.saveLockscreen() }

                    SettingsToggleRow(label: LocalizedStringKey(L10n.lockscreenShowProgress),
                                      isOn: $vm.lockscreenShowProgress)
                        .onChange(of: vm.lockscreenShowProgress) { _, _ in vm.saveLockscreen() }

                    SettingsToggleRow(label: LocalizedStringKey(L10n.lockscreenAnimArtwork),
                                      isOn: $vm.lockscreenAnimatedArtwork)
                        .onChange(of: vm.lockscreenAnimatedArtwork) { _, _ in vm.saveLockscreen() }
                }

                SettingsCard(
                    icon: "paintpalette",
                    iconTint: .purple,
                    title: LocalizedStringKey(L10n.lockscreenAppearance)
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.lockscreenBgBlur).font(.subheadline)
                            Spacer()
                            Text("\(Int(vm.lockscreenBackgroundBlur))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .font(.caption)
                        }
                        Slider(value: $vm.lockscreenBackgroundBlur, in: 0...100, step: 5)
                            .onChange(of: vm.lockscreenBackgroundBlur) { _, _ in vm.saveLockscreen() }
                    }

                    Divider().opacity(0.4)

                    CardRow(label: "Padding") {
                        SettingsNumberField(value: $vm.lockscreenPadding,
                                            range: 0...120,
                                            suffix: "pt",
                                            onCommit: { vm.saveLockscreen() })
                    }

                    CardRow(label: LocalizedStringKey(L10n.lockscreenScreenPicker)) {
                        Picker("", selection: $vm.lockscreenScreens) {
                            Text(L10n.lockscreenMainOnly).tag("main")
                            Text(L10n.lockscreenAllScreens).tag("all")
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: vm.lockscreenScreens) { _, _ in vm.saveLockscreen() }
                    }

                }

                SettingsCard(
                    icon: "clock",
                    iconTint: .teal,
                    title: LocalizedStringKey(L10n.lockscreenClockTitle)
                ) {
                    SettingsToggleRow(label: LocalizedStringKey(L10n.lockscreenClockShow),
                                      isOn: $vm.lockscreenClock)
                        .onChange(of: vm.lockscreenClock) { _, _ in vm.saveLockscreen() }

                    // Only the pickers grey out — disabling the whole card would
                    // take the toggle above with it and there'd be no way back on.
                    Group {
                        CardRow(label: LocalizedStringKey(L10n.lockscreenClockFormat)) {
                            Picker("", selection: $vm.lockscreenClockFormat) {
                                Text(L10n.lockscreenClockSystem).tag("system")
                                Text(verbatim: "24h").tag("24h")
                                Text(verbatim: "12h").tag("12h")
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: vm.lockscreenClockFormat) { _, _ in vm.saveLockscreen() }
                        }

                        CardRow(label: LocalizedStringKey(L10n.lockscreenClockDate)) {
                            Picker("", selection: $vm.lockscreenClockDateStyle) {
                                Text(L10n.lockscreenClockDateFull).tag("full")
                                Text(L10n.lockscreenClockDateShort).tag("short")
                                Text(L10n.lockscreenClockDateOff).tag("off")
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: vm.lockscreenClockDateStyle) { _, _ in vm.saveLockscreen() }
                        }
                    }
                    .disabled(!vm.lockscreenClock)
                    .opacity(vm.lockscreenClock ? 1.0 : 0.45)
                }

            }
            .disabled(!vm.lockscreenEnabled)
            .opacity(vm.lockscreenEnabled ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.18), value: vm.lockscreenEnabled)
        }
    }
}

// MARK: - Edit Rules

@MainActor
private final class EditRulesViewModel: ObservableObject {
    @Published var rules: [EditRule] = []
    @Published var artistMatch: String = ""
    @Published var trackMatch: String = ""
    @Published var albumMatch: String = ""
    @Published var artistTo: String = ""
    @Published var trackTo: String = ""
    @Published var albumTo: String = ""

    func load() async {
        await EditHistoryService.shared.reload()
        self.rules = EditHistoryService.shared.rules
    }

    func add() async {
        await EditHistoryService.shared.add(
            artistMatch: artistMatch, trackMatch: trackMatch, albumMatch: albumMatch,
            artistTo: artistTo, trackTo: trackTo, albumTo: albumTo
        )
        artistMatch = ""; trackMatch = ""; albumMatch = ""
        artistTo = ""; trackTo = ""; albumTo = ""
        await load()
    }

    func remove(_ rule: EditRule) async {
        await EditHistoryService.shared.delete(id: rule.id)
        await load()
    }

    // MARK: - Import / Export (apple-music edit_history.json format)

    func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "edit_history.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var dict: [String: [String: String]] = [:]
        for rule in rules {
            let key = "\(rule.artistMatch)||||\(rule.trackMatch)"
            dict[key] = [
                "artist": rule.artistTo.isEmpty ? rule.artistMatch : rule.artistTo,
                "track":  rule.trackTo.isEmpty  ? rule.trackMatch  : rule.trackTo,
                "album":  rule.albumTo,
                "timestamp": String(Date().timeIntervalSince1970),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func importFromFile() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let existing = Set(rules.map { "\($0.artistMatch)||||\($0.trackMatch)".lowercased() })

        for (key, raw) in json {
            guard let entry = raw as? [String: Any] else { continue }
            let parts = key.components(separatedBy: "||||")
            guard parts.count == 2 else { continue }
            let artistMatch = parts[0]
            let trackMatch = parts[1]
            guard !artistMatch.isEmpty else { continue }
            if existing.contains("\(artistMatch)||||\(trackMatch)".lowercased()) { continue }

            let artistTo = (entry["artist"] as? String) ?? ""
            let trackTo  = (entry["track"]  as? String) ?? ""
            let albumTo  = (entry["album"]  as? String) ?? ""
            await EditHistoryService.shared.add(
                artistMatch: artistMatch, trackMatch: trackMatch, albumMatch: "",
                artistTo: artistTo == artistMatch ? "" : artistTo,
                trackTo:  trackTo  == trackMatch  ? "" : trackTo,
                albumTo:  albumTo
            )
        }
        await load()
    }
}

private struct EditRulesTab: View {
    @StateObject private var vm = EditRulesViewModel()

    var body: some View {
        SettingsPage {
            SettingsCard(
                icon: "pencil.and.list.clipboard",
                iconTint: SettingsTab.editRules.tint,
                title: "Edit Rules",
                subtitle: LocalizedStringKey(L10n.editRulesSubtitle),
                trailing: AnyView(
                    Menu {
                        Button("Import…") { Task { await vm.importFromFile() } }
                        Button("Export…") { vm.exportToFile() }
                            .disabled(vm.rules.isEmpty)
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                )
            ) {
                if vm.rules.isEmpty {
                    Text(L10n.editRulesNoRule)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(vm.rules) { rule in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(matchLabel(rule)).font(.callout)
                                    Text("→ " + replacementLabel(rule))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await vm.remove(rule) }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                }
            }

            SettingsCard(
                icon: "magnifyingglass",
                iconTint: .teal,
                title: LocalizedStringKey(L10n.editRulesMatchHeader)
            ) {
                ruleField(label: LocalizedStringKey(L10n.editRulesArtistRequired), text: $vm.artistMatch)
                ruleField(label: LocalizedStringKey(L10n.editRulesTrackOptional), text: $vm.trackMatch)
                ruleField(label: LocalizedStringKey(L10n.editRulesAlbumOptional), text: $vm.albumMatch)
            }

            SettingsCard(
                icon: "arrow.right.circle",
                iconTint: .green,
                title: LocalizedStringKey(L10n.editRulesReplaceHeader)
            ) {
                ruleField(label: LocalizedStringKey(L10n.editRulesNewArtist), text: $vm.artistTo)
                ruleField(label: LocalizedStringKey(L10n.editRulesNewTrack), text: $vm.trackTo)
                ruleField(label: LocalizedStringKey(L10n.editRulesNewAlbum), text: $vm.albumTo)

                HStack {
                    Spacer()
                    Button(L10n.editRulesAdd) { Task { await vm.add() } }
                        .buttonStyle(PrimaryGradientButtonStyle(tint: SettingsTab.editRules.tint))
                        .keyboardShortcut(.defaultAction)
                        .disabled(vm.artistMatch.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .task { await vm.load() }
    }

    @ViewBuilder
    private func ruleField(label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func matchLabel(_ r: EditRule) -> String {
        var parts = [r.artistMatch]
        if !r.trackMatch.isEmpty { parts.append(r.trackMatch) }
        if !r.albumMatch.isEmpty { parts.append(r.albumMatch) }
        return parts.joined(separator: " | ")
    }

    private func replacementLabel(_ r: EditRule) -> String {
        let a = r.artistTo.isEmpty ? r.artistMatch : r.artistTo
        let t = r.trackTo.isEmpty ? (r.trackMatch.isEmpty ? "*" : r.trackMatch) : r.trackTo
        let alb = r.albumTo.isEmpty ? (r.albumMatch.isEmpty ? "*" : r.albumMatch) : r.albumTo
        return "\(a) | \(t) | \(alb)"
    }
}

// MARK: - History

@MainActor
private final class HistoryViewModel: ObservableObject {
    @Published var events: [HistoryEvent] = []
    @Published var totalCount: Int = 0
    @Published var pendingCount: Int = 0

    func load() async {
        async let evts = HistoryStore.shared.recentEvents(limit: 200)
        async let total = HistoryStore.shared.eventsCount()
        async let pending = HistoryStore.shared.pendingCount()
        self.events = await evts
        self.totalCount = await total
        self.pendingCount = await pending
    }
}

private struct HistoryTab: View {
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                TintedIconTile(icon: "clock.arrow.circlepath",
                               tint: SettingsTab.history.tint,
                               size: 30, corner: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.historyTitle).font(.headline)
                    Text(L10n.historyStats(total: vm.totalCount, pending: vm.pendingCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await vm.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(
                            Circle().fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(SettingsTokens.Spacing.lg)

            Divider().opacity(0.5)

            Table(vm.events) {
                TableColumn(L10n.historyTime) { e in
                    Text(e.timestamp, style: .relative).foregroundStyle(.secondary).font(.caption)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Event") { e in
                    Text(e.eventType).font(.caption.monospaced())
                }
                .width(min: 60, ideal: 70)
                TableColumn(L10n.historyTrack) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.trackName).lineLimit(1)
                        Text("\(e.artistName) — \(e.albumName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(SettingsTokens.pageBackground)
        .task { await vm.load() }
    }
}


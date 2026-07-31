import Foundation
import Combine

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var data: [String: Any] = SettingsStore.defaults()

    private let url: URL
    private let queue = DispatchQueue(label: "musique.settings", qos: .utility)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Musique", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("settings.json")
        load()
    }

    static func defaults() -> [String: Any] {
        [
            "language": "en",
            "general": [
                "launch_at_login": false,
                "show_in_dock": false,
            ],
            "sources": [
                "apple_music_enabled": true,
                "spotify_enabled": true,
                "priority": "apple_music",
            ],
            "lastfm": [
                "api_key": "",
                "api_secret": "",
                "session_key": "",
                "username": "",
                "enabled": false,
                "pending_token": "",
            ],
            "scrobble": [
                "percent": 50,
                "min_seconds": 30,
                "scrobble_apple_music": true,
                "scrobble_spotify": true,
            ],
            "notifications": [
                "enabled": false,
                "on_play": true,
                "on_scrobble": false,
            ],
            "webhook": [
                "enabled": false,
                "urls": [String](),
                "heartbeat_seconds": 0,
            ],
            "menubar": [
                "style": "dynamic_island",
                "show_icon": true,
                "show_track": true,
                "show_artist": false,
                "show_state": true,
                "max_length": 40,
            ],
            "miniplayer": [
                "meta_display": "artist_album",
                "artwork_quality": "high",
                "animation": "full",
                "animation_quality": "high",
                "artwork_style": "classic",
                "animation_fullscreen": false,
            ],
            "widget": [
                "large_artwork_style": "normal",
            ],
            "debug": [
                "server_enabled": false,
                "server_port": 8765,
            ],
            "lockscreen": [
                "enabled": false,
                "show_album": true,
                "show_progress": true,
                "animated_artwork": true,
                "background_blur": 60,
                "background_style": "blurred_artwork",
                "padding": 32,
                "screens": "main",
                "set_system_wallpaper": false,
            ],
        ]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        self.data = deepMerge(Self.defaults(), json)
    }

    func save() {
        let snapshot = data
        queue.async { [url] in
            guard let data = try? JSONSerialization.data(withJSONObject: snapshot,
                                                         options: [.prettyPrinted]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    @discardableResult
    func merge(_ patch: [String: Any]) -> [String: Any] {
        data = deepMerge(data, patch)
        save()
        return data
    }

    func value<T>(_ keyPath: [String], _ type: T.Type = T.self) -> T? {
        var node: Any = data
        for key in keyPath {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return node as? T
    }

    func string(_ keyPath: [String]) -> String { value(keyPath, String.self) ?? "" }
    func bool(_ keyPath: [String]) -> Bool     { value(keyPath, Bool.self) ?? false }
    func int(_ keyPath: [String]) -> Int       { value(keyPath, Int.self) ?? 0 }

    func publicSnapshot() -> [String: Any] {
        var snap = data
        if var lf = snap["lastfm"] as? [String: Any] {
            let secret = (lf["api_secret"] as? String) ?? ""
            lf["api_secret_set"] = !secret.isEmpty
            lf["api_secret"] = ""
            lf["has_pending_token"] = !((lf["pending_token"] as? String) ?? "").isEmpty
            snap["lastfm"] = lf
        }
        return snap
    }
}

func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
    var out = base
    for (key, value) in override {
        if let v = value as? [String: Any], let b = out[key] as? [String: Any] {
            out[key] = deepMerge(b, v)
        } else {
            out[key] = value
        }
    }
    return out
}

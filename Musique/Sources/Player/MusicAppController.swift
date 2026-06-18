import Foundation
import AppKit

enum PlaybackSource: String {
    case appleMusic = "apple_music"
    case spotify

    var bundleID: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify:    return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify:    return "Spotify"
        }
    }

    var sfSymbol: String {
        switch self {
        case .appleMusic: return "music.note"
        case .spotify:    return "waveform"
        }
    }
}

/// Facade that routes transport commands to whichever player is currently active.
/// `activeSource` is kept in sync by `PlayerMonitor` on every refresh.
enum MusicAppController {
    static var activeSource: PlaybackSource = .appleMusic

    @MainActor static func play() {
        switch activeSource {
        case .appleMusic: AppleMusicController.shared.run { $0.playOnce(false) }
        case .spotify:    SpotifyController.shared.run { $0.play() }
        }
    }

    @MainActor static func pause() {
        switch activeSource {
        case .appleMusic: AppleMusicController.shared.run { $0.pause() }
        case .spotify:    SpotifyController.shared.run { $0.pause() }
        }
    }

    @MainActor static func playPause() {
        switch activeSource {
        case .appleMusic: AppleMusicController.shared.run { $0.playpause() }
        case .spotify:    SpotifyController.shared.run { $0.playpause() }
        }
    }

    @MainActor static func next() {
        switch activeSource {
        case .appleMusic: AppleMusicController.shared.run { $0.nextTrack() }
        case .spotify:    SpotifyController.shared.run { $0.nextTrack() }
        }
    }

    @MainActor static func previous() {
        switch activeSource {
        case .appleMusic: AppleMusicController.shared.run { $0.previousTrack() }
        case .spotify:    SpotifyController.shared.run { $0.previousTrack() }
        }
    }

    @MainActor static func setPlayerPosition(_ seconds: Double) {
        switch activeSource {
        case .appleMusic: AppleMusicController.shared.run { $0.playerPosition = seconds }
        case .spotify:    SpotifyController.shared.run { $0.playerPosition = seconds }
        }
    }
}

private func isAppRunning(_ bundleID: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
}

final class AppleMusicController {
    static let shared = AppleMusicController()
    private let queue = DispatchQueue(label: "com.nopxx.musique.scriptingbridge.music", qos: .userInitiated)
    private let app: MusicApplication? = {
        guard let raw = SBApplication(bundleIdentifier: "com.apple.Music") else { return nil }
        return unsafeBitCast(raw, to: MusicApplication.self)
    }()

    func run(_ block: @escaping (MusicApplication) -> Void) {
        guard isAppRunning("com.apple.Music"), let app else { return }
        queue.async { block(app) }
    }
}

final class SpotifyController {
    static let shared = SpotifyController()
    private let queue = DispatchQueue(label: "com.nopxx.musique.scriptingbridge.spotify", qos: .userInitiated)
    private let app: SpotifyApplication? = {
        guard let raw = SBApplication(bundleIdentifier: "com.spotify.client") else { return nil }
        return unsafeBitCast(raw, to: SpotifyApplication.self)
    }()

    func run(_ block: @escaping (SpotifyApplication) -> Void) {
        guard isAppRunning("com.spotify.client"), let app else { return }
        queue.async { block(app) }
    }
}

struct NowPlayingSnapshot {
    var state: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var persistentID: String
    var source: PlaybackSource = .appleMusic

    var isPlaying: Bool { state.lowercased() == "playing" }
    var hasTrack: Bool { !title.isEmpty }
}

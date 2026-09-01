import Foundation
import MediaPlayer
import AppKit
import AVFoundation
import Combine

@MainActor
final class NowPlayingService {
    private weak var monitor: PlayerMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkURL: String = ""
    private var commandsRegistered = false

    /// AVPlayer + AVPlayerLooper that plays a silent audio file so macOS
    /// recognises this app as a media source.  AVPlayer integrates more
    /// tightly with the Now Playing system than AVAudioPlayer — Apple's
    /// own "Becoming a now playable app" guide uses AVPlayer.
    private var silentPlayer: AVQueuePlayer?
    private var silentLooper: AVPlayerLooper?
    private var silentAssetURL: URL?
    private var lastRequestedTrackKey: String = ""

    func attach(monitor: PlayerMonitor) {
        self.monitor = monitor

        monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.update(snap)
            }
            .store(in: &cancellables)

        startSilentAudio()
        registerCommands()
        startRepublishTimer()
        update(monitor.snapshot)
    }

    // MARK: - Silent audio (AVPlayer)

    /// Write a 1-second silent WAV to a temp file then loop it via
    /// AVQueuePlayer + AVPlayerLooper.  AVPlayer hooks directly into the
    /// macOS Now Playing subsystem, which is required for Lock Screen.
    private func startSilentAudio() {
        guard silentPlayer == nil else { return }

        // Write the silent WAV to a temp file (AVPlayer needs a URL).
        // Lock Screen requires the system to see a real signal at the audio
        // HAL — all-zero samples don't qualify — so the WAV uses ±1 LSB
        // (≈ −90 dBFS, inaudible) and the player runs at full volume.
        // 60s, not 1s: AVPlayerLooper re-arms the item on every loop, and each
        // re-arm makes CoreMedia probe the (videoless) WAV for a video track and
        // log -12860/-12864. A 1s file did that every second; 60s makes it rare.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("musique_silence_v3.wav")
        if !FileManager.default.fileExists(atPath: tmpURL.path) {
            let wavData = Self.generateSilentWAV(durationSeconds: 60.0,
                                                  sampleRate: 44100,
                                                  channels: 1)
            try? wavData.write(to: tmpURL)
        }
        silentAssetURL = tmpURL

        let asset = AVAsset(url: tmpURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer(items: [item])
        player.volume = 1.0
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))

        player.play()
        silentPlayer = player
        silentLooper = looper
        NSLog("[NowPlaying] silent AVPlayer started (looping) — app should now appear in Control Center / Lock Screen")
    }

    private func stopSilentAudio() {
        silentPlayer?.pause()
        silentLooper?.disableLooping()
        silentPlayer = nil
        silentLooper = nil
        NSLog("[NowPlaying] silent AVPlayer stopped")
    }

    /// Build a minimal 16-bit PCM WAV file (all-zero samples = silence).
    private static func generateSilentWAV(durationSeconds: Double,
                                           sampleRate: Int,
                                           channels: Int) -> Data {
        let bitsPerSample = 16
        let numSamples = Int(Double(sampleRate) * durationSeconds)
        let bytesPerSample = bitsPerSample / 8
        let dataSize = numSamples * channels * bytesPerSample
        let fileSize = 36 + dataSize

        var d = Data(capacity: 44 + dataSize)

        func appendUInt32LE(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func appendUInt16LE(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46])    // "RIFF"
        appendUInt32LE(UInt32(fileSize))
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45])    // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])    // "fmt "
        appendUInt32LE(16)
        appendUInt16LE(1)                                   // PCM
        appendUInt16LE(UInt16(channels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(sampleRate * channels * bytesPerSample))
        appendUInt16LE(UInt16(channels * bytesPerSample))
        appendUInt16LE(UInt16(bitsPerSample))
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61])    // "data"
        appendUInt32LE(UInt32(dataSize))
        // Alternating ±1 LSB — perceptually silent, but a real non-zero
        // signal so the audio HAL recognises this app as actively playing.
        var samples = Data(capacity: dataSize)
        for i in 0..<(numSamples * channels) {
            let s: Int16 = (i & 1) == 0 ? 1 : -1
            withUnsafeBytes(of: s.littleEndian) { samples.append(contentsOf: $0) }
        }
        d.append(samples)

        return d
    }

    // MARK: - Remote commands

    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { _ in
            Task { @MainActor in MusicAppController.play() }
            return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { _ in
            Task { @MainActor in MusicAppController.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in MusicAppController.playPause() }
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { _ in
            Task { @MainActor in MusicAppController.next() }
            return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { _ in
            Task { @MainActor in MusicAppController.previous() }
            return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in MusicAppController.setPlayerPosition(e.positionTime) }
            return .success
        }
    }

    private func unregisterCommands() {
        guard commandsRegistered else { return }
        commandsRegistered = false
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)
        cc.playCommand.isEnabled = false
        cc.pauseCommand.isEnabled = false
        cc.togglePlayPauseCommand.isEnabled = false
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
        cc.changePlaybackPositionCommand.isEnabled = false
    }

    // MARK: - Now Playing publish

    /// Keep a cached copy of the latest info dict so we can republish it
    /// periodically — this prevents Music.app from reclaiming the slot.
    private var lastPublishedInfo: [String: Any]?
    private var republishTimer: Timer?

    private func startRepublishTimer() {
        republishTimer?.invalidate()
        republishTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.republish()
            }
        }
    }

    private func stopRepublishTimer() {
        republishTimer?.invalidate()
        republishTimer = nil
        lastPublishedInfo = nil
    }

    /// Re-set the nowPlayingInfo to reassert ownership of the Now Playing
    /// slot.  macOS picks the "last writer" so we must write periodically.
    private func republish() {
        guard let info = lastPublishedInfo else { return }
        let center = MPNowPlayingInfoCenter.default()

        // Update elapsed time from the live snapshot
        var updated = info
        if let snap = monitor?.snapshot, snap.hasTrack {
            updated[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snap.position
            updated[MPNowPlayingInfoPropertyPlaybackRate] = snap.isPlaying ? 1.0 : 0.0
            center.playbackState = snap.isPlaying ? .playing : .paused
        }
        center.nowPlayingInfo = updated
    }

    private func update(_ snap: NowPlayingSnapshot?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let snap, snap.hasTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastArtworkURL = ""
            lastPublishedInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snap.title,
            MPMediaItemPropertyArtist: snap.artist,
            MPMediaItemPropertyAlbumTitle: snap.album,
            MPMediaItemPropertyPlaybackDuration: snap.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snap.position,
            MPNowPlayingInfoPropertyPlaybackRate: snap.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }
        center.nowPlayingInfo = info
        center.playbackState = snap.isPlaying ? .playing : .paused
        lastPublishedInfo = info

        fetchArtworkIfNeeded(for: snap)
    }

    private func fetchArtworkIfNeeded(for snap: NowPlayingSnapshot) {
        let trackKey = "\(snap.title)-\(snap.artist)-\(snap.album)"
        if trackKey == lastRequestedTrackKey { return }
        
        artworkTask?.cancel()
        lastRequestedTrackKey = trackKey
        
        let title = snap.title, artist = snap.artist, album = snap.album
        let cachedURL = lastArtworkURL
        artworkTask = Task { [weak self] in
            let result = await ArtworkService.shared.lookup(title: title, artist: artist, album: album)

            // Prefer ultra-resolution for Lock Screen display
            let urlString = result.artworkUltraURL ?? result.artworkURL
            guard let urlString, !urlString.isEmpty,
                  let url = URL(string: urlString) else { return }
            if urlString == cachedURL { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = NSImage(data: data) else { return }
                await MainActor.run {
                    guard let self else { return }
                    let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    self.lastArtworkURL = urlString
                    self.lastPublishedInfo = info
                    NSLog("[NowPlaying] artwork updated (%dx%d) from: %@",
                          Int(img.size.width), Int(img.size.height), urlString)
                }
            } catch {
                NSLog("[NowPlaying] artwork fetch error: \(error.localizedDescription)")
            }
        }
    }
}

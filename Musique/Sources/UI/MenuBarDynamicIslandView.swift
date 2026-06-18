import SwiftUI
import AppKit
import Combine

@MainActor
final class MenuBarDynamicIslandModel: ObservableObject {
    @Published var snapshot: NowPlayingSnapshot?
    @Published var artwork: NSImage?
    @Published var accent: NSColor?
    /// Rendered frame of the play/pause icon, in window (global) coordinates with a
    /// top-left origin. Reported by the SwiftUI layout so AppKit hit-testing stays
    /// correct regardless of menu-bar geometry changes across macOS versions.
    /// `.zero` when no icon is visible.
    @Published var iconFrame: CGRect = .zero

    private let monitor: PlayerMonitor
    private var cancellables = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    private var lastArtworkKey: String = ""

    init(monitor: PlayerMonitor) {
        self.monitor = monitor
        monitor.$snapshot
            .combineLatest(EditHistoryService.shared.$rules)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] raw, _ in
                guard let self else { return }
                let edited = raw.map { EditHistoryService.shared.apply($0) }
                self.snapshot = edited
                self.refreshArtwork(for: edited)
            }
            .store(in: &cancellables)

        // The user can change a track's custom artwork while it's already
        // playing; our key (title|artist|album) is unchanged, so force a
        // re-resolve when that happens.
        NotificationCenter.default.publisher(for: CustomArtworkStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastArtworkKey = ""
                self.refreshArtwork(for: self.snapshot)
            }
            .store(in: &cancellables)
    }

    private func refreshArtwork(for snap: NowPlayingSnapshot?) {
        guard let snap, snap.hasTrack else {
            artworkTask?.cancel()
            paletteTask?.cancel()
            artwork = nil
            accent = nil
            lastArtworkKey = ""
            return
        }
        let key = "\(snap.title)|\(snap.artist)|\(snap.album)"
        if key == lastArtworkKey { return }
        lastArtworkKey = key
        artworkTask?.cancel()
        paletteTask?.cancel()

        // User-chosen artwork wins over the looked-up cover.
        if let customURL = CustomArtworkStore.shared.localURL(for: snap) {
            applyCustomArtwork(customURL, key: key)
            return
        }

        let title = snap.title
        let artist = snap.artist
        let album = snap.album
        artworkTask = Task { [weak self] in
            let result = await ArtworkService.shared.lookup(title: title, artist: artist, album: album)
            guard !Task.isCancelled else { return }
            guard let urlString = result.artworkURL, let url = URL(string: urlString) else {
                await MainActor.run {
                    self?.artwork = nil
                    self?.accent = nil
                }
                return
            }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = NSImage(data: data) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self?.lastArtworkKey == key {
                        self?.artwork = image
                    }
                }
            }
            let palette = await ColorExtractor.shared.palette(for: urlString)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.lastArtworkKey == key {
                    self?.accent = palette.accent
                }
            }
        }
    }

    private func applyCustomArtwork(_ url: URL, key: String) {
        let urlString = url.absoluteString
        artworkTask = Task { [weak self] in
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = NSImage(data: data) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self?.lastArtworkKey == key { self?.artwork = image }
                }
            }
            let palette = await ColorExtractor.shared.palette(for: urlString)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.lastArtworkKey == key { self?.accent = palette.accent }
            }
        }
    }
}

struct MenuBarDynamicIslandView: View {
    @ObservedObject var model: MenuBarDynamicIslandModel
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var audio = MusicAudioLevelMonitor.shared

    private var showState: Bool { settings.bool(["menubar", "show_state"]) }

    var body: some View {
        HStack(spacing: 14) {
            artworkView
            if let snap = model.snapshot, snap.hasTrack {
                if showState {
                    Image(systemName: snap.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
                            model.iconFrame = newFrame
                        }
                } else {
                    Color.clear.frame(width: 0, height: 0)
                        .onAppear { model.iconFrame = .zero }
                }
                WaveBarsView(bands: audio.bands, isPlaying: snap.isPlaying)
            } else {
                Text("Musique")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .onAppear { model.iconFrame = .zero }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 22)
        .background(pillBackground)
        .padding(.horizontal, 3)
        .onAppear { MusicAudioLevelMonitor.shared.start() }
    }

    @ViewBuilder
    private var pillBackground: some View {
        let accent = model.accent.map { Color(nsColor: $0) } ?? Color.primary
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(accent.opacity(0.22))
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(accent.opacity(0.55), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let image = model.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }
}

private struct WaveBarsView: View {
    let bands: [Float]
    let isPlaying: Bool
    private let count = 7

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 2, height: barHeight(i))
                    .animation(.easeOut(duration: 0.05), value: barHeight(i))
            }
        }
        .frame(height: 11)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: CGFloat = 2.5
        guard isPlaying, i < bands.count else { return base }
        let v = CGFloat(min(1, max(0, bands[i])))
        return base + v * 7.5
    }
}

import SwiftUI
import AppKit

/// The desktop panel's compact design: a glass bar with a small cover, title,
/// artist and a live waveform, a progress row, and the transport — the third
/// `miniplayer.desktop_style` (`compact`). Lyrics grow the window downward by
/// a strip between the title and the progress row, the same way the card does.
struct DesktopCompactPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    var onLyricsShown: (Bool) -> Bool = { _ in false }
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false
    /// Lags `showsLyrics` on the way in (window first) and leads it on the way
    /// out (strip first), as in `DesktopPlayerView`.
    @State private var expanded = false
    @State private var hoveringCover = false

    static let width: CGFloat = 340
    static let height: CGFloat = 156
    static let lyricsHeight: CGFloat = 82
    private static let corner: CGFloat = 24
    private static let stripMove = Animation.easeInOut(duration: 0.28)

    private var snap: NowPlayingSnapshot? { viewModel.snapshot }
    private var hasTrack: Bool { snap?.hasTrack == true }
    private var showsLyrics: Bool { viewModel.desktopLyricsEnabled && hasTrack }
    private var canControl: Bool { snap?.source.isControllable ?? true }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded { lyricsArea.transition(.opacity) }
            progress.padding(.top, 14)
            controls.padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: Self.width, height: Self.height + (expanded ? Self.lyricsHeight : 0),
               alignment: .top)
        .background(glass)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        // The window is already tall while the strip grows; below the bar is clear.
        .frame(maxHeight: .infinity, alignment: .top)
        // Initial too: switching design builds this view with lyrics already on,
        // and waiting for a change left the strip shut until toggled off and on.
        .onChange(of: showsLyrics, initial: true) { _, on in
            if on {
                _ = onLyricsShown(true)
                withAnimation(Self.stripMove) { expanded = true }
            } else {
                withAnimation(Self.stripMove) { expanded = false } completion: {
                    if !showsLyrics { _ = onLyricsShown(false) }
                }
            }
        }
        .lyricsLookup(enabled: viewModel.desktopLyricsEnabled, snapshot: snap,
                      lines: $lyrics, loading: $lyricsLoading)
        .contextMenu {
            Button(L10n.tr("ตั้งค่า…", "Settings…")) { AppDelegate.shared?.openSettings() }
            Button(L10n.tr("ปิด mini player บน desktop", "Close desktop player")) {
                SettingsStore.shared.merge(["miniplayer": ["desktop_enabled": false]])
            }
        }
    }

    /// Glass over a dark wash: the text is all white, and glass alone over a
    /// light wallpaper leaves it unreadable (same recipe as the lock screen card).
    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return shape
            .fill(.black.opacity(0.3))
            .glassEffect(Glass.regular.tint(.white.opacity(0.04)), in: shape)
    }

    // MARK: - Rows

    private var header: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: hasTrack ? (snap?.title ?? "") : L10n.miniplayerNoTrack,
                            font: .system(size: 16, weight: .semibold),
                            color: .white)
                MarqueeText(text: snap?.artist ?? "",
                            font: .system(size: 13, weight: .medium),
                            color: .white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WaveBars(active: snap?.isPlaying == true)
        }
    }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let s = viewModel.artwork.artworkURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.1)
                        }
                    }
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { expandButton }

            // Which player it is, where the app badge sits on the system's own.
            if let snap, hasTrack {
                Image(systemName: snap.source.sfSymbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.55)))
                    .padding(4)
                    .opacity(hoveringCover ? 0 : 1)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hoveringCover = inside }
        }
    }

    /// On hover, the cover turns into the way to the artwork card.
    @ViewBuilder
    private var expandButton: some View {
        if hoveringCover {
            Button {
                SettingsStore.shared.merge(["miniplayer": ["desktop_style": "card"]])
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.45))
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("ขยายเป็นการ์ดปกเต็ม", "Expand to artwork card"))
            .transition(.opacity)
        } else {
            Color.clear
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var lyricsArea: some View {
        if let snap {
            Group {
                if lyrics.isEmpty {
                    LyricsStatusView(loading: lyricsLoading)
                } else {
                    FullscreenLyricsView(lines: lyrics, playback: snap, fontSize: 13, spacing: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .padding(.top, 12)
        }
    }

    private var progress: some View {
        let duration = snap?.duration ?? 0
        let position = snap?.position ?? 0
        let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
        return HStack(spacing: 10) {
            Text(Self.time(position))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            Text("-" + Self.time(max(0, duration - position)))
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.8))
    }

    private var controls: some View {
        HStack {
            sideButton(icon: viewModel.desktopLyricsEnabled ? "quote.bubble.fill" : "quote.bubble",
                       active: viewModel.desktopLyricsEnabled, action: viewModel.toggleDesktopLyrics)
                .disabled(!hasTrack)
            Spacer()
            HStack(spacing: 28) {
                transportButton("backward.fill", size: 20, action: viewModel.previous)
                transportButton(snap?.isPlaying == true ? "pause.fill" : "play.fill",
                                size: 26, action: viewModel.playPause)
                    .frame(width: 28)
                transportButton("forward.fill", size: 20, action: viewModel.next)
            }
            .disabled(!canControl)
            .opacity(canControl ? 1 : 0.35)
            Spacer()
            // Up to the artwork card — mirrors the card's own shrink button.
            sideButton(icon: "rectangle.expand.vertical", active: false) {
                SettingsStore.shared.merge(["miniplayer": ["desktop_style": "card"]])
            }
            .help(L10n.tr("ขยายเป็นการ์ดปกเต็ม", "Expand to artwork card"))
        }
    }

    private func transportButton(_ icon: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A filled circle marks the one that's on.
    private func sideButton(icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(active ? 0.22 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Five bars off the live audio tap, flat while paused.
private struct WaveBars: View {
    let active: Bool
    @ObservedObject private var audio = MusicAudioLevelMonitor.shared
    private let count = 5
    private let barW: CGFloat = 2.5
    private let spacing: CGFloat = 2

    // One Canvas pass rather than five views diffing every audio frame.
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<count {
                let v = active && i * 2 < audio.bands.count
                    ? CGFloat(min(1, max(0, audio.bands[i * 2]))) : 0
                let h = 4 + v * (size.height - 4)
                let rect = CGRect(x: CGFloat(i) * (barW + spacing), y: (size.height - h) / 2,
                                  width: barW, height: h)
                ctx.fill(Capsule().path(in: rect), with: .color(.white.opacity(0.75)))
            }
        }
        .frame(width: CGFloat(count) * barW + CGFloat(count - 1) * spacing, height: 16)
        .onAppear { MusicAudioLevelMonitor.shared.start() }
    }
}

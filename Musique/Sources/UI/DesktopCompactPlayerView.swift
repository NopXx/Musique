import SwiftUI
import AppKit

/// The desktop panel's compact design: a glass bar with a small cover, title,
/// artist and a live waveform, a progress row, and the transport — the third
/// `miniplayer.desktop_style` (`compact`). Lyrics grow the window downward by
/// a strip under the transport, the same way the card grows sideways.
/// The cover's hover button opens the artwork full height on the bar's left:
/// the window widens by `artworkGrowth` (rightward, or leftward when the
/// screen has no room) and the controls tighten up beside it.
struct DesktopCompactPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    var onLyricsShown: (Bool) -> Bool = { _ in false }
    /// Asks the controller to widen the window for the artwork panel; returns
    /// whether it grew to the left, so the bar can stay pinned to its own side.
    var onArtworkShown: (Bool) -> Bool = { _ in false }
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false
    /// Lags `showsLyrics` on the way in (window first) and leads it on the way
    /// out (strip first), as in `DesktopPlayerView`.
    @State private var expanded = false
    @State private var hoveringCover = false
    /// What the user asked for. `artworkExpanded` drives the layout and
    /// follows it as `expanded` follows the lyrics: window first on the way in,
    /// panel first on the way out.
    @State private var artworkShown = false
    @State private var artworkExpanded = false
    @State private var grewLeft = false
    @State private var hoveringArtwork = false

    static let width: CGFloat = 340
    /// How much wider the bar gets while the artwork panel is out.
    static let artworkGrowth: CGFloat = 80
    static let height: CGFloat = 166
    static let lyricsHeight: CGFloat = 112
    /// The artwork panel: square to the bar without lyrics.
    static let artworkWidth: CGFloat = height
    private static let coverSize: CGFloat = 56
    private static let artworkMove = Animation.easeInOut(duration: 0.3)
    private static let corner: CGFloat = 24
    private static let stripMove = Animation.easeInOut(duration: 0.28)

    private var snap: NowPlayingSnapshot? { viewModel.snapshot }
    private var hasTrack: Bool { snap?.hasTrack == true }
    private var showsLyrics: Bool { viewModel.desktopLyricsEnabled && hasTrack }
    private var canControl: Bool { snap?.source.isControllable ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if artworkExpanded {
                    artworkPanel
                        .frame(width: Self.artworkWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    header
                    sourceLabel.padding(.top, 8)
                    progress.padding(.top, 6)
                    controls.padding(.top, 10)
                }
                .padding(.horizontal, artworkExpanded ? 14 : 18)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }
            .frame(height: Self.height)
            // Lyrics under everything, the full width of the bar — below the
            // artwork panel too, which stays a square.
            if expanded { lyricsArea.transition(.opacity) }
        }
        .frame(width: Self.width + (artworkExpanded ? Self.artworkGrowth : 0),
               height: Self.height + (expanded ? Self.lyricsHeight : 0),
               alignment: .top)
        .background(glass)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        // The window is already tall (or wide) while a panel grows; the bar is
        // pinned to the side the window didn't grow from, so it doesn't move.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: grewLeft ? .topTrailing : .topLeading)
        .onChange(of: artworkShown) { _, on in
            if on {
                grewLeft = onArtworkShown(true)
                // After the window has grown, as with the lyrics below.
                DispatchQueue.main.async {
                    withAnimation(Self.artworkMove) { artworkExpanded = true }
                }
            } else {
                withAnimation(Self.artworkMove) { artworkExpanded = false } completion: {
                    if !artworkShown { _ = onArtworkShown(false) }
                }
            }
        }
        // Nothing to show once the track is gone.
        .onChange(of: hasTrack) { _, has in if !has { artworkShown = false } }
        // Initial too: switching design builds this view with lyrics already on,
        // and waiting for a change left the strip shut until toggled off and on.
        .onChange(of: showsLyrics, initial: true) { _, on in
            if on {
                _ = onLyricsShown(true)
                // After the window has grown (the controller resizes on the next
                // turn). Animating first made the content taller than the window,
                // which centres it: the bar jumped up and dropped back.
                DispatchQueue.main.async {
                    withAnimation(Self.stripMove) { expanded = true }
                }
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

    /// Plain system glass, so the Liquid Glass Clear–Tinted setting in System
    /// Settings carries through; a black wash under it held the bar near-opaque
    /// whatever that was set to. Dark scheme instead, so the all-white text
    /// still reads over a light wallpaper.
    private var glass: some View {
        Color.clear
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    // MARK: - Rows

    private var header: some View {
        HStack(spacing: 12) {
            if !artworkExpanded { cover.transition(.opacity) }
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
        // The cover's height, kept while the cover is out in the artwork panel,
        // so the progress row and transport don't ride up.
        .frame(height: Self.coverSize)
    }

    private var cover: some View {
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
        .frame(width: Self.coverSize, height: Self.coverSize)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { expandButton }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hoveringCover = inside }
        }
    }

    /// On hover, the cover turns into the way to the artwork panel beside the
    /// bar. The card design has its own button in the corner.
    @ViewBuilder
    private var expandButton: some View {
        if hoveringCover {
            Button {
                hoveringCover = false
                artworkShown = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.45))
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help(L10n.tr("ขยายปก", "Expand artwork"))
            .transition(.opacity)
        } else {
            Color.clear
                .contentShape(Rectangle())
        }
    }

    /// The cover, full height on the bar's left. Motion artwork plays here as on
    /// the card. The hover button (or a click) puts it away.
    private var artworkPanel: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Color(viewModel.palette.gradientMid)
                if viewModel.miniplayerAnimation != "off",
                   let s = viewModel.artwork.animationURL, !s.isEmpty, let url = URL(string: s) {
                    AnimatedArtworkView(url: url, contentMode: .fill)
                } else if let s = viewModel.artwork.artworkURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { artworkShown = false }

            if hoveringArtwork {
                Button { artworkShown = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.5)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(L10n.tr("ย่อปก", "Collapse artwork"))
                .transition(.opacity)
            }
        }
        // Inset from the bar's edge, so the cover reads as a card in the glass.
        .padding(12)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hoveringArtwork = inside }
        }
    }

    @ViewBuilder
    private var lyricsArea: some View {
        if let snap {
            Group {
                if lyrics.isEmpty {
                    LyricsStatusView(loading: lyricsLoading)
                } else {
                    FullscreenLyricsView(lines: lyrics, playback: snap, fontSize: 13, spacing: 5,
                                         // Four ~21pt rows in 100pt: the sung one third, so two
                                         // lines of what was sung show above it.
                                         anchor: 0.55)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.lyricsHeight - 12)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    /// Which player it is, above the time row as on the artwork card. Off the
    /// cover, so it stays put when the cover moves out to the artwork panel.
    /// Keeps its height with no track, so the rows below don't move.
    private var sourceLabel: some View {
        Label(snap?.source.displayName ?? " ", systemImage: snap?.source.sfSymbol ?? "music.note")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            .opacity(hasTrack ? 1 : 0)
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
            Spacer(minLength: 0)
            // Tighter beside the artwork panel, where the column is ~240pt.
            HStack(spacing: artworkExpanded ? 12 : 28) {
                transportButton("backward.fill", size: artworkExpanded ? 15 : 20, action: viewModel.previous)
                transportButton(snap?.isPlaying == true ? "pause.fill" : "play.fill",
                                size: artworkExpanded ? 20 : 26, action: viewModel.playPause)
                    .frame(width: artworkExpanded ? 22 : 28)
                transportButton("forward.fill", size: artworkExpanded ? 15 : 20, action: viewModel.next)
            }
            .disabled(!canControl)
            .opacity(canControl ? 1 : 0.35)
            Spacer(minLength: 0)
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

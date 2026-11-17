import SwiftUI
import AppKit

/// The desktop panel's player: a square card, the cover filling it edge to
/// edge and fading into its own colour at the bottom, where the title and the
/// transport sit. The menu bar popover keeps `MiniPlayerView`; this one is only
/// what `DesktopMiniPlayerController` hosts.
///
/// Lyrics don't go on the cover: the window grows a panel to the *right* of the
/// card for them, and `onLyricsShown` is how the controller learns to resize it.
struct DesktopPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    /// Returns whether the window grew leftward (no room on the right), so the
    /// panel goes on the card's left and the card itself stays where it was.
    var onLyricsShown: (Bool) -> Bool = { _ in false }
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false
    /// Drives the panel's width. Lags `showsLyrics` on the way in (window first,
    /// then the panel slides open) and leads it on the way out (panel first, then
    /// the window shrinks) — an animated window resize made the card jump.
    @State private var expanded = false
    @State private var panelOnLeft = false
    /// Controls show only under the pointer; at rest the card is cover + title.
    @State private var hovering = false
    @State private var controlsHeight: CGFloat = 0
    private static let hoverMove = Animation.spring(response: 0.45, dampingFraction: 0.86)

    static let size: CGFloat = 340
    /// The lyrics panel beside the card.
    static let lyricsWidth: CGFloat = 300

    private var snap: NowPlayingSnapshot? { viewModel.snapshot }
    private var hasTrack: Bool { snap?.hasTrack == true }
    private var showsLyrics: Bool { viewModel.desktopLyricsEnabled && hasTrack }
    private var canControl: Bool { snap?.source.isControllable ?? true }


    var body: some View {
        HStack(spacing: 0) {
            if panelOnLeft { lyricsPanel }
            ZStack(alignment: .bottom) {
                artwork
                bottomFade
                content
            }
            .frame(width: Self.size, height: Self.size)
            .onHover { inside in
                withAnimation(Self.hoverMove) { hovering = inside }
            }
            if !panelOnLeft { lyricsPanel }
        }
        .frame(width: Self.size + (expanded ? Self.lyricsWidth : 0), height: Self.size,
               alignment: cardSide)
        .background(stripColor)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        // The window is already wide while the panel grows; the card is pinned to
        // its own side of it, so it never moves on screen.
        .frame(maxWidth: .infinity, alignment: cardSide)
        .animation(.easeInOut(duration: 0.7), value: viewModel.palette.accent)
        // Initial too: switching design builds this view with lyrics already on,
        // and waiting for a change left the strip shut until toggled off and on.
        .onChange(of: showsLyrics, initial: true) { _, on in
            if on {
                panelOnLeft = onLyricsShown(true)
                // After the window has grown (the controller resizes on the next
                // turn too): animating while it moved slid the card across it.
                DispatchQueue.main.async {
                    withAnimation(Self.stripMove) { expanded = true }
                }
            } else {
                withAnimation(Self.stripMove) { expanded = false } completion: {
                    if !showsLyrics { _ = onLyricsShown(false) }
                }
            }
        }
        .contextMenu {
            Button(L10n.tr("ตั้งค่า…", "Settings…")) { AppDelegate.shared?.openSettings() }
            Button(L10n.tr("ปิด mini player บน desktop", "Close desktop player")) {
                SettingsStore.shared.merge(["miniplayer": ["desktop_enabled": false]])
            }
        }
        .lyricsLookup(enabled: viewModel.desktopLyricsEnabled, snapshot: snap,
                      lines: $lyrics, loading: $lyricsLoading)
    }

    // MARK: - Layers

    @ViewBuilder
    private var artwork: some View {
        ZStack {
            Color(viewModel.palette.gradientMid)
            if viewModel.miniplayerAnimation != "off",
               let s = viewModel.artwork.animationURL, !s.isEmpty, let url = URL(string: s) {
                AnimatedArtworkView(url: url, contentMode: .fill)
            } else if let s = viewModel.artwork.artworkURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipped()
    }

    /// The cover dissolving into its own colour, so the text below reads on
    /// any sleeve. Palette tint over a dark base, the same recipe the mini
    /// player's bottom fade uses.
    private var bottomFade: some View {
        LinearGradient(colors: [.clear, shade.opacity(0.75), shade],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: Self.size * 0.55)
            // Scale, not height: a changing frame relaid the card out every frame.
            .scaleEffect(x: 1, y: hovering ? 1 : 0.64, anchor: .bottom)
            .allowsHitTesting(false)
    }

    /// The cover's colour pulled well toward black, so white text reads on it
    /// whatever the sleeve. Tinting with the raw palette colour left a white
    /// cover's fade (and the lyrics strip) near-white, and the text vanished.
    private var shade: Color {
        Color(viewModel.palette.gradientStart.blended(withFraction: 0.6, of: .black)
              ?? .black)
    }

    /// Exactly the colour the card's bottom fade ends on, so the panel reads as
    /// the card carrying on rather than a second window.
    private var stripColor: some View { shade }

    private static let stripMove = Animation.easeInOut(duration: 0.28)

    private var cardSide: Alignment { panelOnLeft ? .trailing : .leading }

    @ViewBuilder
    private var lyricsPanel: some View {
        if expanded, showsLyrics, let snap {
            Group {
                if lyrics.isEmpty {
                    LyricsStatusView(loading: lyricsLoading)
                } else {
                    FullscreenLyricsView(lines: lyrics, playback: snap, fontSize: 18, spacing: 10,
                                         anchor: 0.5)
                }
            }
                .frame(width: Self.lyricsWidth - 40, height: Self.size - 40)
                .padding(20)
                .transition(.opacity)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: hasTrack ? (snap?.title ?? "") : L10n.miniplayerNoTrack,
                            font: .system(size: 22, weight: .bold),
                            color: .white)
                MarqueeText(text: snap?.artist ?? "",
                            font: .system(size: 17, weight: .medium),
                            color: .white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // At rest the title sits where the controls would be. A transform, not
            // a relayout: inserting/removing the row made the title jump.
            .offset(y: hovering ? 0 : controlsHeight)

            VStack(spacing: 0) {
                if let snap, hasTrack {
                    Label(snap.source.displayName, systemImage: snap.source.sfSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 10)
                }

                HStack {
                    sideButton(icon: viewModel.desktopLyricsEnabled ? "quote.bubble.fill" : "quote.bubble",
                               active: viewModel.desktopLyricsEnabled, action: viewModel.toggleDesktopLyrics)
                        .disabled(!hasTrack)
                    Spacer()
                    transport
                    Spacer()
                    // Back to the glass bar — the card's way down, as the bar's cover
                    // is its way up.
                    sideButton(icon: "rectangle.compress.vertical", active: false) {
                        SettingsStore.shared.merge(["miniplayer": ["desktop_style": "compact"]])
                    }
                    .help(L10n.tr("ย่อเป็นแถบกระจก", "Shrink to glass bar"))
                }
                .padding(.top, 14)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
            .opacity(hovering ? 1 : 0)
            .offset(y: hovering ? 0 : 16)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private var transport: some View {
        HStack(spacing: 30) {
            transportButton("backward.fill", size: 22, action: viewModel.previous)
            transportButton(snap?.isPlaying == true ? "pause.fill" : "play.fill",
                            size: 32, action: viewModel.playPause)
                .frame(width: 34)
            transportButton("forward.fill", size: 22, action: viewModel.next)
        }
        .disabled(!canControl)
        .opacity(canControl ? 1 : 0.35)
    }

    private func transportButton(_ icon: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Edge buttons; a filled circle marks the one that's on.
    private func sideButton(icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.8))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(active ? 0.22 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

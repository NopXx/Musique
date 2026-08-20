import SwiftUI
import AppKit

struct AnimationFullscreenView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    /// The mini player's overlay is a glance you dismiss with a click anywhere.
    /// The desktop window owns a Space, so a stray click on a full screen of
    /// cover art must not end it — there the corner button and Esc are the way out.
    var dismissOnTap: Bool = false
    let onDismiss: () -> Void

    private var animationURL: URL? {
        let s = viewModel.artwork.animationSquareUltraURL ?? viewModel.artwork.animationURL
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var artworkURL: URL? {
        guard let s = viewModel.artwork.artworkURL, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // The clock and card share the lock screen's settings so there's one place to
    // configure them, read live rather than mirrored onto the view model — this
    // window is short-lived and rebuilt on every present.
    private var settings: SettingsStore { .shared }
    private var clockEnabled: Bool { settings.bool(["lockscreen", "clock"]) }
    private var clockFormat: String {
        let f = settings.string(["lockscreen", "clock_format"]); return f.isEmpty ? "system" : f
    }
    private var clockDateStyle: String {
        let s = settings.string(["lockscreen", "clock_date_style"]); return s.isEmpty ? "full" : s
    }
    private var showAlbum: Bool { settings.bool(["lockscreen", "show_album"]) }
    private var showProgress: Bool { settings.bool(["lockscreen", "show_progress"]) }
    private var padding: CGFloat { CGFloat(settings.int(["lockscreen", "padding"])) }
    private var clockSize: CGFloat {
        let pt = settings.int(["lockscreen", "clock_size"])
        return CGFloat(pt > 0 ? pt : 96)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Same component the lock screen overlay draws, so the fullscreen
                // cover looks identical locked and unlocked.
                FullscreenArtworkView(artworkURL: artworkURL,
                                      clipURL: animationURL,
                                      palette: viewModel.palette,
                                      backgroundBlur: settings.int(["lockscreen", "background_blur"]))

                // Clock + date pinned to the top, over the artwork — the same block
                // the lock screen draws. Gated on the same lockscreen.clock setting.
                if clockEnabled {
                    LockScreenClockView(timeFormat: clockFormat, dateStyle: clockDateStyle,
                                        size: clockSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, padding + 40)
                        .allowsHitTesting(false)
                }

                // Now-playing card at the bottom — reuses the lock screen card, so the
                // title/artist, progress and transport all come along. The big artwork
                // is already on screen, so the card's inline thumbnail is off.
                if let snap = viewModel.snapshot, snap.hasTrack {
                    NowPlayingCard(
                        snap: snap,
                        showAlbum: showAlbum,
                        showProgress: showProgress,
                        width: min(380, geo.size.width * 0.36),
                        artworkImage: nil,
                        animatedURL: nil,
                        animatedArtwork: false,
                        showInlineArtwork: false,
                        onArtworkTap: {}
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // Lifted off the bottom edge — the lock screen's own padding
                    // sits the card lower than reads well on a full desktop.
                    .padding(.bottom, padding + 56)
                }

                // Window chrome, not track chrome: leaving fullscreen belongs to
                // the window, so it sits in its corner rather than inside the
                // now-playing card.
                GlassPill {
                    FullscreenGlyph(systemName: "xmark", size: 15, action: onDismiss)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if dismissOnTap {
                    Text("กดเพื่อปิด")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if dismissOnTap { onDismiss() } }
        // Space toggles playback, the way every fullscreen player on the platform
        // behaves. Needs focus to receive the key, and the ring would draw over the
        // artwork — both windows are borderless-looking, so there is nothing for a
        // ring to sit on anyway.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            MusicAppController.playPause()
            return .handled
        }
        // Esc goes through onKeyPress too, not onExitCommand: in a native-fullscreen
        // window AppKit takes cancelOperation: for its own "leave fullscreen", so the
        // SwiftUI hook never sees the key.
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onChange(of: viewModel.snapshot?.hasTrack ?? false) { _, hasTrack in
            if !hasTrack { onDismiss() }
        }
    }

}

/// The card's glass, reused for the corner control so the window chrome matches
/// the thing it frames.
private struct GlassPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.35))
                    .glassEffect(Glass.clear.tint(.white.opacity(0.05)), in: Capsule(style: .continuous))
                    .opacity(0.6)
            )
    }
}

/// `ControlGlyph` in LockScreenPlayerView is private to that file; this is the
/// same press behaviour for the chrome.
private struct FullscreenGlyph: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        let side = size * 1.6
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(pressed ? 0.7 : 1))
            .frame(width: side, height: side)
            .background(Circle().fill(.white.opacity(pressed ? 0.18 : 0)))
            .scaleEffect(pressed ? 0.86 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.6), value: pressed)
            .contentShape(Circle())
            .gesture(
                // minimumDistance 0 so the press lands on mouse-down. Fires the
                // action itself rather than pairing with onTapGesture — a
                // zero-distance drag swallows the tap.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        guard CGRect(x: 0, y: 0, width: side, height: side)
                            .contains(value.location) else { return }
                        action()
                    }
            )
    }
}

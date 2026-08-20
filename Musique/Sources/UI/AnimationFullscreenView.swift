import SwiftUI
import AppKit

struct AnimationFullscreenView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
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
                    .padding(.bottom, padding)
                }

                Text("กดเพื่อปิด")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onExitCommand { onDismiss() }
        .onChange(of: viewModel.snapshot?.hasTrack ?? false) { _, hasTrack in
            if !hasTrack { onDismiss() }
        }
    }

}

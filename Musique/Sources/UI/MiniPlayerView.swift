import SwiftUI
import AppKit

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    @State private var showEditPopover: Bool = false

    private var animationsOn: Bool { viewModel.miniplayerAnimation != "off" }
    private var hasAnimation: Bool {
        guard let s = viewModel.artwork.animationURL, !s.isEmpty else { return false }
        return true
    }
    private var hasTallVideo: Bool {
        animationsOn
        && viewModel.miniplayerAnimation == "full"
        && (viewModel.artwork.animationTallURL?.isEmpty == false)
        && (viewModel.snapshot?.hasTrack == true)
    }

    var body: some View {
        Group {
            if viewModel.artworkStyle == "fullbleed" {
                fullBleedLayout
            } else if hasTallVideo {
                tallLayout
            } else {
                squareLayout
            }
        }
        .frame(width: 320, height: 505)
        .clipped()
        .overlay { editOverlay }
        .animation(.easeInOut(duration: 0.7), value: viewModel.palette.accent)
    }

    /// In-panel edit sheet. Presented as an overlay inside the mini player's own
    /// hosting view rather than a SwiftUI `.popover` — a popover anchored to a
    /// view that itself lives inside the menu bar's transient NSPopover throws
    /// during `NSPopover.show` and crashes the app.
    @ViewBuilder
    private var editOverlay: some View {
        if showEditPopover {
            ZStack {
                Color.black.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { showEditPopover = false }
                EditTrackPopover(viewModel: viewModel, isPresented: $showEditPopover)
                    .frame(width: 290)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            }
            .transition(.opacity)
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Layout 1 — Classic square (artwork in middle, like original)
    // ═════════════════════════════════════════════════════════════

    @ViewBuilder
    private var squareLayout: some View {
        ZStack {
            blurredBackdrop
            VStack(spacing: 0) {
                squareArtwork
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                Spacer(minLength: 0)
            }
            bottomFade
            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    HStack { sourceBadge(); Spacer() }
                        .padding(.bottom, 6)
                    MarqueeText(text: viewModel.snapshot?.title.nilIfEmpty ?? L10n.miniplayerNoTrack,
                                font: .system(size: 17, weight: .bold),
                                color: .white)
                    MarqueeText(text: metaLine(),
                                font: .system(size: 13, weight: .medium),
                                color: .white.opacity(0.65))
                        .padding(.top, 4)
                    VStack(spacing: 5) {
                        progressBar(height: 4)
                        HStack {
                            Text(timeString(viewModel.snapshot?.position ?? 0))
                            Text(scrobbleStatusText())
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(viewModel.hasScrobbled
                                                 ? Color(viewModel.palette.accent)
                                                 : .white.opacity(0.4))
                            Text(remainingString())
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .monospacedDigit()
                    }
                    .padding(.top, 12)
                    HStack {
                        Spacer()
                        transportButton(icon: "backward.fill", size: 18, action: viewModel.previous)
                        Spacer()
                        Button(action: viewModel.playPause) {
                            Image(systemName: viewModel.snapshot?.isPlaying == true ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        transportButton(icon: "forward.fill", size: 18, action: viewModel.next)
                        Spacer()
                    }
                    .padding(.top, 10)
                    HStack {
                        Spacer()
                        sourceMenuButton()
                        footerButton(icon: "pencil", action: openEdit)
                            .disabled(viewModel.snapshot?.hasTrack != true)
                        footerButton(icon: fullscreenIcon, action: openDesktopFullscreen)
                            .disabled(viewModel.snapshot?.hasTrack != true)
                        footerButton(icon: "gearshape.fill", action: openSettings)
                        footerButton(icon: viewModel.notificationsEnabled ? "bell.fill" : "bell.slash.fill",
                                     active: viewModel.notificationsEnabled,
                                     action: viewModel.toggleNotifications)
                        footerButton(icon: "power", action: quit)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private var blurredBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(viewModel.palette.gradientStart),
                    Color(viewModel.palette.gradientMid),
                    Color(viewModel.palette.gradientEnd),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            if let s = viewModel.artwork.artworkURL, let u = URL(string: s) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 60)
                            .saturation(2.4)
                            .brightness(-0.15)
                            .opacity(0.78)
                    }
                }
                .frame(width: 320, height: 505)
                .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var squareArtwork: some View {
        ZStack {
            if animationsOn,
               let s = viewModel.artwork.animationURL, !s.isEmpty,
               let url = URL(string: s) {
                AnimatedArtworkView(url: url, contentMode: .fill, cornerRadius: 14)
            } else if let s = viewModel.artwork.artworkURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    )
            }
        }
        .frame(width: 272, height: 272)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            motionBadge
                .padding(10)
        }
        .shadow(color: .black.opacity(0.55), radius: 20, x: 0, y: 16)
        .onTapGesture { openFullscreenAnimation() }
    }

    @ViewBuilder
    private var trackInfoCentered: some View {
        VStack(spacing: 4) {
            sourceBadge()
            MarqueeText(text: viewModel.snapshot?.title.nilIfEmpty ?? L10n.miniplayerNoTrack,
                        font: .system(size: 17, weight: .bold),
                        color: .white)
            MarqueeText(text: metaLine(),
                        font: .system(size: 13),
                        color: .white.opacity(0.65))
        }
    }

    @ViewBuilder
    private var squareControls: some View {
        HStack(spacing: 28) {
            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            ZStack {
                Circle().fill(Color.white).frame(width: 52, height: 52)
                Image(systemName: viewModel.snapshot?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
            }
            .onTapGesture { viewModel.playPause() }
            Button(action: viewModel.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack {
            Text("MUSIQUE")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            sourceMenuButton()
            iconButton("pencil", action: openEdit)
                .disabled(viewModel.snapshot?.hasTrack != true)
            iconButton(fullscreenIcon, action: openDesktopFullscreen)
                .disabled(viewModel.snapshot?.hasTrack != true)
            iconButton("gearshape.fill", action: openSettings)
            iconButton(viewModel.notificationsEnabled ? "bell.fill" : "bell.slash.fill",
                       active: viewModel.notificationsEnabled,
                       action: viewModel.toggleNotifications)
            iconButton("power", action: quit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func iconButton(_ name: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color(viewModel.palette.accent) : .white.opacity(0.65))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var progressRow: some View {
        VStack(spacing: 6) {
            progressBar(height: 3)
            HStack {
                Text(timeString(viewModel.snapshot?.position ?? 0))
                Spacer()
                Text(remainingString())
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .monospacedDigit()
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Layout 2 — Tall mode (portrait video full-bleed)
    // ═════════════════════════════════════════════════════════════

    @ViewBuilder
    private var tallLayout: some View {
        ZStack {
            baseGradient
            VStack(spacing: 0) {
                if let s = viewModel.artwork.animationTallURL, let u = URL(string: s) {
                    AnimatedArtworkView(url: u, contentMode: .fit)
                        .frame(height: 505 * 0.85)
                        .mask(
                            VStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(
                                    colors: [.white, .white.opacity(0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                                .frame(height: 250)
                            }
                        )
                }
                Spacer(minLength: 0)
            }
            bottomFade
            VStack(spacing: 0) {
                Spacer()
                immersiveContent
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Layout 3 — Full-bleed (always full-bleed media, optional)
    // ═════════════════════════════════════════════════════════════

    @ViewBuilder
    private var fullBleedLayout: some View {
        ZStack {
            baseGradient
            VStack(spacing: 0) {
                fullBleedMedia
                    .frame(width: 320, height: 505 * 0.85)
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: [.white, .white.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: 250)
                        }
                    )
                Spacer(minLength: 0)
            }
            bottomFade
            VStack(spacing: 0) {
                Spacer()
                immersiveContent
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private var fullBleedMedia: some View {
        if animationsOn,
           viewModel.miniplayerAnimation == "full",
           let s = viewModel.artwork.animationTallURL, !s.isEmpty,
           let url = URL(string: s) {
            AnimatedArtworkView(url: url, contentMode: .fit)
        } else if animationsOn,
                  let s = viewModel.artwork.animationURL, !s.isEmpty,
                  let url = URL(string: s) {
            AnimatedArtworkView(url: url, contentMode: .fill)
        } else if let s = viewModel.artwork.artworkURL, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.2)
                }
            }
            .clipped()
        } else {
            ZStack {
                Color.black.opacity(0.2)
                Image(systemName: "music.note")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Shared pieces for tall/full-bleed
    // ═════════════════════════════════════════════════════════════

    @ViewBuilder
    private var baseGradient: some View {
        LinearGradient(
            colors: [
                Color(viewModel.palette.gradientMid),
                Color(viewModel.palette.gradientMid),
                Color(viewModel.palette.gradientEnd),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var bottomFade: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                // Dark base — guarantees text readability on light artwork
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.05),
                        .black.opacity(0.12),
                        .black.opacity(0.25),
                        .black.opacity(0.45),
                        .black.opacity(0.65),
                        .black.opacity(0.85),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                // Palette tint on top — lowered opacity to let dark base through
                LinearGradient(
                    colors: [
                        .clear,
                        Color(viewModel.palette.gradientStart).opacity(0.0),
                        Color(viewModel.palette.gradientStart).opacity(0.15),
                        Color(viewModel.palette.gradientStart).opacity(0.3),
                        Color(viewModel.palette.gradientStart).opacity(0.45),
                        Color(viewModel.palette.gradientStart).opacity(0.55),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(height: 320)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var immersiveContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) { sourceBadge(); motionBadge; Spacer() }
                .padding(.bottom, 8)
            MarqueeText(text: viewModel.snapshot?.title.nilIfEmpty ?? L10n.miniplayerNoTrack,
                        font: .system(size: 20, weight: .heavy),
                        color: .white)

            MarqueeText(text: metaLine(),
                        font: .system(size: 15, weight: .medium),
                        color: .white.opacity(0.55))
                .padding(.top, 3)

            VStack(spacing: 6) {
                progressBar(height: 5)
                HStack {
                    Text(timeString(viewModel.snapshot?.position ?? 0))
                    Text(scrobbleStatusText())
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(viewModel.hasScrobbled
                                         ? Color(viewModel.palette.accent)
                                         : .white.opacity(0.4))
                    Text(remainingString())
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .monospacedDigit()
            }
            .padding(.top, 16)

            HStack {
                Spacer()
                transportButton(icon: "backward.fill", size: 22, action: viewModel.previous)
                Spacer()
                Button(action: viewModel.playPause) {
                    Image(systemName: viewModel.snapshot?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
                transportButton(icon: "forward.fill", size: 22, action: viewModel.next)
                Spacer()
            }
            .padding(.top, 14)

            HStack {
                Spacer()
                sourceMenuButton()
                footerButton(icon: "pencil", action: openEdit)
                    .disabled(viewModel.snapshot?.hasTrack != true)
                footerButton(icon: fullscreenIcon, action: openDesktopFullscreen)
                    .disabled(viewModel.snapshot?.hasTrack != true)
                footerButton(icon: "gearshape.fill", action: openSettings)
                footerButton(icon: viewModel.notificationsEnabled ? "bell.fill" : "bell.slash.fill",
                             active: viewModel.notificationsEnabled,
                             action: viewModel.toggleNotifications)
                footerButton(icon: "power", action: quit)
                Spacer()
            }
            .padding(.top, 10)
        }
    }

    private func transportButton(icon: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func footerButton(icon: String, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color(viewModel.palette.accent) : .white.opacity(0.55))
                .frame(width: 36, height: 28)
        }
        .buttonStyle(.plain)
    }

    /// Dropdown that lists every tracked source with its current track, and lets
    /// the user switch which player the mini player follows.
    private func sourceMenuButton() -> some View {
        Menu {
            ForEach(viewModel.sourceItems) { item in
                Button {
                    viewModel.selectSource(item.source)
                } label: {
                    let detail: String = {
                        guard let snap = item.snapshot, snap.hasTrack else {
                            return L10n.tr("ไม่ได้เล่น", "Not playing")
                        }
                        let state = snap.isPlaying ? "▶" : "⏸"
                        return "\(state) \(snap.title) — \(snap.artist)"
                    }()
                    Text("\(item.displayName)\n\(detail)")
                    Image(systemName: item.isActive ? "checkmark.circle.fill" : item.source.sfSymbol)
                }
                .disabled(item.snapshot == nil)
            }
        } label: {
            Image(systemName: viewModel.activeSource.sfSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 36, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 28)
        .fixedSize()
    }

    // ═════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════

    private func progressBar(height: CGFloat) -> some View {
        let dur = viewModel.snapshot?.duration ?? 0
        let pos = viewModel.snapshot?.position ?? 0
        let pct = dur > 0 ? min(1.0, max(0, pos / dur)) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white.opacity(0.78))
                    .frame(width: geo.size.width * pct)
            }
        }
        .frame(height: height)
    }

    private func scrobbleStatusText() -> String {
        let snap = viewModel.snapshot
        let hasTrack = snap?.hasTrack == true
        let dur = snap?.duration ?? 0
        if !hasTrack { return "" }
        if viewModel.hasScrobbled { return "✓ Scrobbled" }
        if dur > 0 && dur <= 30 { return L10n.miniplayerTrackTooShort }
        return "Scrobble · \(Int(viewModel.scrobblePercent))%"
    }

    private func metaLine() -> String {
        guard let snap = viewModel.snapshot, snap.hasTrack else {
            return L10n.miniplayerOpenMusic
        }
        switch viewModel.miniplayerMeta {
        case "artist": return snap.artist
        case "album":  return snap.album.nilIfEmpty ?? snap.artist
        default:       return snap.album.isEmpty ? snap.artist : "\(snap.artist) — \(snap.album)"
        }
    }

    private func remainingString() -> String {
        let dur = viewModel.snapshot?.duration ?? 0
        return dur > 0 ? timeString(dur) : "0:00"
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func openSettings() { AppDelegate.shared?.openSettings() }
    private func quit() { NSApp.terminate(nil) }
    private func openEdit() { showEditPopover = true }
    /// Icon flips while the desktop fullscreen Space is up, so the same button
    /// reads as the way back out.
    private var fullscreenIcon: String {
        AppDelegate.shared?.menuBarController?.desktopFullscreenPresented == true
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
    }

    private func openDesktopFullscreen() {
        AppDelegate.shared?.menuBarController?.toggleDesktopFullscreen()
    }

    private func openFullscreenAnimation() {
        guard viewModel.animationFullscreenEnabled,
              hasAnimation else { return }
        viewModel.showFullscreenAnimation = true
    }

    @ViewBuilder
    private func sourceBadge() -> some View {
        if let snap = viewModel.snapshot, snap.hasTrack {
            HStack(spacing: 4) {
                Image(systemName: snap.source.sfSymbol)
                    .font(.system(size: 11, weight: .bold))
                Text(snap.source.displayName)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.14)))
        }
    }

    /// Small pill shown on the artwork when the current track has a motion
    /// (animated) artwork available.
    @ViewBuilder
    private var motionBadge: some View {
        if animationsOn && hasAnimation {
            HStack(spacing: 3) {
                Image(systemName: "livephoto")
                    .font(.system(size: 11, weight: .bold))
                Text(L10n.tr("เคลื่อนไหว", "Motion"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.14)))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Edit sheet

private struct EditTrackPopover: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    @Binding var isPresented: Bool

    @State private var artist: String = ""
    @State private var track: String = ""
    @State private var album: String = ""
    @State private var customImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "pencil.and.list.clipboard")
                    .foregroundStyle(.tint)
                Text(L10n.miniplayerEditTitle).font(.headline)
                Spacer()
            }

            artworkSection

            VStack(alignment: .leading, spacing: 6) {
                Text("Track").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $track)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Artist").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $artist)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Album").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $album)
                    .textFieldStyle(.roundedBorder)
            }

            Text(L10n.miniplayerEditFooter(viewModel.snapshot?.artist ?? "", viewModel.snapshot?.title ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.miniplayerCancel) { isPresented = false }
                Button(L10n.miniplayerSave) {
                    viewModel.saveEditForCurrentTrack(artist: artist, track: track, album: album)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(track.trimmingCharacters(in: .whitespaces).isEmpty
                          || artist.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear { prefill() }
    }

    @ViewBuilder
    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("ปกเพลง", "Artwork")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                artworkThumbnail
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.25))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Button(L10n.tr("ค้นหาปก…", "Browse Artwork…")) {
                        guard let snap = viewModel.snapshot else { return }
                        isPresented = false
                        ArtworkPickerWindowController.shared.show(
                            viewModel: viewModel, target: snap,
                            targetArtworkURL: viewModel.artwork.artworkURL)
                    }
                    if customImage != nil {
                        Button(L10n.tr("ใช้ปกเดิม", "Reset"), role: .destructive) {
                            viewModel.removeCustomArtwork()
                            customImage = nil
                        }
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let img = customImage {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let s = viewModel.artwork.artworkURL, let u = URL(string: s) {
            AsyncImage(url: u) { phase in
                if let i = phase.image {
                    i.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
    }

    private func prefill() {
        guard let snap = viewModel.snapshot else { return }
        artist = snap.artist
        track  = snap.title
        album  = snap.album
        customImage = viewModel.currentCustomArtwork()
    }
}

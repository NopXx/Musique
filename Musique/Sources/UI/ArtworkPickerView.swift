import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standalone window that searches the artwork API and lets the user pick a
/// cover for a specific track. The chosen image becomes that track's custom
/// artwork via `MiniPlayerViewModel.setCustomArtwork(_:for:)`.
@MainActor
final class ArtworkPickerWindowController {
    static let shared = ArtworkPickerWindowController()
    private var window: NSWindow?

    func show(viewModel: MiniPlayerViewModel, target: NowPlayingSnapshot, targetArtworkURL: String?) {
        let root = ArtworkPickerView(viewModel: viewModel, target: target,
                                     targetArtworkURL: targetArtworkURL) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 660)

        if let w = window {
            w.contentViewController = host
            w.setContentSize(NSSize(width: 600, height: 660))
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: host)
        w.title = L10n.tr("เลือกปกเพลง", "Choose Artwork")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.setContentSize(NSSize(width: 600, height: 660))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct ArtworkPickerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    let target: NowPlayingSnapshot
    /// Artwork shown for `target`, captured when the window opens. Frozen so it
    /// doesn't drift to the now-playing cover if the track changes while open.
    let targetArtworkURL: String?
    let onClose: () -> Void

    @State private var term: String = ""
    @State private var results: [ArtworkChoice] = []
    @State private var isLoading = false
    @State private var downloadingID: String?
    @State private var didSearch = false
    @State private var hoveredID: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var termIsEmpty: Bool { term.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            term = [target.title, target.artist].filter { !$0.isEmpty }.joined(separator: " ")
            runSearch()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                currentThumb
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title.nilIfBlank ?? L10n.tr("ไม่มีเพลง", "No track"))
                        .font(.headline).lineLimit(1)
                    if !target.artist.isEmpty {
                        Text(target.artist).font(.subheadline)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.tr("ค้นหาปก…", "Search artwork…"), text: $term)
                        .textFieldStyle(.plain)
                        .onSubmit { runSearch() }
                    if !termIsEmpty {
                        Button { term = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.12)))

                Button(L10n.tr("ค้นหา", "Search")) { runSearch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(termIsEmpty)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var currentThumb: some View {
        if let s = targetArtworkURL, let u = URL(string: s) {
            AsyncImage(url: u) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else { thumbPlaceholder }
            }
        } else { thumbPlaceholder }
    }

    private var thumbPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered { ProgressView() }
        } else if results.isEmpty {
            centered {
                Text(didSearch ? L10n.tr("ไม่พบปก", "No artwork found")
                               : L10n.tr("พิมพ์เพื่อค้นหา", "Type to search"))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(results) { choice in
                        cell(choice)
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.tr("เลือกจากไฟล์…", "From File…")) { pickFromFile() }
            Spacer()
            Button(L10n.tr("ปิด", "Close")) { onClose() }
        }
        .padding(12)
    }

    // MARK: - Cell

    private func cell(_ choice: ArtworkChoice) -> some View {
        let isHover = hoveredID == choice.id
        let isDownloading = downloadingID == choice.id
        return VStack(alignment: .leading, spacing: 8) {
            // Color.clear drives the 1:1 ratio so a landscape source image can't
            // stretch the cell — the artwork is laid on top via overlay (which
            // doesn't influence sizing) and clipped to the square.
            Color.secondary.opacity(0.12)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncImage(url: URL(string: choice.thumbURL)) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if choice.hasAnimation { animationBadge.padding(7) }
                }
                .overlay {
                    if isHover && downloadingID == nil {
                        ZStack {
                            Color.black.opacity(0.38)
                            VStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 26, weight: .semibold))
                                Text(L10n.tr("เลือกปกนี้", "Use this"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                        }
                    } else if isDownloading {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.06)))
                .shadow(color: .black.opacity(isHover ? 0.35 : 0.18),
                        radius: isHover ? 10 : 5, y: isHover ? 5 : 2)
                .scaleEffect(isHover ? 1.03 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(choice.album?.nilIfBlank ?? choice.track?.nilIfBlank ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(choice.artist?.nilIfBlank ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(choice) }
        .onHover { hovering in
            if hovering { hoveredID = choice.id }
            else if hoveredID == choice.id { hoveredID = nil }
        }
        .animation(.easeOut(duration: 0.12), value: isHover)
    }

    private var animationBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "livephoto")
                .font(.system(size: 9, weight: .bold))
            Text(L10n.tr("เคลื่อนไหว", "Motion"))
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }

    @ViewBuilder
    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func runSearch() {
        let q = term.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isLoading = true
        didSearch = true
        Task {
            let found = await ArtworkService.shared.search(term: q)
            await MainActor.run {
                results = found
                isLoading = false
            }
        }
    }

    private func choose(_ choice: ArtworkChoice) {
        guard downloadingID == nil, let url = URL(string: choice.fullURL) else { return }
        downloadingID = choice.id
        Task {
            defer { Task { @MainActor in downloadingID = nil } }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            await MainActor.run {
                viewModel.setCustomArtwork(img, for: target, sourceURL: choice.fullURL,
                                           animationURL: choice.animationURL,
                                           animationTallURL: choice.animationTallURL)
                onClose()
            }
        }
    }

    private func pickFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        viewModel.setCustomArtwork(img, for: target)
        onClose()
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

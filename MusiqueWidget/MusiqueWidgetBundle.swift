import WidgetKit
import SwiftUI
import AppIntents
import AppKit

/// Must match the host's `appGroupID` — team-ID-prefixed, the only form the
/// non-sandboxed host can open a container for.
let widgetAppGroupID = "H4M5HWBU2K.group.com.nopxx.musique"

func widgetDataFileURL() -> URL {
    let fm = FileManager.default
    let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: widgetAppGroupID)
    let dir = containerURL ?? fm.temporaryDirectory
    return dir.appendingPathComponent("nowPlaying.json")
}

func widgetArtworkDirURL() -> URL {
    let fm = FileManager.default
    let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: widgetAppGroupID)
    let dir = containerURL?.appendingPathComponent("artwork", isDirectory: true)
        ?? fm.temporaryDirectory.appendingPathComponent("musique_widget_artwork")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct NowPlayingWidgetData: Codable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var hasTrack: Bool
    var artworkPath: String?
    var accentR: Double
    var accentG: Double
    var accentB: Double
    var gradientStartR: Double
    var gradientStartG: Double
    var gradientStartB: Double
    var gradientMidR: Double
    var gradientMidG: Double
    var gradientMidB: Double
    var gradientEndR: Double
    var gradientEndG: Double
    var gradientEndB: Double
    var timestamp: Date
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let data: NowPlayingWidgetData?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = loadEntry()
        // The progress bar and elapsed-time text use Text(timerInterval:) /
        // ProgressView(timerInterval:) which animate smoothly inside the
        // widget process, so we only need a single entry. The reload is
        // pushed by the main app on track / play-state changes; this policy
        // is just a safety net for things like seek-while-paused.
        let next = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> NowPlayingEntry {
        let url = widgetDataFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(NowPlayingWidgetData.self, from: data),
              decoded.hasTrack else {
            return NowPlayingEntry(date: .now, data: nil)
        }
        return NowPlayingEntry(date: .now, data: decoded)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the current track from Apple Music via Musique.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct MusiqueWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}

// MARK: - Data helpers

extension NowPlayingWidgetData {
    var accentColor: Color {
        Color(red: accentR, green: accentG, blue: accentB)
    }

    var gradientColors: [Color] {
        [
            Color(red: gradientStartR, green: gradientStartG, blue: gradientStartB),
            Color(red: gradientMidR, green: gradientMidG, blue: gradientMidB),
            Color(red: gradientEndR, green: gradientEndG, blue: gradientEndB),
        ]
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, max(0, position / duration))
    }

    var remainingTime: String { formatTime(max(0, duration - position)) }
    var currentTime: String { formatTime(position) }
    var totalDuration: String { formatTime(max(0, duration)) }

    /// Wall-clock date corresponding to position 0:00 of the current track.
    var playStartDate: Date { timestamp.addingTimeInterval(-position) }
    /// Wall-clock date when the track will reach its `duration`.
    var playEndDate: Date { playStartDate.addingTimeInterval(max(duration, 1)) }
    var hasLiveTime: Bool { isPlaying && duration > 0 }

    var artworkImage: NSImage? {
        guard let path = artworkPath, !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Entry View

struct NowPlayingWidgetEntryView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        if let data = entry.data, data.hasTrack {
            switch family {
            case .systemSmall:   SmallWidgetView(data: data)
            case .systemMedium:  MediumWidgetView(data: data)
            case .systemLarge:   LargeWidgetView(data: data)
            default:             MediumWidgetView(data: data)
            }
        } else {
            EmptyStateView()
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Not Playing")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Shared backdrop

/// Full-bleed artwork with a bottom fade matching the miniplayer's scrim:
/// a multi-stop dark gradient layered with a palette tint, leaving the top
/// of the artwork untouched.
struct ArtworkBackdrop: View {
    let data: NowPlayingWidgetData

    var body: some View {
        ZStack {
            if let img = data.artworkImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: data.gradientColors,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            // Dark base — guarantees text readability on light artwork.
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
            // Palette tint on top.
            LinearGradient(
                colors: [
                    .clear,
                    Color(red: data.gradientStartR, green: data.gradientStartG, blue: data.gradientStartB).opacity(0.0),
                    Color(red: data.gradientStartR, green: data.gradientStartG, blue: data.gradientStartB).opacity(0.15),
                    Color(red: data.gradientStartR, green: data.gradientStartG, blue: data.gradientStartB).opacity(0.3),
                    Color(red: data.gradientStartR, green: data.gradientStartG, blue: data.gradientStartB).opacity(0.45),
                    Color(red: data.gradientStartR, green: data.gradientStartG, blue: data.gradientStartB).opacity(0.55),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

private struct GlassControlIcon: View {
    let systemName: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }
}

private struct OverlayTitle: View {
    let title: String
    let artist: String
    let titleSize: CGFloat
    let artistSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(artist)
                .font(.system(size: artistSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// In-process animated progress bar via `ProgressView(timerInterval:)`.
struct LiveProgressBar: View {
    let data: NowPlayingWidgetData
    let height: CGFloat

    var body: some View {
        if data.hasLiveTime {
            ProgressView(timerInterval: data.playStartDate...data.playEndDate,
                         countsDown: false,
                         label: { EmptyView() },
                         currentValueLabel: { EmptyView() })
                .progressViewStyle(.linear)
                .tint(.white.opacity(0.9))
                .frame(height: height)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: max(0, geo.size.width * CGFloat(data.progress)))
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let data: NowPlayingWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            OverlayTitle(title: data.title, artist: data.artist,
                         titleSize: 13, artistSize: 10)
            Spacer().frame(height: 10)
            HStack(spacing: 0) {
                Spacer()
                Button(intent: PreviousIntent()) { GlassControlIcon(systemName: "backward.fill", size: 13) }
                    .buttonStyle(.plain)
                Spacer()
                Button(intent: PlayPauseIntent(isPlaying: data.isPlaying)) {
                    GlassControlIcon(systemName: data.isPlaying ? "pause.fill" : "play.fill", size: 16)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(intent: NextIntent()) { GlassControlIcon(systemName: "forward.fill", size: 13) }
                    .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { ArtworkBackdrop(data: data) }
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let data: NowPlayingWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            OverlayTitle(title: data.title, artist: data.artist,
                         titleSize: 16, artistSize: 11)
            Spacer().frame(height: 8)
            LiveProgressBar(data: data, height: 3)
            Spacer().frame(height: 10)
            HStack(spacing: 0) {
                Spacer()
                Button(intent: PreviousIntent()) { GlassControlIcon(systemName: "backward.fill", size: 16) }
                    .buttonStyle(.plain)
                Spacer().frame(width: 26)
                Button(intent: PlayPauseIntent(isPlaying: data.isPlaying)) {
                    GlassControlIcon(systemName: data.isPlaying ? "pause.fill" : "play.fill", size: 22)
                }
                .buttonStyle(.plain)
                Spacer().frame(width: 26)
                Button(intent: NextIntent()) { GlassControlIcon(systemName: "forward.fill", size: 16) }
                    .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .containerBackground(for: .widget) { ArtworkBackdrop(data: data) }
    }
}

// MARK: - Large Widget

struct LargeWidgetView: View {
    let data: NowPlayingWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            OverlayTitle(title: data.title, artist: data.artist,
                         titleSize: 20, artistSize: 13)
            Spacer().frame(height: 12)
            LiveProgressBar(data: data, height: 4)
            Spacer().frame(height: 16)
            HStack(spacing: 0) {
                Spacer()
                Button(intent: PreviousIntent()) { GlassControlIcon(systemName: "backward.fill", size: 20) }
                    .buttonStyle(.plain)
                Spacer().frame(width: 34)
                Button(intent: PlayPauseIntent(isPlaying: data.isPlaying)) {
                    GlassControlIcon(systemName: data.isPlaying ? "pause.fill" : "play.fill", size: 28)
                }
                .buttonStyle(.plain)
                Spacer().frame(width: 34)
                Button(intent: NextIntent()) { GlassControlIcon(systemName: "forward.fill", size: 20) }
                    .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .containerBackground(for: .widget) { ArtworkBackdrop(data: data) }
    }
}

// MARK: - App Intents

@MainActor
private func dispatchMusiqueCommand(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.nopxx.musique.WidgetCommand"),
        object: command,
        userInfo: nil,
        deliverImmediately: true
    )
}

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    static var description: IntentDescription = "Toggle play or pause in Apple Music"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Is Playing")
    var isPlaying: Bool

    init() { isPlaying = false }
    init(isPlaying: Bool) { self.isPlaying = isPlaying }

    @MainActor
    func perform() async throws -> some IntentResult {
        dispatchMusiqueCommand(isPlaying ? "pause" : "play")
        return .result()
    }
}

struct NextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skip to next track in Apple Music"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        dispatchMusiqueCommand("next")
        return .result()
    }
}

struct PreviousIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Go back to previous track in Apple Music"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        dispatchMusiqueCommand("previous")
        return .result()
    }
}
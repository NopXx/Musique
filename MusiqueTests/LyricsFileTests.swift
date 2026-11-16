import XCTest
@testable import Musique

/// Shape trimmed from what LRCLIB really serves in `lyricsfile`.
final class LyricsFileTests: XCTestCase {
    private let sample = """
    version: '1.0'
    lines:
    - text: Baby, I'm just trying to play it cool
      start_ms: 510
      end_ms: 4210
      words:
      - text: 'Baby, '
        start_ms: 510
      - text: 'I''m '
        start_ms: 2150
      - text: cool
        start_ms: 3110
    - text: But I just can't hide that I want you
      start_ms: 4370
      end_ms: 7450
    plain: |
      Baby
    """

    func testNestedWordsStayInsideTheirLine() {
        let lines = LyricsFile.parse(sample)
        XCTAssertEqual(lines.map(\.text), ["Baby, I'm just trying to play it cool",
                                           "But I just can't hide that I want you"])
        XCTAssertEqual(lines[0].time, 0.51, accuracy: 0.001)
        XCTAssertEqual(lines[0].end ?? 0, 4.21, accuracy: 0.001)
    }

    func testWordsBecomeSegmentsEndingAtTheNextWord() {
        let seg = LyricsFile.parse(sample)[0].segments
        XCTAssertEqual(seg.map(\.text), ["Baby,", "I'm", "cool"])
        XCTAssertEqual(seg[0].end, 2.15, accuracy: 0.001)
        XCTAssertEqual(seg[2].end, 4.21, accuracy: 0.001)   // last word runs to the line's end
        XCTAssertTrue(LyricsFile.parse(sample)[1].segments.isEmpty)
    }
}

final class LyricsSourcePreferenceTests: XCTestCase {
    private func line(_ t: Double, words: Int) -> LyricLine {
        let segs = (0..<words).map { TimedLyricSegment(text: "w\($0)", start: t + Double($0), end: t + Double($0) + 1) }
        return LyricLine(time: t, text: "line", segments: segs)
    }

    func testWordTimedAppleWins() {
        let apple = [line(0, words: 3)], lrclib = [line(0, words: 4)]
        XCTAssertEqual(LyricsService.preferred(apple: apple, lrclib: lrclib).first?.segments.count, 3)
    }

    func testWordTimedLrclibBeatsLineTimedApple() {
        // A line-timed TTML parses to one whole-line segment per line.
        let apple = [line(0, words: 1)], lrclib = [line(0, words: 4)]
        XCTAssertEqual(LyricsService.preferred(apple: apple, lrclib: lrclib).first?.segments.count, 4)
    }

    func testLineTimedAppleBeatsLineTimedLrclib() {
        let apple = [line(0, words: 1)], lrclib = [line(5, words: 0)]
        XCTAssertEqual(LyricsService.preferred(apple: apple, lrclib: lrclib).first?.time, 0)
    }

    func testFallsBackToLrclibWhenAppleHasNothing() {
        XCTAssertEqual(LyricsService.preferred(apple: [], lrclib: [line(5, words: 0)]).first?.time, 5)
    }
}

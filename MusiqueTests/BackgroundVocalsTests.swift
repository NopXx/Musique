import XCTest
@testable import Musique

final class BackgroundVocalsTests: XCTestCase {
    // FOREVER (BABYMONSTER), as Apple serves it.
    private let ttml = #"<p begin="1:08.443" end="1:12.153"><span begin="1:08.443" end="1:10.512">For</span><span begin="1:10.512" end="1:11.637">e</span><span begin="1:11.637" end="1:12.153">ver</span> <span ttm:role="x-bg"><span begin="1:10.481" end="1:10.798">(Like</span> <span begin="1:10.798" end="1:11.226">I'mma</span> <span begin="1:11.226" end="1:11.451">live</span> <span begin="1:11.451" end="1:12.092">forever)</span></span></p>"#

    private func seg(_ t: String, _ s: Double, _ e: Double) -> TimedLyricSegment {
        TimedLyricSegment(text: t, start: s, end: e)
    }

    func testSplitsBackingVocalsOntoTheirOwnRow() {
        // What MusanovaKit makes of it: one line, both voices.
        let parsed = LyricLine(time: 68.443, end: 72.092, text: "Forever (Like I'mma live forever)",
                               segments: [seg("For", 68.443, 70.512), seg("e", 70.512, 71.637),
                                          seg("ver", 71.637, 72.153), seg("(Like", 70.481, 70.798),
                                          seg("I'mma", 70.798, 71.226), seg("live", 71.226, 71.451),
                                          seg("forever)", 71.451, 72.092)])
        let line = BackgroundVocals.split(parsed, keys: BackgroundVocals.keys(in: ttml))
        XCTAssertEqual(line.text, "Forever")
        XCTAssertEqual(line.segments.map(\.text), ["For", "e", "ver"])
        XCTAssertEqual(line.backgroundText, "Like I'mma live forever")
        XCTAssertEqual(line.background.map(\.text), ["Like", "I'mma", "live", "forever"])
    }

    func testLineWithoutBackingVocalsIsUntouched() {
        let parsed = LyricLine(time: 1, text: "Forever", segments: [seg("Forever", 1, 2)])
        XCTAssertEqual(BackgroundVocals.split(parsed, keys: BackgroundVocals.keys(in: ttml)), parsed)
    }
}

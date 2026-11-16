import XCTest
@testable import Musique

final class PlaybackClockTests: XCTestCase {
    private func snap(state: String, position: Double, duration: Double, at date: Date) -> NowPlayingSnapshot {
        var s = NowPlayingSnapshot(state: state, title: "t", artist: "a", album: "",
                                   duration: duration, position: position, persistentID: "id")
        s.positionDate = date
        return s
    }

    func testPlayingProjectsForward() {
        let t0 = Date()
        let s = snap(state: "playing", position: 10, duration: 200, at: t0)
        XCTAssertEqual(s.livePosition(at: t0.addingTimeInterval(0.75)), 10.75, accuracy: 0.0001)
    }

    func testPausedHoldsStill() {
        let t0 = Date()
        let s = snap(state: "paused", position: 10, duration: 200, at: t0)
        XCTAssertEqual(s.livePosition(at: t0.addingTimeInterval(5)), 10)
    }

    func testClampsToDuration() {
        let t0 = Date()
        let s = snap(state: "playing", position: 199, duration: 200, at: t0)
        XCTAssertEqual(s.livePosition(at: t0.addingTimeInterval(5)), 200)
    }
}

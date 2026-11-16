import XCTest
@testable import Musique

/// Payloads trimmed from what web-scrobbler (YouTube connector) really posted.
final class WebScrobblerTests: XCTestCase {
    private func event(_ name: String, time: Double, currentTime: Double?, isPlaying: Bool,
                       start: Double = 1_793_697_730) -> WebScrobblerEvent {
        let json = """
        {"eventName":"\(name)","time":\(time),"data":{"song":{
          "parsed":{"track":"Say My Name","artist":"i-dle","album":null,"duration":171,
                    "uniqueID":"9g9NClV1z_w","currentTime":\(currentTime.map { "\($0)" } ?? "null"),
                    "isPlaying":\(isPlaying),"trackArt":null},
          "processed":{"track":"Say My Name","artist":"MIYEON","album":"MY, Lover","duration":171},
          "flags":{"isScrobbled":false},"metadata":{"startTimestamp":\(start),"label":"YouTube"},
          "connector":{"label":"YouTube","id":"youtube"},"controllerTabId":313662328}}}
        """
        return try! JSONDecoder().decode(WebScrobblerEvent.self, from: Data(json.utf8))
    }

    func testNowPlayingPrefersProcessedAndProjectsPosition() throws {
        let sent = Date(timeIntervalSince1970: 1_793_697_732)
        var state = WebScrobblerState()
        state.apply(event("nowplaying", time: 1_793_697_732_000, currentTime: 4, isPlaying: true), now: sent)

        let snap = try XCTUnwrap(state.snapshot(now: sent.addingTimeInterval(10)))
        XCTAssertEqual(snap.artist, "MIYEON")  // user correction in `processed` wins
        XCTAssertEqual(snap.album, "MY, Lover")
        XCTAssertEqual(snap.duration, 171)
        XCTAssertEqual(snap.position, 14, accuracy: 0.01)
        XCTAssertTrue(snap.isPlaying)
        XCTAssertEqual(snap.source, .webScrobbler)
        XCTAssertEqual(snap.persistentID, "web:9g9NClV1z_w@1793697730")
    }

    func testPauseFreezesAndResumeContinues() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_697_824)
        var state = WebScrobblerState()
        state.apply(event("paused", time: 1_793_697_824_000, currentTime: 96, isPlaying: false), now: t0)
        let paused = try XCTUnwrap(state.snapshot(now: t0.addingTimeInterval(60)))
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.position, 96)

        let t1 = t0.addingTimeInterval(58)
        state.apply(event("resumedplaying", time: t1.timeIntervalSince1970 * 1000, currentTime: 96, isPlaying: true), now: t1)
        let resumed = try XCTUnwrap(state.snapshot(now: t1.addingTimeInterval(5)))
        XCTAssertTrue(resumed.isPlaying)
        XCTAssertEqual(resumed.position, 101, accuracy: 0.01)

        // A scrobble carries no transition: still playing.
        state.apply(event("scrobble", time: t1.timeIntervalSince1970 * 1000 + 8000, currentTime: 103, isPlaying: true),
                    now: t1.addingTimeInterval(8))
        XCTAssertEqual(state.snapshot(now: t1.addingTimeInterval(8))?.isPlaying, true)
    }

    func testExpiresWithoutStoppedEvent() {
        let t0 = Date(timeIntervalSince1970: 1_793_697_732)
        var state = WebScrobblerState()
        state.apply(event("nowplaying", time: 1_793_697_732_000, currentTime: 0, isPlaying: true), now: t0)
        XCTAssertNotNil(state.snapshot(now: t0.addingTimeInterval(171 + 29)))
        XCTAssertNil(state.snapshot(now: t0.addingTimeInterval(171 + 31)))

        state.apply(event("paused", time: 1_793_697_732_000, currentTime: 50, isPlaying: false), now: t0)
        XCTAssertNotNil(state.snapshot(now: t0.addingTimeInterval(9 * 60)))
        XCTAssertNil(state.snapshot(now: t0.addingTimeInterval(11 * 60)))
    }

    func testReplayIsANewPlay() {
        let t0 = Date(timeIntervalSince1970: 1_793_697_732)
        var state = WebScrobblerState()
        state.apply(event("nowplaying", time: 1_793_697_732_000, currentTime: 0, isPlaying: true), now: t0)
        let first = state.snapshot(now: t0)?.persistentID
        state.apply(event("nowplaying", time: 1_793_697_932_000, currentTime: 0, isPlaying: true,
                          start: 1_793_697_930), now: t0.addingTimeInterval(200))
        XCTAssertNotEqual(state.snapshot(now: t0.addingTimeInterval(200))?.persistentID, first)
    }

    func testParseRequestWaitsForWholeBody() throws {
        let head = "POST /api/webscrobbler?token=abc HTTP/1.1\r\nHost: 127.0.0.1\r\ncontent-length: 4\r\n\r\n"
        XCTAssertNil(WebScrobblerReceiver.parseRequest(Data((head + "{}").utf8)))
        let req = try XCTUnwrap(WebScrobblerReceiver.parseRequest(Data((head + "{  }").utf8)))
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.target, "/api/webscrobbler?token=abc")
        XCTAssertEqual(req.body, Data("{  }".utf8))
    }
}

import XCTest
@testable import Musique

final class UpdateServiceTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateService.isNewer("1.5.0", than: "1.4.0"))
        XCTAssertTrue(UpdateService.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(UpdateService.isNewer("2", than: "1.99.99"))
        XCTAssertFalse(UpdateService.isNewer("1.5", than: "1.5.0"))
        XCTAssertFalse(UpdateService.isNewer("1.4.0", than: "1.5.0"))
        XCTAssertFalse(UpdateService.isNewer("1.5.0", than: "1.5.0"))
    }

    func testDecodesGitHubRelease() throws {
        let json = #"{"tag_name":"v1.5.0","html_url":"https://github.com/NopXx/Musique/releases/tag/v1.5.0","name":"Musique 1.5.0"}"#
        let r = try JSONDecoder().decode(UpdateService.Release.self, from: Data(json.utf8))
        XCTAssertEqual(r.version, "1.5.0")
    }
}

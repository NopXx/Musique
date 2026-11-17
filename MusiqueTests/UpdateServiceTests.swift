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

    private func release(_ assets: [String], tag: String = "v1.6.0") throws -> UpdateService.Release {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }
        let json = #"{"tag_name":"\#(tag)","html_url":"https://example.com","assets":[\#(list.joined(separator: ","))]}"#
        return try JSONDecoder().decode(UpdateService.Release.self, from: Data(json.utf8))
    }

    func testPicksVersionedDMG() throws {
        let r = try release(["Musique-1.5.0.dmg", "Musique-1.6.0.dmg", "Source.zip"])
        XCTAssertEqual(r.dmg?.name, "Musique-1.6.0.dmg")
        XCTAssertEqual(r.dmg?.url.absoluteString, "https://example.com/Musique-1.6.0.dmg")
    }

    func testFallsBackToLoneDMG() throws {
        XCTAssertEqual(try release(["Musique.DMG", "notes.txt"]).dmg?.name, "Musique.DMG")
    }

    func testNoDMGWhenMissingOrAmbiguous() throws {
        XCTAssertNil(try release(["Source.zip"]).dmg)
        XCTAssertNil(try release(["a.dmg", "b.dmg"]).dmg)
        XCTAssertNil(try release([]).dmg)
    }

    private let current = UpdateService.Signature(bundleID: "com.nopxx.musique", teamID: "TEAM123", version: "1.5.0")

    private func verify(_ c: UpdateService.Signature, against cur: UpdateService.Signature? = nil) -> UpdateService.InstallError? {
        do { try UpdateService.verify(c, against: cur ?? current); return nil }
        catch { return error as? UpdateService.InstallError }
    }

    func testVerifyAcceptsNewerBuildFromSameTeam() {
        XCTAssertNil(verify(.init(bundleID: "com.nopxx.musique", teamID: "TEAM123", version: "1.6.0")))
    }

    func testVerifyRejectsMismatches() {
        XCTAssertEqual(verify(.init(bundleID: "com.evil.app", teamID: "TEAM123", version: "1.6.0")),
                       .bundleMismatch("com.evil.app"))
        XCTAssertEqual(verify(.init(bundleID: "com.nopxx.musique", teamID: "OTHER", version: "1.6.0")),
                       .teamMismatch("OTHER"))
        XCTAssertEqual(verify(.init(bundleID: "com.nopxx.musique", teamID: nil, version: "1.6.0")),
                       .teamMismatch(nil))
        XCTAssertEqual(verify(.init(bundleID: "com.nopxx.musique", teamID: "TEAM123", version: "1.5.0")),
                       .notNewer("1.5.0"))
        XCTAssertEqual(verify(.init(bundleID: "com.nopxx.musique", teamID: "TEAM123", version: nil)),
                       .notNewer(nil))
    }

    func testVerifyRefusesWhenRunningAppIsUnsigned() {
        let unsigned = UpdateService.Signature(bundleID: "com.nopxx.musique", teamID: nil, version: "1.5.0")
        XCTAssertEqual(verify(.init(bundleID: "com.nopxx.musique", teamID: nil, version: "1.6.0"), against: unsigned),
                       .notSigned)
    }

    func testSignatureRejectsUnsignedBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try UpdateService.signature(of: dir))
    }
}

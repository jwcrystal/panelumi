import XCTest
@testable import PanelumiCore

final class BuildInfoTests: XCTestCase {
    func testVersionHidesABuildNumberThatMatchesTheShortVersion() {
        let build = BuildInfo(shortVersion: "0.11.0", buildVersion: "0.11.0")
        XCTAssertEqual(build.version, "0.11.0")
    }

    func testVersionKeepsADifferentBuildNumber() {
        let build = BuildInfo(shortVersion: "0.11.0", buildVersion: "12")
        XCTAssertEqual(build.version, "0.11.0 (12)")
    }

    func testVersionFallsBackWhenTheBuildNumberIsMissing() {
        XCTAssertEqual(BuildInfo(shortVersion: "0.11.0", buildVersion: nil).version, "0.11.0")
        XCTAssertEqual(BuildInfo(shortVersion: "0.11.0", buildVersion: "").version, "0.11.0")
    }

    func testEditionIsEmptyUnlessTheBundleSetsIt() {
        XCTAssertEqual(BuildInfo(shortVersion: "0.11.0", buildVersion: nil).edition, "")
        XCTAssertEqual(BuildInfo(shortVersion: "0.11.0", buildVersion: nil, edition: " Pro ").edition, "Pro")
    }
}

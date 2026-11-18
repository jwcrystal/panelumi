import XCTest
@testable import SwitchKit

final class AppIdentityTests: XCTestCase {
    private var saved = AppIdentity.standard

    override func setUp() {
        super.setUp()
        saved = AppIdentity.current
    }

    override func tearDown() {
        AppIdentity.current = saved
        super.tearDown()
    }

    func testDefaultsFollowCurrentIdentity() async {
        let feed = URL(string: "https://example.invalid/host/latest")!
        AppIdentity.current = AppIdentity(supportFolderName: "HostApp", updateFeedURL: feed)

        XCTAssertEqual(ConfigStore.defaultURL().pathComponents.suffix(2), ["HostApp", "config.json"])

        var captured: URL?
        let checker = UpdateChecker(currentVersion: "1.0.0") { request in
            captured = request.url
            throw URLError(.notConnectedToInternet)
        }
        _ = try? await checker.check()
        XCTAssertEqual(captured, feed)
    }

    func testStandardMatchesBuiltInValues() {
        let standard = AppIdentity.standard
        XCTAssertEqual(standard.supportFolderName, "SwitchDeck")
        XCTAssertEqual(
            standard.updateFeedURL.absoluteString,
            "https://api.github.com/repos/jwcrystal/panelumi/releases/latest"
        )
        XCTAssertEqual(standard.repositoryURL.absoluteString, "https://github.com/jwcrystal/panelumi")
        XCTAssertEqual(standard.issuesURL.absoluteString, "https://github.com/jwcrystal/panelumi/issues")
    }

    func testCustomSupportFolderChangesConfigPath() {
        let custom = AppIdentity(supportFolderName: "CustomHost")
        let url = ConfigStore.defaultURL(identity: custom)
        XCTAssertEqual(url.pathComponents.suffix(2), ["CustomHost", "config.json"])
        XCTAssertEqual(
            ConfigStore.defaultURL(identity: .standard).pathComponents.suffix(2),
            ["SwitchDeck", "config.json"]
        )
    }

    func testUpdateCheckerUsesCustomFeedURL() async {
        let feed = URL(string: "https://example.invalid/feed/latest")!
        var captured: URL?
        let checker = UpdateChecker(currentVersion: "1.0.0", feedURL: feed) { request in
            captured = request.url
            throw URLError(.notConnectedToInternet)
        }
        _ = try? await checker.check()
        XCTAssertEqual(captured, feed)
    }
}

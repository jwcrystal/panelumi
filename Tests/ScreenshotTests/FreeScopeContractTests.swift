import XCTest
@testable import SwitchDeckCore
@testable import SwitchKit

// The lists in this file are the frozen set of shipped switches and tools:
// none may be removed, hidden or restricted. Changing them needs the maintainer.

final class FreeScopeContractTests: XCTestCase {
    private let expectedSwitchIDs: Set<String> = [
        "showHiddenFiles", "hideDesktopIcons", "dockAutohide", "screenClean", "keepAwake",
        "darkMode", "muteOutput", "muteMicrophone", "lockKeyboard", "lockScreen",
        "nightShift", "stageManager", "stageManagerAutohide", "emptyTrash", "emptyPasteboard",
        "screenshot", "recognizeText", "recording", "quitAllApps", "ejectDisk",
    ]

    @MainActor
    func testAppCatalogContainsExactlyTheTwentySwitches() {
        let ids = AppCatalog.make(screenshot: ScreenshotCoordinator()).items.map(\.id)
        XCTAssertEqual(ids.count, 20)
        XCTAssertEqual(Set(ids), expectedSwitchIDs)
    }
}

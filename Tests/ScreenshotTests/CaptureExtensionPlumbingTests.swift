import AppKit
import XCTest
@testable import PanelumiCore

/// The wiring between `LaunchOptions`, the app delegate, the coordinator and
/// the capture session. No capture is started here.
final class CaptureExtensionPlumbingTests: XCTestCase {
    @MainActor
    func testSelectionControllerKeepsFirstOfDuplicateIdentifiers() {
        let first = FakeExtension(identifier: "test.a")
        let duplicate = FakeExtension(identifier: "test.a")
        let other = FakeExtension(identifier: "test.b")

        let controller = SelectionController(captureExtensions: [first, duplicate, other])

        XCTAssertEqual(controller.session.captureExtensions.map(\.identifier), ["test.a", "test.b"])
        XCTAssertEqual(controller.session.captureExtensions.count, 2)
        XCTAssertTrue((controller.session.captureExtensions.first as? FakeExtension) === first)
    }

    @MainActor
    func testSelectionControllerHasNoExtensionsByDefault() {
        let controller = SelectionController()

        XCTAssertTrue(controller.session.captureExtensions.isEmpty)
    }

    @MainActor
    func testCoordinatorAcceptsExtensions() {
        let extensionUnderTest = FakeExtension(identifier: "test.one")

        let coordinator = ScreenshotCoordinator(captureExtensions: [extensionUnderTest])

        XCTAssertEqual(coordinator.switchItem.id, ScreenshotCoordinator.id)
    }
}

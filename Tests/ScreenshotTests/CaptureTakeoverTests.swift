import AppKit
import PanelumiKit
import XCTest
@testable import PanelumiCore

/// The takeover lifecycle: starting one from a toolbar entry, the state it
/// installs, every end path and the input it blocks. No real event delivery,
/// key window or local monitor is involved.
final class CaptureTakeoverTests: XCTestCase {
    // MARK: - Beginning

    @MainActor
    func testPickingAnEntryStartsATakeoverWithTheScreenRegion() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        let context = try XCTUnwrap(harness.fake.contexts.last)
        XCTAssertEqual(context.region.minX, harness.selection.minX, accuracy: 0.5)
        XCTAssertEqual(context.region.minY, harness.selection.minY, accuracy: 0.5)
        XCTAssertEqual(context.region.width, harness.selection.width, accuracy: 0.5)
        XCTAssertEqual(context.region.height, harness.selection.height, accuracy: 0.5)
        XCTAssertTrue(context.screen === view.screen)
        XCTAssertTrue(context.isActive)

        XCTAssertTrue(harness.controller.session.takeoverActive)
        XCTAssertTrue(view.isTakeoverOwner)
        XCTAssertEqual(view.toolbarHost?.isHidden, true, "The toolbar must hide")
        for window in harness.overlayWindows {
            XCTAssertTrue(window.ignoresMouseEvents, "Every overlay window lets the mouse through")
        }
    }

    /// The entry reports the region itself when it is wired to the controller.
    @MainActor
    func testTheWiredActionClosureStartsATakeover() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)

        view.onCaptureAction?(
            harness.fake.identifier,
            "entry",
            captureRegion(harness.selection, on: harness.screen)
        )

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        XCTAssertTrue(harness.controller.session.takeoverActive)
    }

    @MainActor
    func testAnAnnotationRefusesTheEntry() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.controller.session.annotations = [Annotation(
            shape: .rectangle(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.4, y: 0.4)),
            color: .red
        )]

        try XCTUnwrap(harness.view).requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertTrue(harness.fake.beginCalls.isEmpty)
        XCTAssertFalse(harness.controller.session.takeoverActive)
        XCTAssertEqual(harness.takeover.endReasons.count, 0)
    }

    @MainActor
    func testASecondEntryIsRefusedWhileATakeoverRuns() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)

        view.requestCaptureAction(harness.fake.identifier, "entry")
        view.requestCaptureAction(harness.fake.identifier, "other")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        XCTAssertEqual(harness.takeover.endReasons.count, 0)
    }

    // MARK: - Declined and ended

    @MainActor
    func testADeclinedActionKeepsTheSelectedTool() throws {
        let harness = try Harness(returnsTakeover: false)
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        harness.controller.session.tool = .rectangle

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        XCTAssertEqual(harness.controller.session.tool, .rectangle, "A declined action changes nothing")
    }

    @MainActor
    func testBeginReturningNilLeavesEverythingUntouched() throws {
        let harness = try Harness(returnsTakeover: false)
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        XCTAssertEqual(view.toolbarHost?.isHidden, false, "The toolbar stays")
        XCTAssertFalse(harness.controller.session.takeoverActive)
        XCTAssertFalse(view.isTakeoverOwner)
        XCTAssertEqual(harness.takeover.endReasons.count, 0, "No takeover object exists")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        XCTAssertFalse(context.isActive)
        for window in harness.overlayWindows {
            XCTAssertFalse(window.ignoresMouseEvents)
        }
    }

    /// The extension consumes Esc and calls `cancel()` while handling it.
    @MainActor
    func testEscHandledByCancellingEndsCancelled() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let windows = harness.overlayWindows
        harness.takeover.onHandleKey = { _ in context.cancel() }

        let event = keyEvent(53, "\u{1b}", in: view)
        XCTAssertNil(view.handleKeyEvent(event))

        assertEnded(harness, reason: .cancelled, windows: windows)
        XCTAssertFalse(harness.controller.isActive, "Cancel closes the overlay")
        XCTAssertFalse(context.isActive)
        XCTAssertEqual(harness.cancelled, 1)
    }

    @MainActor
    func testUnhandledEscDismisses() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let windows = harness.overlayWindows

        let event = keyEvent(53, "\u{1b}", in: view)
        XCTAssertNil(view.handleKeyEvent(event), "The host consumes the Esc it acted on")

        assertEnded(harness, reason: .dismissed, windows: windows)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertEqual(harness.cancelled, 1)
    }

    @MainActor
    func testCancellingFromOutsideEndsCancelled() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        XCTAssertTrue(harness.controller.isActive)
        let windows = harness.overlayWindows

        context.cancel()

        assertEnded(harness, reason: .cancelled, windows: windows)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertEqual(harness.cancelled, 1)
    }

    @MainActor
    func testCancelInsideBeginEndsCancelledExactlyOnce() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.fake.beginAction = { $0.cancel() }
        let windows = harness.overlayWindows

        try XCTUnwrap(harness.view).requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        assertEnded(harness, reason: .cancelled, windows: windows)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertEqual(harness.cancelled, 1)
    }

    /// The host restores the overlay before it notifies the takeover, so the
    /// extension already sees an inactive context and windows that take the
    /// mouse again. This path ends the takeover without closing the overlay.
    @MainActor
    func testTakeoverDidEndSeesTheRestoredOverlay() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        // The closure below retains the windows; drop it so they are released
        // with the test instead of lingering in `NSApp.windows`.
        defer { harness.takeover.onEnd = nil }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let windows = harness.overlayWindows
        var atEnd: (active: Bool, ignoresMouse: [Bool], toolbarHidden: Bool?, contextActive: Bool)?

        harness.takeover.onEnd = { _ in
            atEnd = (
                harness.controller.session.takeoverActive,
                windows.map(\.ignoresMouseEvents),
                view.toolbarHost?.isHidden,
                context.isActive
            )
        }

        harness.controller.endTakeover(.cancelled)

        let recorded = try XCTUnwrap(atEnd)
        XCTAssertFalse(recorded.active)
        XCTAssertEqual(recorded.ignoresMouse, Array(repeating: false, count: windows.count))
        XCTAssertEqual(recorded.toolbarHidden, false, "The toolbar is laid out again first")
        XCTAssertFalse(recorded.contextActive)
    }

    /// Esc handled by cancelling closes the overlay; the windows are restored
    /// before the takeover hears about the end.
    @MainActor
    func testCancelFromHandleKeyRestoresBeforeItNotifies() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        // The closure below retains the windows; drop it so they are released
        // with the test instead of lingering in `NSApp.windows`.
        defer { harness.takeover.onEnd = nil }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let windows = harness.overlayWindows
        var atEnd: (active: Bool, ignoresMouse: [Bool], contextActive: Bool)?

        harness.takeover.onEnd = { _ in
            atEnd = (
                harness.controller.session.takeoverActive,
                windows.map(\.ignoresMouseEvents),
                context.isActive
            )
        }
        harness.takeover.onHandleKey = { _ in context.cancel() }

        let event = keyEvent(53, "\u{1b}", in: view)
        XCTAssertNil(view.handleKeyEvent(event))

        let recorded = try XCTUnwrap(atEnd)
        XCTAssertFalse(recorded.active)
        XCTAssertEqual(recorded.ignoresMouse, Array(repeating: false, count: windows.count))
        XCTAssertFalse(recorded.contextActive)
        XCTAssertEqual(harness.takeover.endReasons, [.cancelled])
        XCTAssertFalse(harness.controller.isActive)
    }

    /// Closing the overlay from inside `begin` installs nothing: the returned
    /// takeover hears `.dismissed` once and the context stays inactive.
    @MainActor
    func testClosingTheOverlayInsideBeginInstallsNothing() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        harness.fake.beginAction = { _ in view.onCancel?() }

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertFalse(harness.controller.session.takeoverActive)
        XCTAssertFalse(view.isTakeoverOwner)
        XCTAssertEqual(harness.takeover.endReasons, [.dismissed])
        let context = try XCTUnwrap(harness.fake.contexts.last)
        XCTAssertFalse(context.isActive)
        XCTAssertEqual(harness.cancelled, 1)
    }

    @MainActor
    func testTheClosePathDismisses() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let windows = harness.overlayWindows

        view.onCancel?()

        assertEnded(harness, reason: .dismissed, windows: windows)
        XCTAssertFalse(harness.controller.isActive)
    }

    @MainActor
    func testDebugCompletionDismisses() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let windows = harness.overlayWindows

        harness.controller.completeForDebug(.copy)

        assertEnded(harness, reason: .dismissed, windows: windows)
        XCTAssertFalse(harness.controller.isActive)
    }

    @MainActor
    func testDisplayChangeDismissesOnce() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let windows = harness.overlayWindows

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        assertEnded(harness, reason: .dismissed, windows: windows)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertEqual(harness.cancelled, 1)

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        XCTAssertEqual(harness.takeover.endReasons.count, 1, "The observer was removed")
        XCTAssertEqual(harness.cancelled, 1)
    }

    // MARK: - Keys that do not end the takeover

    @MainActor
    func testHostKeysReachTheTakeoverAndAreConsumed() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        harness.takeover.consumesKeys = true

        let presses: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (36, "\r", []),
            (49, " ", []),
            (35, "p", []),
            (6, "z", [.command]),
            (51, "\u{7f}", []),
        ]
        for (keyCode, characters, modifiers) in presses {
            let event = keyEvent(keyCode, characters, in: view, modifiers: modifiers)
            XCTAssertNil(view.handleKeyEvent(event), "Key \(keyCode) is consumed")
            XCTAssertEqual(harness.takeover.keys.last?.keyCode, keyCode)
        }

        XCTAssertEqual(harness.takeover.keys.count, presses.count)
        XCTAssertEqual(harness.takeover.keys[3].modifierFlags, [.command])
        XCTAssertEqual(harness.captures, 0, "No host shortcut ran")
        XCTAssertTrue(harness.controller.isActive)
        XCTAssertTrue(harness.controller.session.takeoverActive)
        XCTAssertEqual(harness.takeover.endReasons.count, 0)
    }

    @MainActor
    func testAnUnhandledNonEscKeyIsHandedBackWithoutHostAction() throws {
        let harness = try Harness(toolbarItem: nil)
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        harness.takeover.consumesKeys = false
        let annotationsBefore = harness.controller.session.annotations

        // Without a takeover each of these finishes the capture.
        for (keyCode, characters) in [(UInt16(36), "\r"), (49, " "), (35, "p")] {
            let event = keyEvent(keyCode, characters, in: view)
            XCTAssertTrue(view.handleKeyEvent(event) === event, "Key \(keyCode) is handed back")
        }

        XCTAssertEqual(harness.takeover.endReasons.count, 0)
        XCTAssertEqual(harness.controller.session.annotations, annotationsBefore)
        XCTAssertEqual(harness.captures, 0, "No host shortcut ran")
        XCTAssertTrue(harness.controller.isActive)
        XCTAssertTrue(harness.controller.session.takeoverActive)
    }

    /// A takeover may end itself from `handleKey`. The key stays consumed: it
    /// must never reach the closed editor as a host shortcut.
    @MainActor
    func testAKeyThatEndsTheTakeoverIsStillConsumed() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        harness.takeover.consumesKeys = false
        harness.takeover.onHandleKey = { _ in context.cancel() }

        let event = keyEvent(36, "\r", in: view)
        XCTAssertNil(view.handleKeyEvent(event))

        XCTAssertEqual(harness.takeover.endReasons, [.cancelled])
        XCTAssertEqual(harness.captures, 0, "Return must not run the host copy")
        XCTAssertFalse(harness.controller.isActive)
    }

    @MainActor
    func testDeleteDoesNotRemoveAnAnnotationDuringATakeover() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        let annotation = Annotation(
            shape: .rectangle(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.4, y: 0.4)),
            color: .red
        )
        view.requestCaptureAction(harness.fake.identifier, "entry")
        // Set the content after the takeover started: the entry refuses while
        // an annotation exists, but the takeover must still protect it.
        harness.controller.session.annotations = [annotation]
        harness.controller.session.selectionIndex = 0
        harness.takeover.consumesKeys = false

        _ = view.handleKeyEvent(keyEvent(51, "\u{7f}", in: view))

        XCTAssertEqual(harness.controller.session.annotations, [annotation])
        XCTAssertEqual(harness.controller.session.selectionIndex, 0)
    }

    // MARK: - Input blocking

    @MainActor
    func testMouseAndModifierInputLeavesTheOverlayAlone() throws {
        let previousFormat = ScreenshotPreferences.colorFormat
        defer { ScreenshotPreferences.setColorFormat(previousFormat) }
        // Set before the harness builds its views: they read the stored value,
        // and a missing guard would advance it to the next one.
        let storedFormat = ScreenshotPreferences.ColorFormat.rgb
        XCTAssertNotEqual(storedFormat.next, storedFormat)
        ScreenshotPreferences.setColorFormat(storedFormat)

        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let start = try XCTUnwrap(view.selection)
        let selection = view.selection
        let tool = harness.controller.session.tool
        let hoverColor = view.hoverColor
        let hoveredID = view.hovered?.id
        let hoveredRect = view.hovered?.rect
        let point = CGPoint(x: start.midX, y: start.midY)
        let dragged = CGPoint(x: point.x + 50, y: point.y + 50)

        view.mouseEntered(with: enteredEvent(at: point, in: view))
        view.mouseMoved(with: mouseEvent(.mouseMoved, at: point, in: view))
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: dragged, in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: dragged, in: view))
        view.flagsChanged(with: keyEvent(58, "", in: view, type: .flagsChanged, modifiers: [.option]))
        view.keyDown(with: keyEvent(36, "\r", in: view))

        XCTAssertEqual(view.selection, selection, "A drag must not move the selection")
        XCTAssertEqual(harness.controller.session.tool, tool)
        XCTAssertEqual(ScreenshotPreferences.colorFormat, storedFormat)
        XCTAssertEqual(view.hoverColor, hoverColor)
        XCTAssertEqual(view.hovered?.id, hoveredID)
        XCTAssertEqual(view.hovered?.rect, hoveredRect)
        XCTAssertTrue(harness.controller.session.takeoverActive)
        XCTAssertTrue(harness.controller.isActive)
        XCTAssertEqual(harness.takeover.endReasons.count, 0)
        XCTAssertEqual(harness.captures, 0)
    }

    // MARK: - Context after the end

    @MainActor
    func testTheContextGoesInactiveAndStaysQuietAfterTheEnd() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.cancel()
        XCTAssertEqual(harness.takeover.endReasons.count, 1)
        XCTAssertEqual(harness.cancelled, 1)

        context.cancel()
        context.cancel()

        XCTAssertFalse(context.isActive)
        XCTAssertEqual(harness.takeover.endReasons.count, 1, "No second takeoverDidEnd")
        XCTAssertEqual(harness.cancelled, 1, "No second close")
    }

    // MARK: - Drawing

    /// Pins the takeover drawing: the frozen frame is never painted, the owner
    /// cuts its selection out of a plain half-black dim, and only the border
    /// remains.
    @MainActor
    func testTheOwnerViewCutsTheSelectionOutOfTheDimming() throws {
        let frozen = try solidImage(red: 0.1, green: 0.8, blue: 0.4)
        let harness = try Harness(frozen: { _ in frozen })
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let ownerSelection = try XCTUnwrap(view.selection)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let inside = color(
                  in: rep,
                  at: CGPoint(x: ownerSelection.midX, y: ownerSelection.midY),
                  bounds: view.bounds
              ),
              let outside = color(in: rep, at: CGPoint(x: 4, y: 4), bounds: view.bounds)
        else {
            throw XCTSkip("Headless rendering did not produce a usable bitmap")
        }

        XCTAssertLessThan(inside.alphaComponent, 0.1, "Inside the selection stays clear")
        XCTAssertEqual(outside.alphaComponent, 0.5, accuracy: 0.1, "Outside is the plain dim")
        XCTAssertLessThan(outside.redComponent, 0.1, "The frozen colour is not drawn")
        XCTAssertLessThan(outside.greenComponent, 0.1, "The frozen colour is not drawn")
        XCTAssertLessThan(outside.blueComponent, 0.1, "The frozen colour is not drawn")
    }

    @MainActor
    func testEveryDisplayIgnoresTheMouseAndNonOwnersDrawAPlainDim() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        guard NSScreen.screens.count >= 2 else {
            throw XCTSkip("Needs two displays")
        }
        let owner = try XCTUnwrap(harness.view)
        owner.requestCaptureAction(harness.fake.identifier, "entry")

        let windows = harness.overlayWindows
        XCTAssertEqual(windows.count, NSScreen.screens.count)
        for window in windows {
            XCTAssertTrue(window.ignoresMouseEvents)
        }

        guard let other = windows
            .compactMap({ $0.contentView as? SelectionView })
            .first(where: { $0 !== owner })
        else {
            throw XCTSkip("No second overlay view")
        }

        let rep = try XCTUnwrap(other.bitmapImageRepForCachingDisplay(in: other.bounds))
        other.cacheDisplay(in: other.bounds, to: rep)
        let middle = CGPoint(x: other.bounds.midX, y: other.bounds.midY)
        guard let centre = alpha(in: rep, at: middle, bounds: other.bounds),
              let corner = alpha(in: rep, at: CGPoint(x: 4, y: 4), bounds: other.bounds),
              corner > 0.05
        else {
            throw XCTSkip("Headless rendering did not produce a usable bitmap")
        }

        XCTAssertEqual(centre, corner, accuracy: 0.02, "No cut-out on a view without the selection")
    }

    /// A selection spanning two displays is cut out on the owner only. The
    /// other view has its own part of the selection (its centre lies inside it)
    /// yet must keep a plain dim.
    @MainActor
    func testANonOwnerViewWithItsOwnSelectionKeepsAPlainDim() throws {
        guard NSScreen.screens.count >= 2 else {
            throw XCTSkip("Needs two displays")
        }
        let first = NSScreen.screens[0].frame
        let second = NSScreen.screens[1].frame
        let spanning = first.union(second).insetBy(dx: 20, dy: 20)
        guard spanning.width > 0, spanning.height > 0 else {
            throw XCTSkip("The displays cannot share one selection")
        }
        let harness = try Harness(initialSelection: spanning)
        defer { harness.cleanup() }
        let owner = try XCTUnwrap(harness.view)
        owner.requestCaptureAction(harness.fake.identifier, "entry")

        guard let other = harness.overlayViews.first(where: { $0 !== owner }),
              let ownSelection = other.selection else {
            throw XCTSkip("No second overlay view with a selection")
        }
        let centre = CGPoint(x: other.bounds.midX, y: other.bounds.midY)
        guard ownSelection.contains(centre) else {
            throw XCTSkip("The other display's centre is outside its part of the selection")
        }

        let rep = try XCTUnwrap(other.bitmapImageRepForCachingDisplay(in: other.bounds))
        other.cacheDisplay(in: other.bounds, to: rep)
        guard let centreAlpha = alpha(in: rep, at: centre, bounds: other.bounds),
              let cornerAlpha = alpha(in: rep, at: CGPoint(x: 4, y: 4), bounds: other.bounds)
        else {
            throw XCTSkip("Headless rendering did not produce a usable bitmap")
        }

        XCTAssertGreaterThan(centreAlpha, 0.05, "The non-owner does not clear its selection")
        XCTAssertEqual(centreAlpha, cornerAlpha, accuracy: 0.02, "A plain dim fills the view")
    }

    // MARK: - Helpers

    /// One started capture plus the fakes behind it.
    @MainActor
    private final class Harness {
        let screen: NSScreen
        let selection: CGRect
        let fake: FakeExtension
        let takeover: FakeTakeover
        let controller: SelectionController
        private(set) var cancelled = 0
        private(set) var captures = 0

        init(
            toolbarItem: CaptureToolbarItem? = nil,
            returnsTakeover: Bool = true,
            initialSelection: CGRect? = nil,
            frozen: @escaping (NSScreen) -> CGImage? = { _ in nil }
        ) throws {
            guard let screen = NSScreen.screens.first else {
                throw XCTSkip("Needs a screen to host the overlay")
            }
            self.screen = screen
            let frame = screen.frame
            self.selection = initialSelection ?? CGRect(
                x: frame.midX - 100,
                y: frame.midY - 75,
                width: 200,
                height: 150
            )
            self.takeover = FakeTakeover()
            self.fake = FakeExtension(identifier: "test.one", toolbarItem: toolbarItem)
            self.fake.takeover = returnsTakeover ? takeover : nil
            self.controller = SelectionController(captureExtensions: [fake])

            controller.begin(
                onCapture: { [weak self] _, _ in self?.captures += 1 },
                onCancel: { [weak self] in self?.cancelled += 1 },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: selection,
                frozen: frozen
            )
        }

        @MainActor
        var view: SelectionView? {
            overlayViews.first { $0.screen == screen }
        }

        @MainActor
        var overlayViews: [SelectionView] {
            NSApp.windows.compactMap { $0.contentView as? SelectionView }
                .filter { $0.window?.isVisible == true && $0.session === controller.session }
        }

        @MainActor
        var overlayWindows: [NSWindow] {
            overlayViews.compactMap(\.window)
        }

        /// Closes a still-live overlay so one failure cannot leak into the next
        /// test.
        @MainActor
        func cleanup() {
            guard controller.isActive, let view else { return }
            view.onCancel?()
        }
    }

    /// Asserts the shared end state. The windows are passed in because every
    /// end path also closes the overlay, after which they are no longer
    /// discoverable.
    @MainActor
    private func assertEnded(
        _ harness: Harness,
        reason: CaptureEndReason,
        windows: [NSWindow]
    ) {
        XCTAssertEqual(harness.takeover.endReasons, [reason])
        XCTAssertFalse(harness.controller.session.takeoverActive)
        XCTAssertEqual(windows.count, NSScreen.screens.count)
        for window in windows {
            XCTAssertFalse(window.ignoresMouseEvents, "Windows take the mouse again")
        }
    }

    @MainActor
    private func captureRegion(_ selection: CGRect, on screen: NSScreen) -> CGRect {
        selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    /// A solid colour image, for the frozen frame a timed capture passes in.
    @MainActor
    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let width = 8, height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not allocate a test bitmap")
        }
        context.setFillColor(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("Could not make a solid test image")
        }
        return image
    }

    @MainActor
    private func color(
        in rep: NSBitmapImageRep,
        at point: CGPoint,
        bounds: CGRect
    ) -> NSColor? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(rep.pixelsWide) / bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / bounds.height
        let x = min(rep.pixelsWide - 1, max(0, Int(point.x * scaleX)))
        let y = min(rep.pixelsHigh - 1, max(0, Int((bounds.height - point.y) * scaleY)))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    @MainActor
    private func alpha(
        in rep: NSBitmapImageRep,
        at point: CGPoint,
        bounds: CGRect
    ) -> CGFloat? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(rep.pixelsWide) / bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / bounds.height
        let x = min(rep.pixelsWide - 1, max(0, Int(point.x * scaleX)))
        let y = min(rep.pixelsHigh - 1, max(0, Int((bounds.height - point.y) * scaleY)))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.alphaComponent
    }

    @MainActor
    private func keyEvent(
        _ keyCode: UInt16,
        _ characters: String,
        in view: SelectionView,
        type: NSEvent.EventType = .keyDown,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @MainActor
    private func enteredEvent(at point: CGPoint, in view: SelectionView) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in view: SelectionView
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

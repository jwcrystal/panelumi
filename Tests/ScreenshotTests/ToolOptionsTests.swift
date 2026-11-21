import AppKit
import SwiftUI
import XCTest
@testable import PanelumiCore

final class ToolOptionsTests: XCTestCase {
    @MainActor
    func testEveryDrawingToolKeepsTheSameToolbarHeight() {
        _ = NSApplication.shared
        func size(_ tool: CaptureSession.Tool) -> NSSize {
            let session = CaptureSession()
            session.tool = tool
            let host = NSHostingView(rootView: CaptureToolbarView(session: session))
            return host.fittingSize
        }
        let plain = size(.rectangle)
        let mainRow = size(.select)
        for tool in CaptureSession.Tool.allCases where tool != .select {
            let options = size(tool)
            XCTAssertEqual(options.height, plain.height, accuracy: 0.5,
                           "\(tool) must keep the toolbar height steady")
            XCTAssertLessThanOrEqual(options.width, mainRow.width + 2,
                                     "\(tool) must not widen the main toolbar")
        }
    }

    /// The width sliders show points; a region resized after entering the
    /// editor changes the size those points are scaled by.
    @MainActor
    func testResizingTheRegionRescalesThePointWidths() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let session = CaptureSession()
        let view = SelectionView(screen: screen, session: session) { _, _ in nil }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        let region = CGRect(x: 40, y: 40, width: 320, height: 200)
        view.presetSelection(region)
        XCTAssertEqual(session.imagePointSize.width, region.width, accuracy: 0.5)

        let handle = CGPoint(x: region.maxX, y: region.midY)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: handle))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: handle.x + 80, y: handle.y)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: handle.x + 80, y: handle.y)))

        XCTAssertEqual(session.imagePointSize.width, region.width + 80, accuracy: 0.5)
        XCTAssertEqual(session.imagePointSize.height, region.height, accuracy: 0.5)
    }

    @MainActor
    func testSelectedAnnotationOptionsKeepTheToolbarCompact() {
        _ = NSApplication.shared
        func size(_ shape: Annotation.Shape?) -> NSSize {
            let session = CaptureSession()
            session.tool = .select
            if let shape {
                session.annotations = [Annotation(shape: shape, style: AnnotationStyle())]
                session.selectionIndex = 0
            }
            return NSHostingView(rootView: CaptureToolbarView(session: session)).fittingSize
        }
        let reference = size(.rectangle(from: .zero, to: .zero))
        let mainRow = size(nil)
        let shapes: [Annotation.Shape] = [
            .rectangle(from: .zero, to: .zero),
            .ellipse(from: .zero, to: .zero),
            .line(from: .zero, to: .zero),
            .arrow(from: .zero, to: .zero),
            .pen(points: []),
            .highlighter(points: []),
            .text("Hi", at: .zero),
            .number(1, at: .zero),
            .mosaic(from: .zero, to: .zero),
            .blur(from: .zero, to: .zero),
        ]
        for shape in shapes {
            let expanded = size(shape)
            XCTAssertEqual(expanded.height, reference.height, accuracy: 0.5,
                           "\(shape) must keep the toolbar height steady")
            XCTAssertLessThanOrEqual(expanded.width, mainRow.width + 2,
                                     "\(shape) must not widen the main toolbar")
        }
    }

    @MainActor
    func testSelectWithoutSelectionShowsTheColorSwatch() {
        _ = NSApplication.shared
        let session = CaptureSession()
        session.tool = .select

        XCTAssertTrue(CaptureToolbarView(session: session).showsColorSwatch,
                      "the colour button sets the default for the next annotation")

        session.tool = .mosaic
        XCTAssertFalse(CaptureToolbarView(session: session).showsColorSwatch)
        session.tool = .blur
        XCTAssertFalse(CaptureToolbarView(session: session).showsColorSwatch)

        for tool in CaptureSession.Tool.allCases where tool != .select && tool != .mosaic && tool != .blur {
            session.tool = tool
            XCTAssertTrue(CaptureToolbarView(session: session).showsColorSwatch, "\(tool)")
        }

        session.tool = .select
        session.annotations = [Annotation(shape: .mosaic(from: .zero, to: .zero), color: .red)]
        session.selectionIndex = 0
        XCTAssertFalse(CaptureToolbarView(session: session).showsColorSwatch,
                       "a selected mosaic has no colour")
        session.annotations = [Annotation(shape: .rectangle(from: .zero, to: .zero), color: .red)]
        XCTAssertTrue(CaptureToolbarView(session: session).showsColorSwatch)
    }

    @MainActor
    func testEmptySelectRowHidesTheOptionsRow() {
        _ = NSApplication.shared
        func size(_ tool: CaptureSession.Tool) -> NSSize {
            let session = CaptureSession()
            session.tool = tool
            return NSHostingView(rootView: CaptureToolbarView(session: session)).fittingSize
        }
        let hiddenRow = CaptureToolbarView.optionsRowReserve
        XCTAssertEqual(size(.select).height + hiddenRow, size(.rectangle).height, accuracy: 0.5)
        XCTAssertEqual(size(.select).height + hiddenRow, size(.mosaic).height, accuracy: 0.5)
    }

    @MainActor
    func testSelectWithoutASelectionHidesTheOptionsRow() {
        _ = NSApplication.shared
        let session = CaptureSession()
        session.tool = .select

        XCTAssertFalse(session.showsOptionsRow)

        session.tool = .rectangle
        XCTAssertTrue(session.showsOptionsRow)
    }

    func testEveryToolHasATitleAndAUniqueShortcut() {
        let tools = CaptureSession.Tool.allCases
        XCTAssertTrue(tools.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(Set(tools.map(\.shortcut)).count, tools.count)
    }

    func testShortcutCharactersMapToTools() {
        let expected: [(Character, CaptureSession.Tool)] = [
            ("v", .select), ("V", .select),
            ("r", .rectangle), ("R", .rectangle),
            ("o", .ellipse), ("l", .line), ("a", .arrow), ("d", .pen),
            ("h", .highlighter), ("t", .text), ("n", .number),
            ("m", .mosaic), ("b", .blur),
        ]
        for (character, tool) in expected {
            XCTAssertEqual(CaptureSession.Tool.tool(forShortcut: character), tool, "\(character)")
        }
        XCTAssertNil(CaptureSession.Tool.tool(forShortcut: "c"), "C stays the colour key")
        XCTAssertNil(CaptureSession.Tool.tool(forShortcut: "f"), "F stays the full-screen key")
    }

    func testLineWidthStepsCoverOneToTen() {
        XCTAssertEqual(CaptureToolbarView.lineWidthLevel(for: 0.0015), 1)
        XCTAssertEqual(CaptureToolbarView.lineWidthLevel(for: 0.016), 10)
        XCTAssertEqual(CaptureToolbarView.lineWidthLevel(for: 0.0001), 1)
        XCTAssertEqual(CaptureToolbarView.lineWidthLevel(for: 0.05), 10)
    }

    func testWidthLabelsShowPointsOnceTheCaptureSizeIsKnown() {
        XCTAssertEqual(
            CaptureToolbarView.widthLabel(for: 0.024, in: CGSize(width: 800, height: 600), level: 4),
            "19 pt"
        )
        XCTAssertEqual(
            CaptureToolbarView.widthLabel(for: 0.05, in: CGSize(width: 1400, height: 900), level: 10),
            "70 pt"
        )
        XCTAssertEqual(
            CaptureToolbarView.widthLabel(for: 0.024, in: .zero, level: 4),
            "4",
            "the level is the fallback before the capture size is known"
        )
    }

    @MainActor
    func testHintBandDoesNotTakeClicks() {
        _ = NSApplication.shared
        let (host, container) = makeHintBandHost(edge: .bottom)
        // Hit testing needs a window and a layout pass; the host's flipped
        // coordinates are mirrored in the unflipped container.
        let bandPoint = host.convert(
            NSPoint(x: host.bounds.midX, y: host.hintBandRect.midY),
            to: container
        )
        XCTAssertNil(host.hitTest(bandPoint), "Clicks on the hint band must reach the selection")

        let pillPoint = host.convert(
            NSPoint(x: host.bounds.midX, y: host.hintBandRect.maxY + 20),
            to: container
        )
        XCTAssertNotNil(host.hitTest(pillPoint), "The pill itself keeps taking clicks")
    }

    @MainActor
    func testHintBandSitsAtTheBottomWhenPopoversOpenUpward() {
        _ = NSApplication.shared
        let (host, container) = makeHintBandHost(edge: .top)
        let bottom = host.isFlipped ? host.bounds.maxY - host.hintBandRect.height : host.bounds.minY
        XCTAssertEqual(host.hintBandRect.minY, bottom, accuracy: 0.5,
                       "edge .top puts the band at the bottom of the toolbar")

        let bandPoint = host.convert(
            NSPoint(x: host.bounds.midX, y: host.hintBandRect.midY),
            to: container
        )
        XCTAssertNil(host.hitTest(bandPoint), "Clicks on the hint band must reach the selection")
    }

    @MainActor
    private func makeHintBandHost(edge: Edge) -> (host: CaptureToolbarHost, container: NSView) {
        let host = CaptureToolbarHost(rootView: CaptureToolbarView(session: CaptureSession()))
        host.rootView.popoverPlacement.edge = edge
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        return (host, container)
    }

    func testArrowChoicesUseDifferentPaths() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 20)
        let paths = [ArrowStyle.straight, .curved, .elbow, .sCurve].map { ArrowOptionIcon(style: $0).path(in: rect).description }
        XCTAssertEqual(Set(paths).count, 4)
    }

    @MainActor
    func testOptionalVisualSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["PANELUMI_UI_SNAPSHOT"] else { return }
        _ = NSApplication.shared
        let session = CaptureSession()
        session.tool = .arrow
        let host = NSHostingView(rootView: CaptureToolbarView(session: session))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    func testStraightBandIconIsABandNotALine() throws {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: StraightBandIcon().frame(width: 21, height: 15))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))

        func ink(inRow row: Int) -> Int {
            (0..<bitmap.pixelsWide).reduce(0) { count, x in
                guard let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5, color.redComponent < 0.5 else { return count }
                return count + 1
            }
        }

        XCTAssertGreaterThan(ink(inRow: bitmap.pixelsHigh / 2), bitmap.pixelsWide / 2,
                             "the icon fills a band, not a hairline")
        XCTAssertEqual(ink(inRow: 1), 0, "the band sits in the middle, clear of the edges")
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

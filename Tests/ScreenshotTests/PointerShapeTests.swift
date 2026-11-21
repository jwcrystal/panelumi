import AppKit
import XCTest
@testable import PanelumiCore

/// A hover may only promise what a click starts, so the shapes the cursor
/// reads are checked here. The cursor images themselves need a real pointer.
final class PointerShapeTests: XCTestCase {
    private let region = CGRect(x: 40, y: 40, width: 320, height: 200)

    // MARK: - The region

    @MainActor
    func testEveryRegionHandleResizes() {
        let (view, session, window) = makeView()
        defer { window.close() }
        session.tool = .select

        for handle in SelectionView.Handle.allCases {
            XCTAssertEqual(
                view.pointerShape(at: handlePoint(handle)),
                .regionHandle(handle),
                "\(handle)"
            )
        }
    }

    @MainActor
    func testTheRegionHandleWinsOverAnAnnotationUnderIt() {
        let (view, session, window) = makeView()
        defer { window.close() }
        session.tool = .select
        session.annotations = [Annotation(
            shape: .arrow(from: .zero, to: CGPoint(x: 0.3, y: 0.3)),
            style: AnnotationStyle()
        )]
        session.selectionIndex = 0

        XCTAssertEqual(view.pointerShape(at: handlePoint(.topLeft)), .regionHandle(.topLeft))
    }

    @MainActor
    func testTheRegionIsTheToolTargetAndOutsideIsNothing() {
        let (view, session, window) = makeView()
        defer { window.close() }
        let inside = CGPoint(x: region.midX, y: region.midY)

        session.tool = .select
        XCTAssertEqual(view.pointerShape(at: inside), .region)

        session.tool = .pen
        XCTAssertEqual(view.pointerShape(at: inside), .region,
                       "a drawing tool draws, it does not move the region")
        XCTAssertEqual(
            view.pointerShape(at: CGPoint(x: region.maxX + 60, y: region.maxY + 60)),
            .nothing
        )
    }

    // MARK: - Annotations

    @MainActor
    func testAnAnnotationIsAMoveTargetInSelectMode() throws {
        let (view, session, window) = makeView()
        defer { window.close() }
        session.tool = .select
        session.annotations = [arrow()]

        let frame = try XCTUnwrap(view.annotationFrameForDebug(0))
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(view.pointerShape(at: middle), .annotation)
    }

    @MainActor
    func testTheSelectedAnnotationsCornerResizesIt() throws {
        let (view, session, window) = makeView()
        defer { window.close() }
        session.tool = .select
        session.annotations = [arrow()]
        session.selectionIndex = 0

        let frame = try XCTUnwrap(view.annotationFrameForDebug(0))
        XCTAssertEqual(
            view.pointerShape(at: CGPoint(x: frame.minX, y: frame.maxY)),
            .annotationHandle(.topLeft)
        )
    }

    @MainActor
    func testPickingAColourDropsTheDragTargets() throws {
        let (view, session, window) = makeView()
        defer { window.close() }
        session.tool = .select
        session.annotations = [arrow()]
        session.selectionIndex = 0
        session.isPickingColor = true

        let frame = try XCTUnwrap(view.annotationFrameForDebug(0))
        XCTAssertEqual(
            view.pointerShape(at: CGPoint(x: frame.minX, y: frame.maxY)),
            .nothing,
            "a click reads the pixel instead of starting a drag"
        )
    }

    // MARK: - Helpers

    private func arrow() -> Annotation {
        Annotation(
            shape: .arrow(
                from: CGPoint(x: 0.25, y: 0.3),
                to: CGPoint(x: 0.75, y: 0.7)
            ),
            style: AnnotationStyle()
        )
    }

    private func handlePoint(_ handle: SelectionView.Handle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: region.minX, y: region.maxY)
        case .top: return CGPoint(x: region.midX, y: region.maxY)
        case .topRight: return CGPoint(x: region.maxX, y: region.maxY)
        case .right: return CGPoint(x: region.maxX, y: region.midY)
        case .bottomRight: return CGPoint(x: region.maxX, y: region.minY)
        case .bottom: return CGPoint(x: region.midX, y: region.minY)
        case .bottomLeft: return CGPoint(x: region.minX, y: region.minY)
        case .left: return CGPoint(x: region.minX, y: region.midY)
        }
    }

    @MainActor
    private func makeView() -> (SelectionView, CaptureSession, NSWindow) {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
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
        view.presetSelection(region)
        return (view, session, window)
    }
}

import CoreGraphics
import XCTest
@testable import SwitchDeckCore

// The lists in this file are the frozen set of shipped switches and tools:
// none may be removed, hidden or restricted. Changing them needs the maintainer.
//
// Enums that are not CaseIterable are covered by switches without a default
// branch: adding or removing a case stops this file from compiling.

final class FreeScopeAnnotationContractTests: XCTestCase {
    private let p = CGPoint(x: 0.1, y: 0.1)

    private func toolName(_ shape: Annotation.Shape) -> String {
        switch shape {
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .line: return "line"
        case .arrow: return "arrow"
        case .pen: return "pen"
        case .highlighter: return "highlighter"
        case .number: return "number"
        case .mosaic: return "mosaic"
        case .blur: return "blur"
        case .text: return "text"
        }
    }

    private func arrowName(_ style: ArrowStyle) -> String {
        switch style {
        case .straight: return "straight"
        case .curved: return "curved"
        case .elbow: return "elbow"
        case .sCurve: return "sCurve"
        }
    }

    func testAnnotationToolsAreExactlyTheTen() {
        let one: [Annotation.Shape] = [
            .rectangle(from: p, to: p), .ellipse(from: p, to: p), .line(from: p, to: p),
            .arrow(from: p, to: p), .pen(points: [p]), .highlighter(points: [p]),
            .number(1, at: p), .mosaic(from: p, to: p), .blur(from: p, to: p), .text("a", at: p),
        ]
        XCTAssertEqual(Set(one.map(toolName)), [
            "rectangle", "ellipse", "line", "arrow", "pen",
            "highlighter", "number", "mosaic", "blur", "text",
        ])
        XCTAssertEqual(one.count, 10)
    }

    func testArrowPathsAreExactlyTheFour() {
        let all: [ArrowStyle] = [.straight, .curved, .elbow, .sCurve]
        XCTAssertEqual(Set(all.map(arrowName)), ["straight", "curved", "elbow", "sCurve"])
    }

    func testShapeFillsAreExactlyTheThree() {
        XCTAssertEqual(Set(ShapeFillStyle.allCases.map { "\($0)" }), ["outline", "hatched", "solid"])
        XCTAssertEqual(ShapeFillStyle.allCases.count, 3)
    }

    func testStrokeStylesAreExactlyTheThree() {
        XCTAssertEqual(Set(LinePattern.allCases.map { "\($0)" }), ["solid", "dashed", "dotted"])
        XCTAssertEqual(LinePattern.allCases.count, 3)
    }

    func testWatermarkPositionsAreExactlyTheSix() {
        let all = AnnotationRenderer.WatermarkOptions.Placement.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)),
                       ["bottomRight", "bottomLeft", "topRight", "topLeft", "center", "tiled"])
        XCTAssertEqual(all.count, 6)
    }
}

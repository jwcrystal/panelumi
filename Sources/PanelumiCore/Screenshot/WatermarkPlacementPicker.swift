import SwiftUI

/// A picture-shaped picker: one dot per position, so all five on-image spots
/// stay one click away instead of sitting in a menu. Tiled is its own button.
struct WatermarkPlacementPicker: View {
    @Binding var placement: AnnotationRenderer.WatermarkOptions.Placement
    var onHover: (AnnotationRenderer.WatermarkOptions.Placement, Bool) -> Void = { _, _ in }

    private static let frameSize = CGSize(width: 36, height: 22)
    private static let dotHitSize: CGFloat = 10
    private static let dotDiameter: CGFloat = 6

    private struct Dot: Identifiable {
        let placement: AnnotationRenderer.WatermarkOptions.Placement
        let center: CGPoint
        var id: AnnotationRenderer.WatermarkOptions.Placement { placement }
    }

    private var dots: [Dot] {
        let left: CGFloat = 7
        let right = Self.frameSize.width - left
        let top: CGFloat = 6
        let bottom = Self.frameSize.height - top
        let middle = CGPoint(x: Self.frameSize.width / 2, y: Self.frameSize.height / 2)
        return [
            Dot(placement: .topLeft, center: CGPoint(x: left, y: top)),
            Dot(placement: .topRight, center: CGPoint(x: right, y: top)),
            Dot(placement: .center, center: middle),
            Dot(placement: .bottomLeft, center: CGPoint(x: left, y: bottom)),
            Dot(placement: .bottomRight, center: CGPoint(x: right, y: bottom)),
        ]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            ForEach(dots) { dot in
                dotButton(dot)
                    .position(dot.center)
            }
        }
        .frame(width: Self.frameSize.width, height: Self.frameSize.height)
    }

    private func dotButton(_ dot: Dot) -> some View {
        let selected = placement == dot.placement
        return Button {
            placement = dot.placement
        } label: {
            Circle()
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.28))
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .frame(width: Self.dotHitSize, height: Self.dotHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dot.placement.title)
        .onHover { onHover(dot.placement, $0) }
    }
}

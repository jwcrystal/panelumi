import SwiftUI

/// Alternating blocks stay readable as "mosaic" down to the toolbar's 13pt.
struct MosaicToolIcon: View {
    private let columns = 4
    private let rows = 4

    var body: some View {
        Canvas { context, size in
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let box = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    context.fill(Path(box), with: .foreground)
                }
            }
        }
    }
}

/// A filled band, the mark the straight mode leaves, so the two drawing modes
/// differ by shape rather than by a hairline that reads as nothing.
struct StraightBandIcon: View {
    var body: some View {
        Canvas { context, size in
            let height = size.height * 0.46
            let box = CGRect(
                x: size.width * 0.04,
                y: (size.height - height) / 2,
                width: size.width * 0.92,
                height: height
            )
            context.fill(
                Path(roundedRect: box, cornerRadius: height * 0.3),
                with: .foreground
            )
        }
    }
}

/// A solid disc with a blurred edge, so it reads as soft next to the mosaic's
/// hard squares. The filter keeps the icon in the surrounding foreground tint.
struct BlurToolIcon: View {
    var body: some View {
        Canvas { context, size in
            var layer = context
            layer.addFilter(.blur(radius: min(size.width, size.height) * 0.13))
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            layer.fill(Path(ellipseIn: box), with: .foreground)
        }
    }
}

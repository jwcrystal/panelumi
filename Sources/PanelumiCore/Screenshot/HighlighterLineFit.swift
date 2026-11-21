import CoreGraphics
import Foundation

/// Fits a straight highlighter band to the text line under it.
///
/// Only the height and the row are measured: the band keeps the columns it was
/// dragged across, so the mark still covers what the user swept. A row profile
/// finds the ink without any text recognition, which keeps the fit immediate
/// and lets it work on any rendered text, in either theme.
enum HighlighterLineFit {
    struct Fit: Equatable {
        /// Band thickness relative to the image width.
        var width: CGFloat
        /// Centre row of the line, relative to the image height.
        var centerY: CGFloat
    }

    /// Text is never this much ink; more than it and the row is a solid block,
    /// not a line worth snapping to.
    private static let solidCoverage: CGFloat = 0.7
    /// A row counts as text when this much of it differs from its own paper.
    private static let inkCoverage: CGFloat = 0.04
    /// Ascenders and descenders carry a few glyphs per row; they still belong to
    /// the line, so a row next to the ink joins it at this lower bar.
    private static let faintCoverage: CGFloat = 0.006
    /// How far a pixel must sit from the row's paper to count as ink.
    private static let inkDelta: CGFloat = 0.2
    /// Sized in points, so a fit never depends on the capture's resolution.
    private static let heightRange: ClosedRange<CGFloat> = 4...60
    /// The band gets a little air above and below the glyphs.
    private static let breathing: CGFloat = 1.15

    static func fit(
        in base: CGImage,
        points: [CGPoint],
        width: CGFloat,
        pointScale: CGFloat
    ) -> Fit? {
        guard let first = points.first, let last = points.last, pointScale > 0 else { return nil }
        let imageWidth = CGFloat(base.width)
        let imageHeight = CGFloat(base.height)
        let thickness = imageWidth * width
        guard thickness >= 2 else { return nil }

        let centerRow = (first.y + last.y) / 2 * imageHeight
        let x0 = Int((min(first.x, last.x) * imageWidth).rounded())
        let x1 = Int((max(first.x, last.x) * imageWidth).rounded())
        // Look one line above and below, so a line taller than the band still
        // fits; a thin band should not decide the answer on its own height.
        let margin = max(thickness * 1.5, 24 * pointScale)
        let y0 = Int((centerRow - margin).rounded())
        let y1 = Int((centerRow + margin).rounded())

        // The scan window can run past the image at the edges; the fitted row
        // is measured from where the pixels actually start.
        let columns = clamped(x0...x1, to: 0...(base.width - 1))
        let rows = clamped(y0...y1, to: 0...(base.height - 1))

        guard let region = Region(image: base, columns: columns, rows: rows), region.width > 0
        else { return nil }

        let profile = region.profile()
        let groups = contiguousGroups(profile.inkRows)
        let pressedRow = centerRow - CGFloat(rows.lowerBound)
        guard let core = groups.min(by: {
            abs(groupCenter($0) - pressedRow) < abs(groupCenter($1) - pressedRow)
        }) else { return nil }

        let coverage = core.reduce(0) { $0 + profile.coverage[$1] } / CGFloat(core.count)
        guard coverage < solidCoverage else { return nil }

        let group = expanded(core, in: profile.faintRows)
        let height = CGFloat(group.count)
        let heightPoints = height * breathing / pointScale
        guard heightRange.contains(heightPoints) else { return nil }

        return Fit(
            width: heightPoints * pointScale / imageWidth,
            centerY: (CGFloat(rows.lowerBound) + groupCenter(group)) / imageHeight
        )
    }

    private static func clamped(
        _ range: ClosedRange<Int>,
        to bounds: ClosedRange<Int>
    ) -> ClosedRange<Int> {
        let lower = min(max(range.lowerBound, bounds.lowerBound), bounds.upperBound)
        let upper = min(max(range.upperBound, bounds.lowerBound), bounds.upperBound)
        return lower...max(lower, upper)
    }

    private static func groupCenter(_ group: Range<Int>) -> CGFloat {
        (CGFloat(group.lowerBound) + CGFloat(group.upperBound - 1)) / 2
    }

    /// Grows a core group over the faint rows that belong to the same line, so
    /// ascenders and descenders count towards its height.
    private static func expanded(_ group: Range<Int>, in rows: [Bool]) -> Range<Int> {
        var lower = group.lowerBound
        var upper = group.upperBound
        while lower > 0, rows[lower - 1] { lower -= 1 }
        while upper < rows.count, rows[upper] { upper += 1 }
        return lower..<upper
    }

    private static func contiguousGroups(_ flags: [Bool]) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start: Int?
        for (index, flagged) in flags.enumerated() {
            if flagged, start == nil { start = index }
            if !flagged, let begin = start {
                groups.append(begin..<index)
                start = nil
            }
        }
        if let begin = start {
            groups.append(begin..<flags.count)
        }
        return groups
    }

    // MARK: - Pixels

    private struct Profile {
        /// Rows that read as text.
        var inkRows: [Bool]
        /// Rows with any glyph at all, ascenders and descenders included.
        var faintRows: [Bool]
        /// Fraction of each row that differs from that row's paper.
        var coverage: [CGFloat]
    }

    private struct Region {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init?(image: CGImage, columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
            let x0 = max(0, min(columns.lowerBound, image.width - 1))
            let x1 = max(x0, min(columns.upperBound, image.width - 1))
            let y0 = max(0, min(rows.lowerBound, image.height - 1))
            let y1 = max(y0, min(rows.upperBound, image.height - 1))
            let box = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
            guard let cropped = image.cropping(to: box) else { return nil }

            width = Int(box.width)
            height = Int(box.height)
            guard width > 0, height > 0 else { return nil }

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = pixels
        }

        func luminance(x: Int, y: Int) -> CGFloat {
            let offset = (y * width + x) * 4
            let r = CGFloat(bytes[offset])
            let g = CGFloat(bytes[offset + 1])
            let b = CGFloat(bytes[offset + 2])
            return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }

        /// Each row is measured against its own paper, so light and dark
        /// captures read the same way.
        func profile() -> Profile {
            var inkRows: [Bool] = []
            var faintRows: [Bool] = []
            var coverage: [CGFloat] = []
            for y in 0..<height {
                var values: [CGFloat] = []
                values.reserveCapacity(width)
                for x in 0..<width {
                    values.append(luminance(x: x, y: y))
                }
                values.sort()
                let paper = values[values.count / 2]
                let ink = values.reduce(0) { $0 + (abs($1 - paper) > inkDelta ? 1 : 0) }
                let fraction = CGFloat(ink) / CGFloat(width)
                coverage.append(fraction)
                inkRows.append(fraction >= inkCoverage)
                faintRows.append(fraction >= faintCoverage)
            }
            return Profile(inkRows: inkRows, faintRows: faintRows, coverage: coverage)
        }
    }
}

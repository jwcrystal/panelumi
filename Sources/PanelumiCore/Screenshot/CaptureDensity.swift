import CoreGraphics

/// Keeps a capture's pixels at the density the display can produce.
///
/// A saved capture is sized in points and tagged `72 × scale` dpi
/// (`ScreenshotSaver`), so a bitmap holding more pixels per point than the
/// screen never describes a sharper image: the extra pixels came from a
/// resample upstream (a wrong rect, a stale frozen frame, a screen that changed
/// under the overlay) and only make the file soft and heavy. A bitmap with
/// fewer pixels per point is left alone: inventing pixels would fake a density
/// the display cannot back.
enum CaptureDensity {
    /// Above the display's scale by more than this is inflation rather than
    /// round-off from a selection snapped to half points.
    static let tolerance: CGFloat = 0.05

    static func fitted(
        _ image: CGImage,
        for rect: CGSize,
        deviceScale: CGFloat
    ) -> (image: CGImage, scale: CGFloat) {
        let displayScale = max(1, deviceScale)
        let observed = CGFloat(image.width) / max(1, rect.width)
        guard observed > displayScale * (1 + tolerance) else {
            return (image, observed)
        }

        // Shrink uniformly, so a rect whose aspect disagrees with the bitmap
        // is not squeezed into it.
        let factor = displayScale / observed
        let size = CGSize(
            width: max(1, (CGFloat(image.width) * factor).rounded()),
            height: max(1, (CGFloat(image.height) * factor).rounded())
        )
        guard let fitted = resized(image, to: size) else { return (image, observed) }
        return (fitted, displayScale)
    }

    private static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

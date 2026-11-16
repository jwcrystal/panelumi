import CoreGraphics
import Foundation

/// Synthetic, deterministic test images shared by the screenshot tests.
enum TestFrames {
    /// A 640 × 480 grey-pattern frame; `offset` shifts the pattern by rows.
    static func frame(offset: Int) -> CGImage {
        let width = 640, height = 480
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = y + offset
            for x in 0..<width {
                let value = UInt8((row * 73 + x * 31 + (row / 9) * (x / 13)) % 223)
                let i = (y * width + x) * 4
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
            }
        }
        let data = Data(bytes) as CFData
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

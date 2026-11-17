import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Writes what the editor composed to the folder and format Settings ›
/// Screenshot picked.
enum ScreenshotSaver {
    @discardableResult
    static func save(
        _ image: NSImage,
        watermark: AnnotationRenderer.WatermarkOptions? = nil
    ) -> URL? {
        write(
            image,
            watermark: watermark,
            folder: ScreenshotPreferences.folder,
            format: ScreenshotPreferences.imageFormat,
            quality: ScreenshotPreferences.quality
        )
    }

    /// The seam tests use: settings are passed in rather than read.
    @discardableResult
    static func write(
        _ image: NSImage,
        watermark: AnnotationRenderer.WatermarkOptions?,
        folder: URL,
        format: ScreenshotPreferences.ImageFormat,
        quality: Double,
        date: Date = Date()
    ) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let name = ScreenshotPreferences.fileName(
            prefix: ScreenshotPreferences.prefix,
            at: date,
            format: format
        )
        let url = uniqueURL(in: folder, name: name)

        // The bitmap rep holds every captured pixel; asking the image itself
        // would rasterise it at its point size and halve a Retina capture.
        let bitmap = image.representations.lazy.compactMap { $0 as? NSBitmapImageRep }.first
        guard let cgImage = bitmap?.cgImage ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  format.utType.identifier as CFString,
                  1,
                  nil
              )
        else { return nil }

        var properties: [CFString: Any] = [:]
        if image.size.width > 0, image.size.height > 0 {
            properties[kCGImagePropertyDPIWidth] = 72 * CGFloat(cgImage.width) / image.size.width
            properties[kCGImagePropertyDPIHeight] = 72 * CGFloat(cgImage.height) / image.size.height
        }
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // The signature is burned into the pixels; these keys only keep the
        // text findable in the file's metadata.
        if let watermark {
            switch format {
            case .png:
                properties[kCGImagePropertyPNGDescription] = watermark.text
            case .jpeg, .heic:
                properties[kCGImagePropertyExifDictionary] = [
                    kCGImagePropertyExifUserComment: watermark.text,
                ] as CFDictionary
            }
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// Two captures inside the same second must not overwrite each other.
    private static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = name as NSString
        let stem = base.deletingPathExtension
        let ext = base.pathExtension

        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)_\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

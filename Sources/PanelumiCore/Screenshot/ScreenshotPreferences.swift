import AppKit
import Foundation
import UniformTypeIdentifiers

/// Everything Settings › Screenshot changes, in one place.
///
/// Values live in `UserDefaults` so the capture overlay can read them without
/// the settings window being open. Every getter has the same default the
/// settings UI shows, so a fresh install behaves as documented.
enum ScreenshotPreferences {
    // MARK: - Keys

    static let folderKey = "ScreenshotFolder"
    static let prefixKey = "ScreenshotFilenamePrefix"
    static let formatKey = "ScreenshotFormat"
    static let qualityKey = "ScreenshotQuality"
    static let delayKey = "ScreenshotDelay"
    static let colorFormatKey = "ScreenshotColorFormat"
    static let watermarkTextKey = "ScreenshotWatermarkText"
    static let watermarkDefaultKey = "ScreenshotWatermarkDefault"
    static let watermarkPlacementKey = "ScreenshotWatermarkPlacement"
    static let watermarkScaleKey = "ScreenshotWatermarkScale"
    static let watermarkRotationKey = "ScreenshotWatermarkRotation"
    static let watermarkOpacityKey = "ScreenshotWatermarkOpacity"
    static let watermarkColorKey = "ScreenshotWatermarkColor"
    static let annotationColorKey = "ScreenshotAnnotationColor"
    static let annotationLineWidthKey = "ScreenshotAnnotationLineWidth"
    static let highlighterWidthKey = "ScreenshotHighlighterWidth"
    static let recentAnnotationColorsKey = "ScreenshotRecentAnnotationColors"
    static let silentRecognitionKey = "TextRecognitionSilent"
    static let autoCopyRecognitionKey = "TextRecognitionAutoCopy"
    static let qrLinkActionKey = "TextRecognitionQRLinkAction"
    static let toastSecondsKey = "TextRecognitionToastSeconds"

    /// What happens when the recognised QR code is an http(s) link.
    enum QRLinkAction: String, CaseIterable, Identifiable {
        /// Copy it like any other result (the default).
        case copy
        /// Open it in the default browser, and copy it as well.
        case open

        var id: String { rawValue }
    }

    static var qrLinkAction: QRLinkAction {
        get { QRLinkAction(rawValue: UserDefaults.standard.string(forKey: qrLinkActionKey) ?? "") ?? .copy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: qrLinkActionKey) }
    }

    /// Choices offered for how long a recognition toast stays up.
    static let toastSecondsChoices = [2, 3, 5, 8]
    static let defaultToastSeconds = 3

    static var toastSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: toastSecondsKey)
            return toastSecondsChoices.contains(stored) ? stored : defaultToastSeconds
        }
        set { UserDefaults.standard.set(newValue, forKey: toastSecondsKey) }
    }

    /// The result window also copies the text as it opens, so a quick look
    /// needs no extra click. Off by default; silent recognition always copies.
    static var autoCopyRecognition: Bool {
        get { UserDefaults.standard.bool(forKey: autoCopyRecognitionKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoCopyRecognitionKey) }
    }

    /// Text recognition copies straight to the clipboard and shows a toast
    /// instead of opening the result window. Off by default.
    static var silentRecognition: Bool {
        get { UserDefaults.standard.bool(forKey: silentRecognitionKey) }
        set { UserDefaults.standard.set(newValue, forKey: silentRecognitionKey) }
    }

    // MARK: - Storage

    enum ImageFormat: String, CaseIterable, Identifiable {
        case png, jpeg, heic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            }
        }

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            }
        }

        var fileExtension: String { utType.preferredFilenameExtension ?? "png" }

        /// JPEG and HEIC are the only formats with a quality knob.
        var isLossy: Bool { self != .png }
    }

    enum ColorFormat: Int, CaseIterable, Identifiable {
        case hex, rgb, hsl

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .hex: return "HEX"
            case .rgb: return "RGB"
            case .hsl: return "HSL"
            }
        }

        var next: ColorFormat {
            ColorFormat(rawValue: (rawValue + 1) % ColorFormat.allCases.count) ?? .hex
        }
    }

    // MARK: - Folder and name

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return downloads
    }

    static var prefix: String {
        sanitizedPrefix(UserDefaults.standard.string(forKey: prefixKey) ?? "Panelumi")
    }

    /// A prefix becomes part of a file name, so a slash would quietly turn it
    /// into a folder, and spaces would break the compact `_`-joined scheme.
    static func sanitizedPrefix(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
    }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .png
    }

    /// 0…1, clamped; only meaningful for JPEG and HEIC.
    static var quality: Double {
        guard UserDefaults.standard.object(forKey: qualityKey) != nil else { return 0.9 }
        return min(1, max(0.1, UserDefaults.standard.double(forKey: qualityKey)))
    }

    /// `prefix` defaults to the stored one; the settings pane passes what is
    /// typed so the preview updates before it is saved.
    ///
    /// The name is space-free and sorts chronologically:
    /// `Panelumi_Screenshot_2026-11-13_09-07-55.png`.
    static func fileName(
        prefix: String? = nil,
        at date: Date = Date(),
        format: ImageFormat? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ext = (format ?? imageFormat).fileExtension
        let stamp = formatter.string(from: date)
        let name = sanitizedPrefix(prefix ?? self.prefix)
        return name.isEmpty
            ? "Screenshot_\(stamp).\(ext)"
            : "\(name)_Screenshot_\(stamp).\(ext)"
    }

    // MARK: - Capture

    /// Seconds the overlay waits. 0 turns the delay off.
    static var delaySeconds: Int {
        let value = UserDefaults.standard.integer(forKey: delayKey)
        return [0, 3, 5, 10].contains(value) ? value : 0
    }

    static var colorFormat: ColorFormat {
        ColorFormat(rawValue: UserDefaults.standard.integer(forKey: colorFormatKey)) ?? .hex
    }

    static func setColorFormat(_ format: ColorFormat) {
        UserDefaults.standard.set(format.rawValue, forKey: colorFormatKey)
    }

    // MARK: - Watermark

    /// Empty means "use the macOS full user name", which is what a new install
    /// gets.
    static var watermarkText: String {
        (UserDefaults.standard.string(forKey: watermarkTextKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var defaultWatermarkText: String {
        let name = NSFullUserName()
        return name.isEmpty ? "Panelumi" : name
    }

    static var watermarkOnByDefault: Bool {
        UserDefaults.standard.bool(forKey: watermarkDefaultKey)
    }

    /// The appearance every capture starts from; the editor's popover changes
    /// only the current capture.
    static let defaultWatermarkPlacement: AnnotationRenderer.WatermarkOptions.Placement = .bottomRight
    static let defaultWatermarkScale: CGFloat = 0.02
    static let watermarkScaleRange: ClosedRange<CGFloat> = 0.01...0.06
    static let defaultWatermarkRotation: CGFloat = 0
    static let watermarkRotationRange: ClosedRange<CGFloat> = -90...90
    static let defaultWatermarkOpacity: CGFloat = 0.6
    static let watermarkOpacityRange: ClosedRange<CGFloat> = 0.15...1
    static let defaultWatermarkColor = "#FFFFFF"

    static var watermarkPlacement: AnnotationRenderer.WatermarkOptions.Placement {
        get {
            AnnotationRenderer.WatermarkOptions.Placement(
                rawValue: UserDefaults.standard.string(forKey: watermarkPlacementKey) ?? ""
            ) ?? defaultWatermarkPlacement
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: watermarkPlacementKey) }
    }

    static var watermarkScale: CGFloat {
        get { storedClamped(watermarkScaleKey, default: defaultWatermarkScale, range: watermarkScaleRange) }
        set { storeClamped(newValue, forKey: watermarkScaleKey, default: defaultWatermarkScale, range: watermarkScaleRange) }
    }

    static var watermarkRotation: CGFloat {
        get { storedClamped(watermarkRotationKey, default: defaultWatermarkRotation, range: watermarkRotationRange) }
        set { storeClamped(newValue, forKey: watermarkRotationKey, default: defaultWatermarkRotation, range: watermarkRotationRange) }
    }

    static var watermarkOpacity: CGFloat {
        get { storedClamped(watermarkOpacityKey, default: defaultWatermarkOpacity, range: watermarkOpacityRange) }
        set { storeClamped(newValue, forKey: watermarkOpacityKey, default: defaultWatermarkOpacity, range: watermarkOpacityRange) }
    }

    static var watermarkColor: String {
        get {
            AnnotationPalette.canonicalHex(
                UserDefaults.standard.string(forKey: watermarkColorKey) ?? ""
            ) ?? defaultWatermarkColor
        }
        set {
            UserDefaults.standard.set(
                AnnotationPalette.canonicalHex(newValue) ?? defaultWatermarkColor,
                forKey: watermarkColorKey
            )
        }
    }

    private static func storedClamped(
        _ key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard let stored = UserDefaults.standard.object(forKey: key) as? NSNumber else { return defaultValue }
        let value = CGFloat(stored.doubleValue)
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func storeClamped(
        _ value: CGFloat,
        forKey key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) {
        let resolved = value.isFinite ? value : defaultValue
        UserDefaults.standard.set(
            Double(min(max(resolved, range.lowerBound), range.upperBound)),
            forKey: key
        )
    }

    // MARK: - Annotation

    static let defaultAnnotationColor = "#FF3B30"
    static let defaultAnnotationLineWidth: CGFloat = 0.004
    static let annotationLineWidthRange: ClosedRange<CGFloat> = 0.0015...0.016
    /// The default matches the pen width the highlighter used when it shared
    /// the pen's value with a ×5 factor.
    static let defaultHighlighterWidth: CGFloat = 0.02
    static let highlighterWidthRange: ClosedRange<CGFloat> = 0.006...0.026

    static var annotationColor: String {
        get {
            AnnotationPalette.canonicalHex(
                UserDefaults.standard.string(forKey: annotationColorKey) ?? ""
            ) ?? defaultAnnotationColor
        }
        set {
            UserDefaults.standard.set(
                AnnotationPalette.canonicalHex(newValue) ?? defaultAnnotationColor,
                forKey: annotationColorKey
            )
        }
    }

    /// Width relative to the image, kept inside the slider's range. A value
    /// that is not a number falls back to the default.
    static var annotationLineWidth: CGFloat {
        get {
            guard let stored = UserDefaults.standard.object(forKey: annotationLineWidthKey) as? NSNumber
            else { return defaultAnnotationLineWidth }
            let value = CGFloat(stored.doubleValue)
            guard value.isFinite else { return defaultAnnotationLineWidth }
            return min(max(value, annotationLineWidthRange.lowerBound), annotationLineWidthRange.upperBound)
        }
        set {
            let value = newValue.isFinite ? newValue : defaultAnnotationLineWidth
            UserDefaults.standard.set(
                Double(min(max(value, annotationLineWidthRange.lowerBound), annotationLineWidthRange.upperBound)),
                forKey: annotationLineWidthKey
            )
        }
    }

    /// Highlighter band thickness relative to the image, kept inside the
    /// slider's range. A value that is not a number falls back to the default.
    static var highlighterWidth: CGFloat {
        get {
            guard let stored = UserDefaults.standard.object(forKey: highlighterWidthKey) as? NSNumber
            else { return defaultHighlighterWidth }
            let value = CGFloat(stored.doubleValue)
            guard value.isFinite else { return defaultHighlighterWidth }
            return min(max(value, highlighterWidthRange.lowerBound), highlighterWidthRange.upperBound)
        }
        set {
            let value = newValue.isFinite ? newValue : defaultHighlighterWidth
            UserDefaults.standard.set(
                Double(min(max(value, highlighterWidthRange.lowerBound), highlighterWidthRange.upperBound)),
                forKey: highlighterWidthKey
            )
        }
    }

    static var recentAnnotationColors: [String] {
        get {
            AnnotationPalette.sanitizedRecent(
                UserDefaults.standard.stringArray(forKey: recentAnnotationColorsKey) ?? []
            )
        }
        set {
            UserDefaults.standard.set(
                AnnotationPalette.sanitizedRecent(newValue),
                forKey: recentAnnotationColorsKey
            )
        }
    }
}

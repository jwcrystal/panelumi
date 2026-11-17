import AppKit
import Foundation
import SwiftUI
import SwitchKit

/// The colours shared by the annotation popover and the watermark colour row.
enum AnnotationPalette {
    struct Swatch: Identifiable, Equatable {
        let hex: String
        let name: String

        var id: String { hex }
        var color: Color { AnnotationPalette.color(fromHex: hex) ?? .black }
    }

    static let recentLimit = 5

    static let presets: [Swatch] = [
        Swatch(hex: "#FF3B30", name: t("Red")),
        Swatch(hex: "#FF9500", name: t("Orange")),
        Swatch(hex: "#FFCC00", name: t("Yellow")),
        Swatch(hex: "#34C759", name: t("Green")),
        Swatch(hex: "#32ADE6", name: t("Cyan")),
        Swatch(hex: "#0A84FF", name: t("Blue")),
        Swatch(hex: "#AF52DE", name: t("Purple")),
        Swatch(hex: "#FF2D55", name: t("Pink")),
        Swatch(hex: "#FFFFFF", name: t("White")),
        Swatch(hex: "#000000", name: t("Black")),
    ]

    static var presetHexes: Set<String> { Set(presets.map(\.hex)) }

    static func isPreset(_ hex: String) -> Bool {
        guard let canonical = canonicalHex(hex) else { return false }
        return presetHexes.contains(canonical)
    }

    /// `#RRGGBB` in uppercase. Accepts a missing `#` and any letter case.
    static func canonicalHex(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + text.uppercased()
    }

    static func color(fromHex raw: String) -> Color? {
        nsColor(fromHex: raw).map(Color.init(nsColor:))
    }

    /// The 0…255 channels the hex field and the RGB sliders share.
    struct RGB: Equatable {
        var red: Int
        var green: Int
        var blue: Int
    }

    static func nsColor(fromHex raw: String) -> NSColor? {
        guard let rgb = rgb(fromHex: raw) else { return nil }
        return NSColor(
            srgbRed: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }

    static func rgb(fromHex raw: String) -> RGB? {
        guard let canonical = canonicalHex(raw),
              let value = UInt32(canonical.dropFirst(), radix: 16)
        else { return nil }
        return RGB(
            red: Int((value >> 16) & 0xFF),
            green: Int((value >> 8) & 0xFF),
            blue: Int(value & 0xFF)
        )
    }

    static func rgb(for color: Color) -> RGB? {
        rgb(for: NSColor(color))
    }

    static func rgb(for color: NSColor) -> RGB? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return RGB(
            red: channel(srgb.redComponent),
            green: channel(srgb.greenComponent),
            blue: channel(srgb.blueComponent)
        )
    }

    static func color(_ rgb: RGB) -> Color {
        Color(
            .sRGB,
            red: CGFloat(min(255, max(0, rgb.red))) / 255,
            green: CGFloat(min(255, max(0, rgb.green))) / 255,
            blue: CGFloat(min(255, max(0, rgb.blue))) / 255,
            opacity: 1
        )
    }

    private static func channel(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// sRGB `#RRGGBB`; nil when the colour cannot be converted.
    static func hex(for color: Color) -> String? {
        hex(for: NSColor(color))
    }

    static func hex(for color: NSColor) -> String? {
        guard let rgb = rgb(for: color) else { return nil }
        return String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    /// The recent list after picking `hex`. Presets are never stored: they
    /// always sit in the grid above. A colour already in the list moves to the
    /// front, and the list keeps `recentLimit` entries.
    static func addingRecent(_ hex: String, to recent: [String]) -> [String] {
        let cleaned = sanitizedRecent(recent)
        guard let canonical = canonicalHex(hex), !isPreset(canonical) else { return cleaned }
        var updated = cleaned.filter { $0 != canonical }
        updated.insert(canonical, at: 0)
        return Array(updated.prefix(recentLimit))
    }

    static func sanitizedRecent(_ recent: [String]) -> [String] {
        var seen = Set<String>()
        return recent.compactMap { raw in
            guard let hex = canonicalHex(raw), !isPreset(hex), seen.insert(hex).inserted else { return nil }
            return hex
        }.prefix(recentLimit).map { $0 }
    }
}

/// One circle in the annotation popover or the watermark colour row.
struct AnnotationColorSwatch: View {
    let color: Color
    let name: String
    let selected: Bool
    var diameter: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle().strokeBorder(
                        Color.primary.opacity(selected ? 0.85 : 0.25),
                        lineWidth: selected ? 2 : 1
                    )
                }
                .overlay {
                    if selected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

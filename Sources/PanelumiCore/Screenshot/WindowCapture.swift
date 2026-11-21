import AppKit

/// A window the user picked, in the overlay's screen coordinates
/// (bottom-left origin), so the editor's selection and the composer share one
/// coordinate space.
struct CaptureWindowTarget: Equatable {
    let id: CGWindowID
    let rect: CGRect
}

/// A window that was on screen when the freeze was taken. The pointer is
/// matched against this list first, because activating the overlay dismisses
/// menus, popovers and panels before the overlay can ask about them.
struct PressWindow: Equatable {
    let id: CGWindowID
    let layer: Int
    /// What the window actually draws, in global top-left coordinates. A panel
    /// like Control Center lives in a window far larger than itself, with the
    /// rest transparent, so this is the trimmed rect, not the window's frame.
    let bounds: CGRect
}

/// The part of a captured window that is really drawn.
enum WindowTrim {
    /// Crops a window capture to its non-transparent content.
    ///
    /// `bounds` is the window's frame in global top-left coordinates. A window
    /// without alpha keeps all of it.
    static func content(of image: CGImage, in bounds: CGRect) -> (image: CGImage, rect: CGRect)? {
        guard hasAlpha(image) else { return (image, bounds) }
        // An alpha channel with nothing drawn in it is an empty window, and an
        // empty shot is worse than no pick at all.
        guard let box = alphaBounds(of: image) else { return nil }
        let scale = CGFloat(image.width) / max(1, bounds.width)
        guard let cropped = image.cropping(to: box) else { return nil }
        return (
            cropped,
            CGRect(
                x: bounds.minX + box.minX / scale,
                y: bounds.minY + box.minY / scale,
                width: box.width / scale,
                height: box.height / scale
            )
        )
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    /// The bounding box of the pixels that are not transparent, in the image's
    /// own top-left space. Nil when nothing is drawn.
    static func alphaBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }

        // Drawing over black leaves transparent pixels at zero and everything
        // else at its own luminance, so the box is where anything is drawn.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let row = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: row * height)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let start = y * row
            for x in 0..<width where pixels[start + x] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Which windows a pick may land on.
enum WindowPick {
    /// Application windows. They are still on screen when the click lands, so
    /// they are captured live and keep their own pixels.
    static let liveLayers = NSWindow.Level.normal.rawValue...NSWindow.Level.modalPanel.rawValue

    /// Status items (25), menus and popovers (101) and the floating widgets
    /// apps put at the screen saver level (1000). They are gone once the
    /// overlay takes the keyboard, so each is captured at the press.
    ///
    /// The menu bar (24) stays out on purpose: it is a 33-point strip across
    /// the top, which is what the pointer rests on right after its icon was
    /// clicked to open a panel, so it would answer instead of the panel the
    /// user is aiming at. The cursor sits above the ceiling.
    static func isFrozenOnly(layer: Int) -> Bool {
        layer >= NSWindow.Level.statusBar.rawValue
            && layer <= NSWindow.Level.screenSaver.rawValue
    }

    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

    /// The Dock is picked, but not captured: its window is the whole display,
    /// so the pick is `dockStrip(frame:visible:)` and its pixels come from the
    /// frozen frame.
    static func isDock(layer: Int) -> Bool {
        layer == dockLayer
    }

    static func isPickable(layer: Int) -> Bool {
        liveLayers.contains(layer) || isDock(layer: layer) || isFrozenOnly(layer: layer)
    }

    /// The strip the Dock draws, from the screen's frame and its visible frame.
    ///
    /// The Dock's window covers the whole display, so its own frame cannot be
    /// the pick; what it covers is exactly what the screen loses to it. Nil when
    /// the Dock is hidden, and then there is nothing to pick.
    static func dockStrip(frame: CGRect, visible: CGRect) -> CGRect? {
        let bottom = visible.minY - frame.minY
        if bottom >= 1 {
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bottom)
        }
        let left = visible.minX - frame.minX
        if left >= 1 {
            return CGRect(x: frame.minX, y: visible.minY, width: left, height: visible.height)
        }
        let right = frame.maxX - visible.maxX
        if right >= 1 {
            return CGRect(x: visible.maxX, y: visible.minY, width: right, height: visible.height)
        }
        return nil
    }

    /// A sliver of an application window is not something a user aims at, but a
    /// menu or a tooltip can legitimately be smaller.
    static func minimumSize(layer: Int) -> CGFloat {
        isFrozenOnly(layer: layer) ? 16 : 60
    }

    /// Keeps every pickable window on screen, in the list's own order: front to
    /// back. Taken at the press, because a panel that closes the moment the
    /// overlay activates is not in any list read afterwards.
    static func pressSnapshot(
        from list: [[String: Any]],
        excluding: Set<CGWindowID> = []
    ) -> [PressWindow] {
        list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !excluding.contains(id),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  isPickable(layer: layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= minimumSize(layer: layer),
                  bounds.height >= minimumSize(layer: layer)
            else { return nil }
            return PressWindow(id: id, layer: layer, bounds: bounds)
        }
    }

    /// The topmost window under a point.
    static func window(at point: CGPoint, in snapshot: [PressWindow]) -> PressWindow? {
        snapshot.first { $0.bounds.contains(point) }
    }
}

/// Composes one capture per window into a single image, keeping the windows at
/// their on-screen positions and drawing the shadow itself.
///
/// ScreenCaptureKit can include a window's own shadow, but it then shrinks the
/// window to fit the requested buffer. Drawing the shadow here keeps the window
/// content at native resolution and gives one predictable canvas for both a
/// single window and several.
enum WindowComposer {
    static let shadowBlur: CGFloat = 18
    /// The drawing context has a bottom-left origin, so negative height moves
    /// the shadow down while the window keeps its on-screen position.
    static let shadowOffset = NSSize(width: 0, height: -6)
    static let shadowOpacity: CGFloat = 0.35

    /// Match the selected window bounds exactly. Shadows may draw inside this
    /// canvas but never add blank margins outside the selection.
    static func canvas(for targets: [CaptureWindowTarget], screenBounds: CGRect) -> CGRect? {
        guard let first = targets.first else { return nil }
        let union = targets.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let clipped = union.intersection(screenBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }

    /// `shots` carry the window rects in the same space as `canvas`.
    static func compose(
        shots: [(image: CGImage, rect: CGRect)],
        canvas: CGRect,
        scale: CGFloat
    ) -> CGImage? {
        let safeScale = max(1, scale)
        let pixelWidth = Int((canvas.width * safeScale).rounded())
        let pixelHeight = Int((canvas.height * safeScale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: safeScale, y: safeScale)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        for shot in shots {
            // Both the window rect and CGContext use bottom-left coordinates.
            // Flipping y here would mirror the layout within the selection.
            let drawRect = shot.rect.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
            guard drawRect.width >= 1, drawRect.height >= 1 else { continue }

            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: shadowOpacity)
            shadow.shadowBlurRadius = shadowBlur
            shadow.shadowOffset = shadowOffset
            shadow.set()

            NSImage(cgImage: shot.image, size: drawRect.size).draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        return context.makeImage()
    }
}

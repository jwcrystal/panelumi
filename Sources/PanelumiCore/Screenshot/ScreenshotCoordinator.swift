import AppKit
import ImageIO
import PanelumiKit
import UniformTypeIdentifiers

/// Owns the screenshot flow: in-place selection and editing, then capture,
/// compose and deliver (copy, save or pin).
@MainActor
final class ScreenshotCoordinator {
    private let selections: SelectionController
    private let capture = ScreenCaptureService()
    /// Base-region and live captures share the capture service's content
    /// cache, so they run one at a time. Window captures are not serialised.
    private let captureGate = SerialAsyncGate()
    /// Replaces the service call behind a region capture. Tests set it to see
    /// which path a capture takes without Screen Recording; nil uses the real
    /// service.
    var regionCaptureHook: (@MainActor (CGRect, NSScreen) async -> CGImage?)?
    /// Replaces the service call behind a freeze. Tests set it to open the
    /// overlay without Screen Recording; nil uses the real service. Every
    /// display is asked for one frame, in screen order.
    var displayCaptureHook: (@MainActor (CGDirectDisplayID) async -> CGImage?)?
    /// The Screen Recording grant, read without prompting: a preflight costs a
    /// few microseconds and shows no UI, while asking for the grant does both.
    /// Tests replace it.
    var screenRecordingGranted: () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// Called when a capture failed only because macOS has not granted Screen
    /// Recording. The app answers by opening the permission checklist.
    var onPermissionFailure: (() -> Void)?
    private var pinnedWindows: [NSWindow] = []
    private var countdown: CaptureCountdown?
    /// The freeze that runs before the overlay opens. Held so the next press
    /// can call the capture off while there is no overlay to take the cancel.
    private var pendingFreeze: Task<Void, Never>?
    /// Frames taken before the overlay opened, keyed by display. Regions are
    /// cut from these instead of the live screen, so the shot is the instant
    /// the shortcut was pressed: menus, popovers and tooltips that the
    /// overlay's activation dismisses are still in the picture, and nothing
    /// moves under the cursor while the region is chosen. Internal so a capture
    /// can be checked against a seeded frame.
    var frozenScreens: [CGDirectDisplayID: CGImage] = [:]
    /// The pixels of each menu, popover or status item captured before the app
    /// activated, by window id. They are gone from the screen by click time.
    private var frozenWindowImages: [CGWindowID: CGImage] = [:]
    private let recognitionWindow = TextRecognitionWindowController()

    /// Creates the coordinator; extensions are offered to the capture toolbar.
    init(captureExtensions: [any CaptureExtension] = []) {
        selections = SelectionController(captureExtensions: captureExtensions)
    }

    /// The catalog id, also used for the shortcut the settings pane edits.
    static let id = "screenshot"

    var switchItem: SwitchItem {
        SwitchItem(
            id: Self.id,
            title: t("Screenshot"),
            symbolName: "camera.viewfinder",
            kind: .action,
            perform: { [weak self] in self?.begin() }
        )
    }

    /// The text-recognition switch: same overlay, no editor.
    static let recognizeTextID = "recognizeText"

    var recognizeTextItem: SwitchItem {
        SwitchItem(
            id: Self.recognizeTextID,
            title: t("Recognize Text"),
            symbolName: "text.viewfinder",
            kind: .action,
            perform: { [weak self] in self?.beginTextRecognition() }
        )
    }

    /// Select a region or window, then read its text. There is no delay and
    /// no editor: choosing the area is the whole interaction.
    func beginTextRecognition() {
        guard !selections.isActive, countdown == nil, pendingFreeze == nil else { return }
        guard requireScreenRecording() else { return }
        // Load the models while the user is still selecting.
        Task.detached(priority: .userInitiated) { TextRecognizer.warmUp() }
        startFrozen(initialSelection: nil, finishOnSelect: .recognizeText)
    }

    /// Debug (`--ocr-demo`): recognition over `$PANELUMI_DEMO_IMAGE`, so the
    /// result window and the silent toast can be checked without selecting.
    func beginRecognitionDemo() {
        guard let path = ProcessInfo.processInfo.environment["PANELUMI_DEMO_IMAGE"],
              let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("--ocr-demo needs PANELUMI_DEMO_IMAGE")
            return
        }
        Task { @MainActor in await recognizeText(in: image) }
    }

    /// Read-only state for tests: the capture overlay is open.
    var isSelectionActive: Bool { selections.isActive }

    deinit {
        pendingFreeze?.cancel()
        pinnedWindows.removeAll()
    }

    func begin() {
        guard !selections.isActive else { return }

        // A second press calls the capture off, whether the clock is running or
        // the freeze has started and no overlay is up to take the cancel.
        if let pendingFreeze {
            pendingFreeze.cancel()
            self.pendingFreeze = nil
            return
        }
        if let countdown {
            countdown.cancel()
            self.countdown = nil
            return
        }

        guard requireScreenRecording() else { return }

        let seconds = ScreenshotPreferences.delaySeconds
        guard seconds > 0 else {
            startFrozen(initialSelection: nil)
            return
        }

        let hud = CaptureCountdown(seconds: seconds)
        countdown = hud
        hud.start { [weak self] in
            guard let self else { return }
            self.countdown = nil
            Task { @MainActor in
                self.startFrozen(initialSelection: nil)
            }
        }
    }

    /// Debug: runs the real delayed path with a 3 second clock, so the pill and
    /// the frozen frame can be checked without pressing the shortcut.
    func beginTimedDemo() {
        let stored = UserDefaults.standard.object(forKey: ScreenshotPreferences.delayKey)
        UserDefaults.standard.set(3, forKey: ScreenshotPreferences.delayKey)
        begin()
        if let stored {
            UserDefaults.standard.set(stored, forKey: ScreenshotPreferences.delayKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ScreenshotPreferences.delayKey)
        }
    }

    /// Debug: opens the overlay with a region already in edit mode, so the
    /// toolbar layout can be checked without dragging.
    func beginDemo() {
        start(initialSelection: CGRect(x: 300, y: 240, width: 900, height: 520))
    }

    /// Debug (`--editor-demo`): the editor over a still image instead of the
    /// live desktop, so a README or a bug report never shows what is on screen.
    /// The image comes from `PANELUMI_DEMO_IMAGE`; without it the demo falls
    /// back to the frozen desktop, like `--selection-demo`.
    func beginEditorDemo() {
        var frozen: [CGDirectDisplayID: CGImage] = [:]
        if let path = ProcessInfo.processInfo.environment["PANELUMI_DEMO_IMAGE"],
           let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            for screen in NSScreen.screens {
                if let id = Self.displayID(for: screen) { frozen[id] = image }
            }
        }

        start(
            initialSelection: CGRect(x: 360, y: 200, width: 1000, height: 600),
            frozen: frozen
        )

        guard !frozen.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.selections.session.annotations = [
                Annotation(
                    shape: .rectangle(from: CGPoint(x: 0.09, y: 0.14), to: CGPoint(x: 0.54, y: 0.47)),
                    color: .red,
                    lineWidth: 0.005
                ),
                Annotation(
                    shape: .arrow(from: CGPoint(x: 0.60, y: 0.63), to: CGPoint(x: 0.87, y: 0.28)),
                    color: .red,
                    lineWidth: 0.005
                ),
                Annotation(
                    shape: .text("Panelumi", at: CGPoint(x: 0.10, y: 0.66)),
                    color: .red,
                    textScale: 0.045
                ),
            ]
        }
    }

    /// Debug: demo plus a tiled, rotated watermark.
    func beginWatermarkDemo() {
        beginDemo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.selections.session.watermarkEnabled = true
            self.selections.session.watermarkPlacement = .tiled
            self.selections.session.watermarkRotation = -30
            self.selections.session.watermarkOpacity = 0.25
        }
    }

    /// Debug: demo selection, saved straight to the configured folder.
    func beginDemoSave() {
        beginDemo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.selections.completeForDebug(.save)
        }
    }

    /// Debug: compares a normal capture with one that excludes capture UI while
    /// the overlay is up, to prove the overlay is not baked into the image.
    func compareCaptures() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        guard let displayID = Self.displayID(for: screen) else { return }

        Task {
            let plain = try? await capture.captureDisplay(displayID: displayID)
            let excluded = try? await capture.captureDisplay(
                displayID: displayID, excludingWindowIDs: SelectionController.overlayWindowIDs
            )

            for (name, image) in [("plain", plain), ("excluded", excluded)] {
                guard let image else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let data = rep.representation(using: .png, properties: [:])
                try? data?.write(to: URL(fileURLWithPath: "/tmp/sd-capture-\(name).png"))
            }
        }
    }

    /// Debug: demo selection, then copy it after a moment. Verifies the whole
    /// capture → compose → clipboard path without any clicking.
    func beginDemoCopy() {
        beginDemo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            let mosaic = Annotation(
                shape: .mosaic(from: CGPoint(x: 0.1, y: 0.2), to: CGPoint(x: 0.45, y: 0.7)),
                color: .red
            )
            let blur = Annotation(
                shape: .blur(from: CGPoint(x: 0.55, y: 0.2), to: CGPoint(x: 0.9, y: 0.5)),
                color: .red
            )
            self?.selections.completeForDebug(.copy, extraAnnotations: [mosaic, blur])
        }
    }

    /// Freezes every display, then opens the overlay on those frames.
    ///
    /// The overlay activates the app, which dismisses menus, popovers and
    /// tooltips, and the screen keeps moving underneath it. Freezing first
    /// makes the pixels a region is cut from the instant the shortcut was
    /// pressed, and holds them still while the region is chosen.
    private func startFrozen(
        initialSelection: CGRect?,
        finishOnSelect: CaptureSession.Output? = nil
    ) {
        pendingFreeze?.cancel()
        pendingFreeze = Task { [weak self] in
            guard let self else { return }
            // Before anything activates, while a menu or a panel is still up.
            let candidates = Self.windowSnapshot()
            let frozen = await self.captureEveryScreen()
            let windows = await self.capturedWindows(from: candidates)
            guard !Task.isCancelled else { return }
            self.pendingFreeze = nil
            self.start(
                initialSelection: initialSelection,
                frozen: frozen,
                pressWindows: windows,
                finishOnSelect: finishOnSelect
            )
        }
    }

    private func start(
        initialSelection: CGRect?,
        frozen: [CGDirectDisplayID: CGImage] = [:],
        pressWindows: [PressWindow] = [],
        finishOnSelect: CaptureSession.Output? = nil
    ) {
        guard !selections.isActive else { return }
        // A delayed capture reaches here after the countdown, so the grant is
        // checked again rather than trusted from the first press.
        guard requireScreenRecording() else { return }

        frozenScreens = frozen
        selections.session.prepareForCapture()

        selections.begin(
            onCapture: { [weak self] payload, output in
                Task { @MainActor in
                    await self?.finish(payload, output)
                }
            },
            onCancel: { [weak self] in
                self?.frozenScreens.removeAll()
                self?.frozenWindowImages.removeAll()
            },
            captureBase: { [weak self] rect, screen in
                await self?.captureRegion(rect, screen)
            },
            captureWindows: { [weak self] targets, canvas, screen in
                guard let self else { return nil }
                let image = await self.captureWindows(targets, canvas: canvas, screen: screen)
                if image == nil, !self.screenRecordingGranted() {
                    self.abortForMissingPermission()
                }
                return image
            },
            initialSelection: initialSelection,
            frozen: { [weak self] screen in
                guard let self, let id = Self.displayID(for: screen) else { return nil }
                return self.frozenScreens[id]
            },
            pressWindows: pressWindows,
            finishOnSelect: finishOnSelect,
            captureLive: { [weak self] rect, screen in
                await self?.captureLiveRegion(rect, screen)
            }
        )
    }

    /// Every capture entry point runs this before it draws anything. The
    /// checklist is the only place that asks for the grant and explains that
    /// macOS applies it on the next launch.
    private func requireScreenRecording() -> Bool {
        guard screenRecordingGranted() else {
            onPermissionFailure?()
            return false
        }
        return true
    }

    /// The overlay sits above every ordinary window, so it has to close before
    /// the checklist opens; otherwise the checklist is drawn behind it.
    private func abortForMissingPermission() {
        selections.abort()
        onPermissionFailure?()
    }

    /// A nil region capture means different things: an empty selection, or a
    /// grant that is not there. Only the second one has an answer.
    static func regionCaptureFailure(permissionGranted: Bool) -> ScreenCaptureService.CaptureError {
        permissionGranted
            ? .captureFailed(t("The selected area was empty."))
            : .permission
    }

    /// The menu, popover and status item windows on screen right now, as ids
    /// and frames. Taken at the press: activating the app is what dismisses
    /// them, so a list read after that has nothing left to answer with.
    private static func windowSnapshot() -> [PressWindow] {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let excluded = SelectionController.overlayWindowIDs
        let snapshot = WindowPick.pressSnapshot(from: list, excluding: excluded)
        return snapshot
    }

    /// Captures the windows a live list cannot be asked about any more, on
    /// their own, then crops to what they draw: a panel like Control Center sits
    /// in a window far larger than itself with the rest transparent, so its
    /// frame is not what the user aimed at. Ordinary windows are left to the
    /// click, so a window that moved is captured where it is by then.
    private func capturedWindows(from candidates: [PressWindow]) async -> [PressWindow] {
        var captured: [PressWindow] = []
        for candidate in candidates {
            guard WindowPick.isFrozenOnly(layer: candidate.layer) else {
                captured.append(candidate)
                continue
            }
            guard let image = try? await capture.captureWindow(windowID: candidate.id) else {
                // Still pickable: the click can cut it from the frozen frame.
                captured.append(candidate)
                continue
            }
            guard let trimmed = WindowTrim.content(of: image, in: candidate.bounds),
                  trimmed.rect.width >= 8, trimmed.rect.height >= 8
            else { continue }
            frozenWindowImages[candidate.id] = trimmed.image
            captured.append(
                PressWindow(id: candidate.id, layer: candidate.layer, bounds: trimmed.rect)
            )
        }
        return captured
    }

    /// One frame per display, taken while the desktop is still untouched.
    private func captureEveryScreen() async -> [CGDirectDisplayID: CGImage] {
        var frames: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            if Task.isCancelled { break }
            guard let id = Self.displayID(for: screen) else { continue }
            let image: CGImage?
            if let hook = displayCaptureHook {
                image = await hook(id)
            } else {
                image = try? await capture.captureDisplay(
                    displayID: id, excludingWindowIDs: SelectionController.overlayWindowIDs
                )
            }
            guard let image else { continue }
            frames[id] = image
        }
        return frames
    }

    /// A frame of one region, in screen points. A frozen frame is cropped
    /// directly for a non-live capture; every other capture runs the service
    /// through `captureGate`.
    func captureRegion(_ rect: CGRect, _ screen: NSScreen, live: Bool = false) async -> CGImage? {
        guard let displayID = Self.displayID(for: screen) else { return nil }

        if !live, let frozen = frozenScreens[displayID] {
            return ScreenCaptureService.crop(image: frozen, to: rect, screenFrame: screen.frame)
        }

        return await captureGate.run {
            if Task.isCancelled { return nil }
            if let hook = self.regionCaptureHook {
                return await hook(rect, screen)
            }
            return await self.captureRegionFromService(displayID, rect, screen)
        }
    }

    /// The service call behind a base or live capture. Kept in its own method so
    /// its call shape matches the capture it replaces.
    private func captureRegionFromService(
        _ displayID: CGDirectDisplayID,
        _ rect: CGRect,
        _ screen: NSScreen
    ) async -> CGImage? {
        return try? await capture.captureRegion(
            displayID: displayID,
            rect: rect,
            screenFrame: screen.frame,
            excludingWindowIDs: SelectionController.overlayWindowIDs
        )
    }

    /// A frame from the live screen for an extension, never the frozen one a
    /// timed capture keeps. The exclusion set is read inside the gate, so a
    /// window attached while the call waited is left out.
    private func captureLiveRegion(_ rect: CGRect, _ screen: NSScreen) async -> CGImage? {
        await captureRegion(rect, screen, live: true)
    }

    /// Captures each picked window on its own, then lays them out at their
    /// on-screen positions. If any picked window vanishes, keep the selection
    /// failed rather than silently dropping a window or capturing the desktop.
    private func captureWindows(
        _ targets: [CaptureWindowTarget],
        canvas: CGRect,
        screen: NSScreen
    ) async -> CGImage? {
        guard !targets.isEmpty else { return nil }

        var shots: [(image: CGImage, rect: CGRect)] = []
        for target in targets {
            let shot: (image: CGImage, rect: CGRect)?
            if let image = frozenWindowImages[target.id] {
                shot = (image, target.rect)
            } else if let image = try? await capture.captureWindow(windowID: target.id) {
                shot = (image, target.rect)
            } else {
                // A panel that is not on a frozen layer but still closes the
                // moment the overlay takes the keyboard: the press-time frame
                // has it where it was picked, on screen.
                let visible = target.rect.intersection(CGRect(origin: .zero, size: screen.frame.size))
                shot = frozenPixels(of: visible, on: screen).map { ($0, visible) }
            }
            guard let shot else { return nil }
            shots.append(shot)
        }
        guard !shots.isEmpty else { return nil }

        return WindowComposer.compose(
            shots: shots,
            canvas: canvas,
            scale: screen.backingScaleFactor
        )
    }

    /// Cuts a rect of the frame frozen at the press, for a window that is gone
    /// by the time it would be captured live.
    private func frozenPixels(of rect: CGRect, on screen: NSScreen) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let displayID = Self.displayID(for: screen),
              let frame = frozenScreens[displayID] else { return nil }
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        return ScreenCaptureService.crop(image: frame, to: global, screenFrame: screen.frame)
    }

    // MARK: - Finish

    private func finish(_ payload: CapturePayload, _ output: CaptureSession.Output) async {
        defer {
            frozenScreens.removeAll()
            frozenWindowImages.removeAll()
        }
        do {
            // The overlay already froze the region for live mosaic/blur; only
            // capture again if that never arrived.
            let cropped: CGImage
            if let base = payload.base {
                cropped = base
            } else if let region = await captureRegion(payload.rect, payload.screen) {
                cropped = region
            } else {
                throw Self.regionCaptureFailure(permissionGranted: screenRecordingGranted())
            }

            if output == .recognizeText {
                await recognizeText(in: cropped)
                return
            }

            let visibleWatermark = payload.watermarkVisible ? payload.watermark : nil
            // The saved density is decided here, once for copy, save and pin:
            // pixels the display cannot back are never tagged as if it could.
            let (base, scale) = CaptureDensity.fitted(
                cropped,
                for: payload.rect.size,
                deviceScale: payload.screen.backingScaleFactor
            )
            reportDensity(of: cropped, fitted: base, scale: scale, payload: payload)
            let image = AnnotationRenderer.render(
                base: base,
                annotations: payload.annotations,
                watermark: visibleWatermark,
                pointScale: scale
            )

            switch output {
            case .copy:
                copy(image)
            case .save:
                save(image, watermark: payload.watermark)
            case .pin:
                pin(image, at: payload.rect)
            case .recognizeText:
                break
            }
        } catch {
            present(error)
        }
    }

    /// `PANELUMI_CAPTURE_DIAGNOSTICS=1` prints what the capture returned next
    /// to what the overlay selected, so a density that disagrees with the
    /// display can be traced to the frozen frame, the live capture or a window
    /// composite instead of being silently rescaled.
    private func reportDensity(
        of cropped: CGImage,
        fitted: CGImage,
        scale: CGFloat,
        payload: CapturePayload
    ) {
        guard ProcessInfo.processInfo.environment["PANELUMI_CAPTURE_DIAGNOSTICS"] == "1" else { return }
        print(
            "capture density: rect \(payload.rect.width)x\(payload.rect.height) pt, "
                + "pixels \(cropped.width)x\(cropped.height) -> \(fitted.width)x\(fitted.height), "
                + "scale \(scale), display \(payload.screen.backingScaleFactor)"
        )
    }

    private func recognizeText(in image: CGImage) async {
        let result: TextRecognizer.Result
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try TextRecognizer.recognize(image)
            }.value
        } catch {
            present(error, title: t("Recognize Text"))
            return
        }

        let preview = NSImage(cgImage: image, size: .zero)

        // A QR link set to open skips the window: open it, copy it, say so.
        if ScreenshotPreferences.qrLinkAction == .open, let link = TextRecognizer.openableLink(in: result.codes) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            NSWorkspace.shared.open(link)
            RecognitionToast.show(t("Opened QR link"), detail: link.absoluteString) { [weak self] in
                self?.recognitionWindow.show(image: preview, result: result)
            }
            return
        }

        guard ScreenshotPreferences.silentRecognition else {
            var autoCopied = false
            if ScreenshotPreferences.autoCopyRecognition, let text = result.clipboardText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                autoCopied = true
            }
            recognitionWindow.show(image: preview, result: result, autoCopied: autoCopied)
            return
        }

        guard let text = result.clipboardText else {
            RecognitionToast.show(t("No text found"), detail: nil) { [weak self] in
                self?.recognitionWindow.show(image: preview, result: result)
            }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        RecognitionToast.show(
            result.foundCode ? t("Copied QR code") : t("Copied text"),
            detail: RecognitionToast.preview(of: text)
        ) { [weak self] in
            self?.recognitionWindow.show(image: preview, result: result)
        }
    }

    private func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func save(_ image: NSImage, watermark: AnnotationRenderer.WatermarkOptions?) {
        guard ScreenshotSaver.save(image, watermark: watermark) != nil else {
            let folder = (ScreenshotPreferences.folder.path as NSString).abbreviatingWithTildeInPath
            present(
                ScreenCaptureService.CaptureError.captureFailed(
                    "The screenshot could not be written to \(folder)."
                )
            )
            return
        }
    }

    /// Opens the pin over the area that was captured, at the picture's own size,
    /// so what was pinned stays where it was taken from. The pill's percentage
    /// and the wheel then move it away from that 100%.
    private func pin(_ image: NSImage, at region: CGRect) {
        let size = image.size
        let window = PinnedWindow(
            contentRect: NSRect(origin: region.origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.naturalSize = size

        let content = PinnedContentView(frame: NSRect(origin: .zero, size: size))
        content.imageView.image = image
        content.naturalWidth = size.width
        content.onClose = { [weak window] in window?.close() }
        window.contentView = content
        content.syncZoom()

        window.setFrameOrigin(region.origin)
        window.makeKeyAndOrderFront(nil)

        pinnedWindows.append(window)
    }

    private func present(_ error: Error, title: String = t("Screenshot")) {
        // A missing grant is answered by the checklist, which explains that
        // macOS applies the Screen Recording grant after a relaunch and offers
        // the relaunch; an alert would only repeat that badly.
        if case ScreenCaptureService.CaptureError.permission = error {
            onPermissionFailure?()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: t("OK"))
        alert.runModal()
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

/// Floating pill that counts down before a timed capture. It never takes key
/// focus or clicks, so whatever the user is setting up underneath keeps going.
@MainActor
final class CaptureCountdown {
    private let totalSeconds: Int
    private var panel: NSPanel?
    private var label: NSTextField?
    private var task: Task<Void, Never>?

    init(seconds: Int) {
        totalSeconds = seconds
    }

    func start(onFinish: @escaping () -> Void) {
        show()

        task = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: self.totalSeconds, through: 1, by: -1) {
                if Task.isCancelled {
                    self.close()
                    return
                }
                self.update(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled {
                self.close()
                return
            }
            self.close()
            onFinish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        close()
    }

    private func show() {
        let size = NSSize(width: 190, height: 54)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        content.layer?.cornerRadius = 14
        content.layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 12, y: (size.height - 22) / 2, width: size.width - 24, height: 22)
        content.addSubview(label)

        panel.contentView = content

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 56
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.label = label
    }

    private func update(_ seconds: Int) {
        label?.stringValue = tf("Screenshot in %d…", seconds)
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }
}

/// A pinned screenshot: the wheel zooms it about the pointer, ⌘-scroll changes
/// opacity, Esc or the pill closes it.
final class PinnedWindow: NSWindow {
    /// The picture's own size. Zoom is the frame's width over this, so 100% puts
    /// the pin back where it was captured.
    var naturalSize = NSSize(width: 1, height: 1)
    /// Beyond this the pin is either a speck or a wall.
    static let zoomRange: ClosedRange<CGFloat> = 0.1...4

    var zoom: CGFloat {
        naturalSize.width > 0 ? frame.width / naturalSize.width : 1
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contentView else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: t("Copy"), action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: t("50% Opacity"), action: #selector(toggleHalfOpacity), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: t("Close"), action: #selector(closeSelf), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    @objc private func closeSelf() {
        close()
    }

    @objc private func copyImage() {
        (contentView as? PinnedContentView)?.copyImage()
    }

    @objc private func toggleHalfOpacity() {
        alphaValue = alphaValue < 0.99 ? 1 : 0.5
    }

    /// Zooms to `zoom`, holding the screen point under `anchor` — the pointer for
    /// the wheel, the middle for the pill's menu — so the part being looked at
    /// stays put instead of the pin growing from a corner.
    func setZoom(_ zoom: CGFloat, around anchor: NSPoint? = nil) {
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        let size = NSSize(
            width: naturalSize.width * clamped,
            height: naturalSize.height * clamped
        )
        var frame = self.frame
        let point = anchor ?? NSPoint(x: frame.midX, y: frame.midY)
        let relative = NSPoint(
            x: frame.width > 0 ? (point.x - frame.minX) / frame.width : 0.5,
            y: frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5
        )
        frame = NSRect(
            x: point.x - size.width * relative.x,
            y: point.y - size.height * relative.y,
            width: size.width,
            height: size.height
        )
        setFrame(frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: size)
        (contentView as? PinnedContentView)?.syncZoom()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY

        if event.modifierFlags.contains(.command) {
            alphaValue = min(1, max(0.2, alphaValue - delta * 0.015))
            return
        }

        // A trackpad sends many small precise deltas, a wheel a few whole lines.
        let step = event.hasPreciseScrollingDeltas ? delta * 0.01 : delta * 0.1
        setZoom(zoom * exp(step), around: convertPoint(toScreen: event.locationInWindow))
    }

    /// Two fingers pinching do what the wheel does, so a trackpad user never has
    /// to find a scroll gesture for it.
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convertPoint(toScreen: event.locationInWindow))
    }
}

/// The picture, with a pill over its bottom edge: the zoom, copy and close. The
/// image itself is what most drags land on, so the pill only has to say what it
/// can be resized to and offers the two actions that do not have a key.
final class PinnedContentView: NSView {
    let imageView = PinnedImageView()
    let toolbar = PinnedToolbar()
    var onClose: (() -> Void)?
    /// The picture's width at its own size, for the zoom readout. Zero until
    /// the pin sets it.
    var naturalWidth: CGFloat = 0

    /// Set while the pointer is over the pin. The pill is only there then, so a
    /// pinned shot is just the shot until it is used.
    var isPointerInside = false {
        didSet {
            guard isPointerInside != oldValue else { return }
            updateToolbarVisibility()
        }
    }

    private var toolbarFits = true
    private var hoverTracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        toolbar.onCopy = { [weak self] in self?.copyImage() }
        toolbar.onClose = { [weak self] in self?.onClose?() }
        toolbar.onZoom = { [weak self] zoom in
            (self?.window as? PinnedWindow)?.setZoom(zoom)
        }
        addSubview(toolbar)
        updateToolbarVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedContentView is created in code only")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        let full = toolbar.contentSize
        let compact = bounds.width < full.width + inset * 2 || bounds.height < full.height + inset * 2
        toolbar.isCompact = compact
        let size = compact ? toolbar.compactSize : full
        toolbarFits = bounds.width >= size.width + inset * 2 && bounds.height >= size.height + inset * 2
        updateToolbarVisibility()
        guard toolbarFits else { return }
        toolbar.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: inset,
            width: size.width,
            height: size.height
        )
    }

    private func updateToolbarVisibility() {
        guard toolbarFits, isPointerInside else {
            toolbar.isHidden = true
            toolbar.alphaValue = 0
            return
        }
        toolbar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            toolbar.animator().alphaValue = 1
        }
    }

    /// Keeps the readout level with how far the pin has been stretched from
    /// the picture's own size.
    func syncZoom() {
        guard naturalWidth > 0 else { return }
        toolbar.zoom = bounds.width / naturalWidth
        needsLayout = true
    }

    func copyImage() {
        guard let image = imageView.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        toolbar.flashCopied()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }
}

/// The pin's own chrome. It is a view inside the pinned window rather than a
/// second floating panel: the picture already carries the drag and the scroll
/// zoom, and a panel would have to be kept in step with every resize.
final class PinnedToolbar: NSView {
    var zoom: CGFloat = 1 {
        didSet {
            zoomLabel.stringValue = Self.percent.string(from: NSNumber(value: zoom))
                ?? "\(Int((zoom * 100).rounded()))%"
        }
    }

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    /// The percentages the readout offers; the wheel fills in everything else.
    private static let zoomPresets = [25, 50, 100, 200, 400]

    private static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private let zoomLabel = NSTextField(labelWithString: "")
    private let zoomHitArea = PinnedZoomHitArea()
    private let divider = NSView()
    private let copyButton = PinnedToolbarButton(symbol: "doc.on.doc", label: t("Copy"))
    private let closeButton = PinnedToolbarButton(symbol: "xmark", label: t("Close"))
    private let background = NSVisualEffectView()
    private var copyFlash: DispatchWorkItem?

    private enum Metric {
        static let height: CGFloat = 30
        static let leading: CGFloat = 9
        static let trailing: CGFloat = 7
        static let spacing: CGFloat = 7
        static let divider = NSSize(width: 1, height: 14)
        static let button: CGFloat = 18
        static let buttonSpacing: CGFloat = 2
    }

    /// The pill at its content size. The pin places the pill with frames, so
    /// this view must not fix its own frame with constraints.
    var contentSize: NSSize {
        NSSize(
            width: Metric.leading + zoomWidth + Metric.spacing
                + Metric.divider.width + Metric.spacing
                + Metric.button + Metric.buttonSpacing + Metric.button + Metric.trailing,
            height: Metric.height
        )
    }

    /// The pill without the readout. A pin too narrow for the full pill keeps
    /// copy and close rather than losing its chrome to the edge.
    var compactSize: NSSize {
        NSSize(
            width: Metric.leading + Metric.button + Metric.buttonSpacing + Metric.button + Metric.trailing,
            height: Metric.height
        )
    }

    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            for view in [zoomLabel, zoomHitArea, divider] {
                view.isHidden = isCompact
            }
            needsLayout = true
        }
    }

    private var zoomWidth: CGFloat {
        zoomLabel.intrinsicContentSize.width.rounded(.up)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.maskImage = Self.pillMask(radius: 10)
        addSubview(background)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.setAccessibilityLabel(t("Zoom"))

        zoomHitArea.isBordered = false
        zoomHitArea.title = ""
        zoomHitArea.target = self
        zoomHitArea.action = #selector(zoomClicked)
        zoomHitArea.setAccessibilityLabel(t("Zoom"))
        zoomHitArea.onHover = { [weak self] inside in
            self?.zoomLabel.textColor = inside ? .labelColor : .secondaryLabelColor
        }

        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        for view in [zoomLabel, zoomHitArea, divider, copyButton, closeButton] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedToolbar is created in code only")
    }

    override func layout() {
        super.layout()
        background.frame = bounds

        var x = Metric.leading
        if !isCompact {
            let zoomHeight = zoomLabel.intrinsicContentSize.height.rounded(.up)
            zoomLabel.frame = NSRect(
                x: x,
                y: (bounds.height - zoomHeight) / 2,
                width: zoomWidth,
                height: zoomHeight
            )
            zoomHitArea.frame = zoomLabel.frame.insetBy(dx: -2, dy: -6)
            x = zoomLabel.frame.maxX + Metric.spacing

            divider.frame = NSRect(
                x: x,
                y: (bounds.height - Metric.divider.height) / 2,
                width: Metric.divider.width,
                height: Metric.divider.height
            )
            x = divider.frame.maxX + Metric.spacing
        }

        for button in [copyButton, closeButton] {
            button.frame = NSRect(
                x: x,
                y: (bounds.height - Metric.button) / 2,
                width: Metric.button,
                height: Metric.button
            )
            x = button.frame.maxX + Metric.buttonSpacing
        }
    }

    @objc private func copyTapped() {
        onCopy?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func zoomClicked() {
        let menu = NSMenu()
        let current = Int((zoom * 100).rounded())
        for preset in Self.zoomPresets {
            let title = Self.percent.string(from: NSNumber(value: Double(preset) / 100)) ?? "\(preset)"
            let item = NSMenuItem(title: title, action: #selector(zoomPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(preset) / 100)
            item.state = preset == current ? .on : .off
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: zoomHitArea)
    }

    @objc private func zoomPicked(_ sender: NSMenuItem) {
        guard let selected = sender.representedObject as? NSNumber else { return }
        onZoom?(CGFloat(selected.doubleValue))
    }

    /// A checkmark for a second says the copy landed without a sound.
    func flashCopied() {
        copyFlash?.cancel()
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: t("Copied"))
        copyButton.contentTintColor = .systemGreen
        let reset = DispatchWorkItem { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: t("Copy"))
            self?.copyButton.contentTintColor = .secondaryLabelColor
        }
        copyFlash = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reset)
    }

    /// An NSVisualEffectView draws its material outside a layer's corner
    /// radius, so the pill is rounded with a resizable mask instead.
    private static func pillMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// An invisible target over the zoom readout: a click opens the percentages, and
/// the readout brightens while the pointer is on it so it reads as a control.
final class PinnedZoomHitArea: NSButton {
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

/// A symbol button that brightens under the pointer, the way the editor's
/// toolbar entries do.
final class PinnedToolbarButton: NSButton {
    private var hoverTracking: NSTrackingArea?

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedToolbarButton is created in code only")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}

/// The image covers the whole pin, so the mouse-down lands here rather than on
/// the window's background. NSImageView refuses to hand that drag to the window
/// (`mouseDownCanMoveWindow` is false for controls), which left the pin stuck
/// where it opened; forwarding it restores dragging by the picture itself.
final class PinnedImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
}

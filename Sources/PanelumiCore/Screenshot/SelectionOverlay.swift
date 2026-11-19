import AppKit
import Combine
import SwiftUI
import PanelumiKit

/// In-place screenshot editing: the selection stays on screen,
/// everything outside it dims, and the toolbar appears right under the region.
/// The selected pixels freeze when editing starts; output reuses that image.
@MainActor
final class SelectionController {
    private var windows: [SelectionWindow] = []
    private var captureHandler: ((CapturePayload, CaptureSession.Output) -> Void)?
    private var cancelHandler: (() -> Void)?
    /// The takeover that currently controls the selection, if any.
    private var activeTakeover: TakeoverRun?
    /// True while an extension's `begin` is running; refuses nested takeovers.
    private var beginningTakeover = false
    /// The session's one local key monitor; the view it routes to decides.
    private var keyMonitor: Any?
    /// Watches for the keyboard leaving an overlay window, or coming back to
    /// the app, while a capture is live.
    private var focusObservers: [NSObjectProtocol] = []
    /// The overlay the user last clicked in. It owns the keyboard when no
    /// overlay window happens to be key.
    private weak var focusView: SelectionView?
    /// Watches for display reconfiguration only while a takeover is active.
    private var displayObserver: NSObjectProtocol?
    /// The host's live-capture handler, as handed to `begin`. Defaults to
    /// failing so a caller that does not offer live capture still compiles.
    private var captureLive: @MainActor (CGRect, NSScreen) async -> CGImage? = { _, _ in nil }

    let session = CaptureSession()
    private(set) var isActive = false

    /// Creates the controller; extensions are passed to the capture session
    /// with duplicates removed, keeping the first of each identifier.
    init(captureExtensions: [any CaptureExtension] = []) {
        var seen: Set<String> = []
        session.captureExtensions = captureExtensions.filter { seen.insert($0.identifier).inserted }
    }

    /// Exclude only capture overlays and the helper windows a takeover
    /// attached, not Settings or other app windows. Also excludes the visible
    /// message toasts a takeover showed, so a message never lands in a live
    /// capture. The colour-copy toast stays out: it was always part of the
    /// captured pixels.
    static var overlayWindowIDs: Set<CGWindowID> {
        var ids = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window.contentView is SelectionView, window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
        // Visible only: a window that is not on screen yet has a window number
        // the shared content cache does not know, which would make every frame
        // refetch that cache.
        for window in attachedWindows.allObjects + messageToasts.allObjects
        where window.isVisible && window.windowNumber > 0 {
            ids.insert(CGWindowID(window.windowNumber))
        }
        return ids
    }

    /// Every window an extension attached during any takeover. Weak, so it
    /// never keeps a window alive.
    private static let attachedWindows = NSHashTable<NSWindow>.weakObjects()

    /// The message toasts a takeover showed, and only those. Weak, so a toast
    /// that has gone never stays in the set. The colour-copy toast is
    /// deliberately absent because captures have always included it.
    private static let messageToasts = NSHashTable<NSWindow>.weakObjects()

    func begin(
        onCapture: @escaping (CapturePayload, CaptureSession.Output) -> Void,
        onCancel: @escaping () -> Void,
        captureBase: @escaping (CGRect, NSScreen) async -> CGImage?,
        captureWindows: @escaping ([CaptureWindowTarget], CGRect, NSScreen) async -> CGImage?,
        initialSelection: CGRect? = nil,
        frozen: @escaping (NSScreen) -> CGImage? = { _ in nil },
        finishOnSelect: CaptureSession.Output? = nil,
        captureLive: @escaping @MainActor (CGRect, NSScreen) async -> CGImage? = { _, _ in nil }
    ) {
        guard !isActive else { return }
        isActive = true
        captureHandler = onCapture
        cancelHandler = onCancel
        self.captureLive = captureLive
        session.annotations = []
        session.resetHistory()

        // Activate before any overlay exists. On macOS 14 activation is
        // cooperative: a window ordered front into an inactive app is not
        // guaranteed to become key, which left the overlay drawing its hints
        // while the keyboard stayed with Settings or the recognition panel.
        NSApplication.shared.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen)
            let view = SelectionView(
                screen: screen,
                session: session,
                captureWindows: captureWindows,
                captureBase: captureBase,
                frozenScreen: frozen(screen)
            )
            view.finishOnSelect = finishOnSelect
            view.onCapture = { [weak self] payload, output in
                self?.finish(payload, output)
            }
            view.onCancel = { [weak self] in
                self?.finish(nil, .copy)
            }
            view.onCaptureAction = { [weak self, weak view] extensionID, entryID, region in
                guard let self, let view else { return }
                self.beginTakeover(extensionID, entryID, region: region, view: view)
            }
            view.onTakeoverKey = { [weak self] key in
                self?.routeKey(key) ?? false
            }
            view.onInteract = { [weak self, weak view] in
                guard let self, let view else { return }
                self.focusView = view
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            view.prepareSample()

            if let initialSelection {
                let local = initialSelection.offsetBy(
                    dx: -screen.frame.minX,
                    dy: -screen.frame.minY
                )
                if local.intersects(NSRect(origin: .zero, size: screen.frame.size)) {
                    view.presetSelection(local)
                }
            }
        }

        installKeyMonitor()
        observeFocusLoss()
        claimFocus()
        // Activation lands on a later run-loop turn; claim again once it has.
        DispatchQueue.main.async { [weak self] in self?.claimFocus() }
    }

    // MARK: - Focus

    private var focusPolicy: CaptureFocusPolicy {
        CaptureFocusPolicy(
            sessionActive: isActive,
            appActive: NSApp.isActive,
            takeoverActive: activeTakeover != nil
        )
    }

    /// The overlay that should hold the keyboard when no overlay window is key:
    /// the one the user last clicked in, else the one being edited, else the
    /// one on the display under the pointer.
    private var focusTarget: SelectionView? {
        let views = windows.compactMap { $0.contentView as? SelectionView }
        if let focusView, views.contains(where: { $0 === focusView }) {
            return focusView
        }
        if let editing = views.first(where: { $0.isEditing }) {
            return editing
        }
        let pointer = NSEvent.mouseLocation
        return views.first { $0.screen.frame.contains(pointer) } ?? views.first
    }

    /// Puts the keyboard back on the overlay after AppKit gave it to another
    /// window. Runs after activation, whenever an overlay window resigns key,
    /// and when Panelumi becomes active again.
    private func claimFocus() {
        guard focusPolicy.claimsKeyboard, let target = focusTarget else { return }
        guard target.window?.isKeyWindow != true else { return }
        target.window?.makeKey()
        // An annotation's text editor keeps the first responder: it is what
        // was waiting for those keys.
        if let window = target.window,
           window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(target)
        }
    }

    private func reclaimFocus() {
        // After the transaction that took the keyboard away has finished;
        // re-keying from inside it is ignored.
        DispatchQueue.main.async { [weak self] in self?.claimFocus() }
    }

    private func observeFocusLoss() {
        let center = NotificationCenter.default
        for window in windows {
            focusObservers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimFocus() }
            })
        }
        focusObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaimFocus() }
        })
    }

    /// The session's one local monitor. It sees a key before the window AppKit
    /// delivered it to, so an overlay that never became key still answers its
    /// own shortcuts instead of sitting there inert.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let view = self.keyTarget() else { return event }
            return view.handleKeyEvent(event)
        }
    }

    /// The view a key event belongs to, or nil to let AppKit deliver it.
    func keyTarget() -> SelectionView? {
        let keyWindow = NSApp.keyWindow
        let overlayIsKey = keyWindow.map { key in windows.contains { $0 === key } } ?? false
        guard focusPolicy.ownsKeyEvent(overlayIsKey: overlayIsKey) else { return nil }
        if overlayIsKey, let view = keyWindow?.contentView as? SelectionView { return view }
        return focusTarget
    }

    private func stopFocusTracking() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        focusObservers.removeAll()
    }

    /// Closes a live overlay without producing output. Used when the grant the
    /// capture needs is gone: the checklist replaces the overlay instead of
    /// being drawn behind it.
    func abort() {
        finish(nil, outputs: [])
    }

    /// Debug helper: completes the current selection as if Enter was pressed.
    func completeForDebug(_ output: CaptureSession.Output, extraAnnotations: [Annotation] = []) {
        for window in windows {
            guard let view = window.contentView as? SelectionView, view.hasSelectionForDebug else { continue }
            view.session.annotations.append(contentsOf: extraAnnotations)
            view.finishForDebug(output)
            return
        }
    }

    /// Starts a takeover for an extension entry. Declines when the overlay is
    /// not live, another takeover is already running, or no extension has that
    /// identifier.
    ///
    /// A `cancel()` or `deliver` made inside `begin` is applied right after
    /// this method installs the takeover; the first deliver wins, and a cancel
    /// wins over deliver. Both are dropped when `begin` returns nil.
    func beginTakeover(
        _ extensionID: String,
        _ entryID: String,
        region: CGRect,
        view: SelectionView
    ) {
        guard isActive, activeTakeover == nil, !beginningTakeover else { return }
        guard let extensionUnderTest = session.captureExtensions
            .first(where: { $0.identifier == extensionID })
        else { return }

        // The context's closures need the run that owns it. The box is created
        // first and holds the run weakly, so the run and its context never form
        // a retain cycle.
        let box = TakeoverRunBox()
        let run = TakeoverRun(
            view: view,
            region: region,
            screen: view.screen,
            cancel: { [box, weak self] in
                guard let run = box.run else { return }
                if run.beginning {
                    run.pendingCancel = true
                    return
                }
                self?.endTakeover(.cancelled) { self?.finish(nil, .copy) }
            },
            deliver: { [box, weak self] image, outputs in
                guard let run = box.run else { return }
                if run.beginning {
                    // Two delivers inside `begin`: the first one wins.
                    if run.pendingDeliver == nil {
                        run.pendingDeliver = (image, outputs)
                    }
                    return
                }
                self?.endTakeover(.delivered) {
                    self?.deliverExternal(run, image, outputs)
                }
            },
            message: { [box] text in
                guard let run = box.run else { return }
                let toast = ColorToast.show(
                    text,
                    level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1),
                    screen: run.context.screen
                )
                Self.messageToasts.add(toast)
            },
            attach: { [box, weak self] window in
                guard let self, let run = box.run, run.endedReason == nil, self.isActive else { return }
                window.isReleasedWhenClosed = false
                // Raise only a window that is at or below the overlay's level;
                // never lower one the extension already placed higher.
                let overlayLevel = NSWindow.Level.screenSaver
                if window.level.rawValue <= overlayLevel.rawValue {
                    window.level = NSWindow.Level(rawValue: overlayLevel.rawValue + 1)
                }
                run.attached.append(window)
                Self.attachedWindows.add(window)
            },
            live: { [box, weak self] in
                guard let self, let run = box.run else { return nil }
                return await self.captureLive(run.context.region, run.context.screen)
            }
        )
        box.run = run

        beginningTakeover = true
        defer { beginningTakeover = false }
        let takingOver = extensionUnderTest.begin(entryID, context: run.context)

        guard let takeover = takingOver else {
            run.context.invalidate()
            closeAttached(run)
            return
        }
        // `begin` may have closed the overlay (for example through the view's
        // cancel closure). This view is gone, so install nothing and tell the
        // takeover it was dismissed, once.
        guard isActive else {
            run.beginning = false
            run.context.invalidate()
            closeAttached(run)
            takeover.takeoverDidEnd(reason: .dismissed)
            return
        }

        run.takeover = takeover
        run.beginning = false
        activeTakeover = run
        session.takeoverActive = true
        view.isTakeoverOwner = true
        for window in windows {
            window.ignoresMouseEvents = true
            guard let overlay = window.contentView as? SelectionView else { continue }
            overlay.refreshToolbarLayout()
            overlay.needsDisplay = true
        }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endTakeover(.dismissed) { self?.finish(nil, .copy) }
            }
        }

        if run.pendingCancel {
            endTakeover(.cancelled) { self.finish(nil, .copy) }
        } else if let pending = run.pendingDeliver {
            run.pendingDeliver = nil
            endTakeover(.delivered) {
                self.deliverExternal(run, pending.image, pending.outputs)
            }
        }
    }

    /// Ends the active takeover: restores the overlay first, then tells the
    /// extension exactly once. Does nothing when no takeover is running.
    func endTakeover(_ reason: CaptureEndReason, then: (() -> Void)? = nil) {
        guard let run = activeTakeover, run.endedReason == nil else { return }
        run.endedReason = reason
        activeTakeover = nil
        run.context.invalidate()

        session.takeoverActive = false
        run.view?.isTakeoverOwner = false
        for window in windows {
            window.ignoresMouseEvents = false
            guard let overlay = window.contentView as? SelectionView else { continue }
            overlay.refreshToolbarLayout()
            overlay.needsDisplay = true
        }
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
        closeAttached(run)

        then?()
        run.takeover?.takeoverDidEnd(reason: reason)
        reclaimFocus()
    }

    /// Closes every window an extension attached during `run`, used by every
    /// exit path. The shared table and the run hold nothing afterwards.
    private func closeAttached(_ run: TakeoverRun) {
        for window in run.attached {
            window.orderOut(nil)
            window.close()
            Self.attachedWindows.remove(window)
        }
        run.attached.removeAll()
    }

    /// Sends a key to the active takeover. An Escape the takeover does not
    /// consume ends it, so the user can never be stuck.
    func routeKey(_ key: CaptureKey) -> Bool {
        guard let run = activeTakeover, run.endedReason == nil else { return false }
        let handled = run.takeover?.handleKey(key) ?? false
        // `handleKey` may have ended the takeover from inside (for example by
        // calling `cancel()`). The key must never reach the closed view.
        if activeTakeover !== run { return true }
        if !handled, key.isEscape {
            endTakeover(.dismissed) { self.finish(nil, .copy) }
            return true
        }
        return handled
    }

    /// Hands an image an extension delivered to the same end path the overlay's
    /// own `deliver(_:)` uses. The payload is built here from the run's region,
    /// its screen and the shared session, so watermark settings and the pixel
    /// size behave as they do for a normal capture.
    private func deliverExternal(
        _ run: TakeoverRun,
        _ image: CGImage,
        _ outputs: Set<CaptureOutput>
    ) {
        let payload = CapturePayload(
            rect: run.context.region,
            screen: run.context.screen,
            annotations: [],
            base: image,
            watermark: session.watermarkOptions,
            watermarkVisible: !session.watermarkHidden
        )
        run.view?.prepareForExternalDelivery()
        finish(payload, outputs: Self.sortedOutputs(outputs))
    }

    /// The pipeline order: copy, save, pin. Every output the extension asked
    /// for appears once.
    private static func sortedOutputs(_ outputs: Set<CaptureOutput>) -> [CaptureSession.Output] {
        [CaptureOutput.copy, .save, .pin]
            .filter(outputs.contains)
            .map(\.sessionOutput)
    }

    private func finish(_ payload: CapturePayload?, _ output: CaptureSession.Output) {
        finish(payload, outputs: [output])
    }

    private func finish(_ payload: CapturePayload?, outputs: [CaptureSession.Output]) {
        guard isActive else { return }
        endTakeover(.dismissed)
        isActive = false
        stopFocusTracking()
        focusView = nil

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        if let payload {
            for output in outputs {
                captureHandler?(payload, output)
            }
        } else {
            cancelHandler?()
        }
        captureHandler = nil
        cancelHandler = nil
    }
}

private final class SelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Interaction {
        case none
        case creating(start: CGPoint)
        case moving(start: CGPoint, rect: CGRect)
        case resizing(handle: Handle, rect: CGRect)
        case drawing
        /// `start` is a view-space point.
        case movingAnnotation(start: CGPoint, index: Int, original: Annotation)
        case resizingAnnotation(handle: Handle, index: Int, original: Annotation, rect: CGRect)

        var isIdle: Bool {
            if case .none = self { return true }
            return false
        }
    }

    enum HistoryCommand: Equatable {
        case undo
        case redo
    }

    let screen: NSScreen
    let session: CaptureSession
    private let captureWindows: ([CaptureWindowTarget], CGRect, NSScreen) async -> CGImage?
    private let captureBase: (CGRect, NSScreen) async -> CGImage?
    /// A frame taken before the overlay appeared, shown in place of the live
    /// desktop so a menu or tooltip opened during the countdown survives.
    private let frozenScreen: CGImage?

    var onCapture: ((CapturePayload, CaptureSession.Output) -> Void)?
    var onCancel: (() -> Void)?
    /// Called when the user picks an extension's toolbar entry, with the
    /// extension identifier, the entry id and the region in global screen
    /// coordinates.
    var onCaptureAction: ((String, String, CGRect) -> Void)?
    /// Routes a key press to the controller while a takeover is active.
    var onTakeoverKey: ((CaptureKey) -> Bool)?
    /// Tells the controller the user worked with this overlay, so it can be
    /// the keyboard's fallback owner if no overlay window is key.
    var onInteract: (() -> Void)?
    /// True on the view that started the takeover; only it draws the border.
    var isTakeoverOwner = false
    /// Set for captures that skip the editor (text recognition): choosing a
    /// region or a window delivers it straight away with this output.
    var finishOnSelect: CaptureSession.Output?

    private(set) var selection: CGRect?
    private var interaction: Interaction = .none
    /// True once the overlay has a region to act on; used to pick the window
    /// that should hold the keyboard.
    var isEditing: Bool { editing }
    private(set) var hovered: (id: CGWindowID, rect: CGRect)?
    /// Windows picked with ⇧-click: composited together when editing starts.
    private var windowTargets: [CaptureWindowTarget] = []
    private var editing = false
    private var baseImage: CGImage?
    private var baseTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var isFinishing = false
    private var windowCaptureFailed = false
    private var sampleImage: CGImage?
    private(set) var hoverColor: NSColor?
    private var optionHeld = false
    private var colorFormat: ScreenshotPreferences.ColorFormat = ScreenshotPreferences.colorFormat
    private var lastMousePoint: CGPoint = .zero

    private var startPoint: CGPoint?
    private var draft: Annotation?
    private var penPoints: [CGPoint] = []

    private(set) var toolbarHost: CaptureToolbarHost?
    let popoverPlacement = ToolbarPopoverPlacement()
    private var textField: NSTextField?
    /// Where the user clicked to start the text; the anchor is fitted to it.
    private var textClickPoint: CGPoint = .zero
    private var textAnchor: CGPoint = .zero
    private var sessionCancellable: AnyCancellable?

    init(
        screen: NSScreen,
        session: CaptureSession,
        captureWindows: @escaping ([CaptureWindowTarget], CGRect, NSScreen) async -> CGImage? = { _, _, _ in nil },
        captureBase: @escaping (CGRect, NSScreen) async -> CGImage?,
        frozenScreen: CGImage? = nil
    ) {
        self.screen = screen
        self.session = session
        self.captureWindows = captureWindows
        self.captureBase = captureBase
        self.frozenScreen = frozenScreen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("SelectionView is created in code only")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The overlay is nonopaque. Clear the previous editor bitmap first.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        // A takeover shows only the dimming and the selection border. Every
        // view takes this branch: another display keeps a plain dim without a
        // cut-out, and only the owner outlines the selection.
        if session.takeoverActive {
            let path = NSBezierPath(rect: bounds)
            if isTakeoverOwner, let selection {
                path.append(NSBezierPath(rect: selection))
                path.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(0.5).setFill()
            path.fill()
            if isTakeoverOwner, let selection {
                let stroke = NSBezierPath(rect: selection)
                stroke.lineWidth = 1
                NSColor.white.withAlphaComponent(0.9).setStroke()
                stroke.stroke()
            }
            return
        }

        // A capture paints the frame taken before the overlay opened, so menus
        // and tooltips stay on screen while the region is chosen.
        if let frozenScreen {
            NSImage(cgImage: frozenScreen, size: bounds.size).draw(in: bounds)
        }

        // Everything outside the region (or the window a click would
        // capture) dims; the region itself keeps full brightness.
        let path = NSBezierPath(rect: bounds)
        if let selection, selection.width > 1, selection.height > 1 {
            path.append(NSBezierPath(rect: selection))
            path.windingRule = .evenOdd
        } else if selection == nil, !editing, let hovered {
            path.append(NSBezierPath(rect: hovered.rect))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(editing ? 0.5 : 0.45).setFill()
        path.fill()

        if !editing {
            drawWindowHighlight()
        }

        guard let selection else {
            drawHint(t("Drag to select · click a window · ⇧ click adds one · F full screen · R last region"))
            drawColorReadout()
            drawColorHint()
            return
        }

        if editing {
            let resizing: Bool = {
                if case .resizing = interaction { return true }
                return false
            }()

            if !resizing {
                if let baseImage {
                    NSImage(cgImage: baseImage, size: selection.size).draw(in: selection)
                }
                drawAnnotations(in: selection)
                if let options = session.watermarkOptions, !session.watermarkHidden {
                    AnnotationRenderer.drawWatermark(options, in: selection)
                }
                drawAnnotationSelection(in: selection)
                drawTextBubble(in: selection)
            }

            if windowTargets.isEmpty { drawHandles(for: selection) }
            let stroke = NSBezierPath(rect: selection)
            stroke.lineWidth = 1
            NSColor.white.withAlphaComponent(0.9).setStroke()
            stroke.stroke()
            if windowCaptureFailed {
                drawHint(t("The selected window could not be captured. Press Esc to try again."))
            }
        } else {
            let stroke = NSBezierPath(rect: selection)
            stroke.lineWidth = 1
            NSColor.white.withAlphaComponent(0.9).setStroke()
            stroke.stroke()

            for target in windowTargets {
                let outline = NSBezierPath(rect: target.rect)
                outline.lineWidth = 1.5
                outline.setLineDash([5, 3], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                outline.stroke()
            }

            if windowTargets.isEmpty { drawHandles(for: selection) }
            drawLabel(sizeText(for: selection), above: selection)

            if windowTargets.isEmpty {
                drawHint(t("Enter or drag to edit · R reuses the last region · Esc cancels"))
            } else {
                drawHint(tf("%d windows · Return to edit · Esc clears", windowTargets.count))
            }
        }

        if !editing {
            drawColorReadout()
            drawColorHint()
        }
    }

    /// Outline over the window a click would capture. With no selection the
    /// window is already cut out of the dimming, so a solid line suffices;
    /// while adding windows to a selection it stays dashed.
    private func drawWindowHighlight() {
        guard let hovered, selection == nil || !windowTargets.isEmpty else { return }
        let path = NSBezierPath(rect: hovered.rect)
        path.lineWidth = 1
        if selection != nil {
            path.setLineDash([5, 3], count: 2, phase: 0)
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawAnnotations(in rect: CGRect) {
        for annotation in session.annotations {
            AnnotationRenderer.draw(annotation, in: rect, base: baseImage)
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: rect, base: baseImage)
        }
    }

    private func drawAnnotationSelection(in selection: CGRect) {
        guard session.tool == .select,
              let index = session.selectionIndex,
              session.annotations.indices.contains(index)
        else { return }

        let rect = annotationFrame(index, in: selection)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        guard hasResizeHandles(session.annotations[index].shape) else { return }

        for box in handleRects(for: rect).values {
            NSColor.white.setFill()
            NSColor.controlAccentColor.setStroke()
            let handle = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            handle.lineWidth = 1.5
            handle.fill()
            handle.stroke()
        }
    }

    /// Text and numbered markers are sized by what they draw, not dragged.
    private func hasResizeHandles(_ shape: Annotation.Shape) -> Bool {
        switch shape {
        case .text, .number: return false
        default: return true
        }
    }

    private func drawHandles(for rect: CGRect) {
        NSColor.white.setFill()
        NSColor.black.withAlphaComponent(0.35).setStroke()

        for handleRect in handleRects(for: rect).values {
            let path = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            path.lineWidth = 1.5
            path.fill()
            path.stroke()
        }
    }

    private func drawLabel(_ text: String, above rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = NSSize(width: 7, height: 3)

        var origin = NSPoint(x: rect.minX, y: rect.maxY + 8)
        if origin.y + size.height + padding.height * 2 > bounds.maxY {
            origin.y = rect.minY - size.height - padding.height * 2 - 8
        }
        if origin.y < bounds.minY {
            origin.y = rect.minY + 8
        }

        let background = NSRect(
            x: origin.x,
            y: origin.y,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        string.draw(at: NSPoint(x: origin.x + padding.width, y: origin.y + padding.height))
    }

    private func drawHint(_ text: String) {
        let string = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
        )
        let size = string.size()
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 42)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: origin.x - 14,
                y: origin.y - 8,
                width: size.width + 28,
                height: size.height + 16
            ),
            xRadius: 8,
            yRadius: 8
        ).fill()
        string.draw(at: origin)
    }

    private func drawColorHint() {
        let string = NSAttributedString(
            string: t("C Copy colour · ⌥ HEX / RGB / HSL"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ]
        )
        let size = string.size()
        let box = NSRect(x: 12, y: 12, width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5))
    }

    private func drawColorReadout() {
        guard let hoverColor else { return }

        let value = NSAttributedString(
            string: colorText(hoverColor),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        )
        let scale = screen.backingScaleFactor
        let coords = String(
            format: "%d, %d",
            Int((lastMousePoint.x * scale).rounded()),
            Int(((screen.frame.height - lastMousePoint.y) * scale).rounded())
        )
        let coordinateText = NSAttributedString(
            string: coords,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            ]
        )

        let size = value.size()
        let boxSize = NSSize(width: size.width + 36, height: 36)

        var origin = NSPoint(
            x: lastMousePoint.x + 16,
            y: lastMousePoint.y - boxSize.height - 10
        )
        origin.x = min(max(4, origin.x), bounds.width - boxSize.width - 4)
        origin.y = min(max(4, origin.y), bounds.height - boxSize.height - 4)

        let box = NSRect(origin: origin, size: boxSize)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()

        let swatch = NSRect(x: box.minX + 7, y: box.midY - 5, width: 10, height: 10)
        hoverColor.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2)
        border.lineWidth = 1
        border.stroke()

        value.draw(at: NSPoint(x: box.minX + 23, y: box.maxY - size.height - 6))
        coordinateText.draw(at: NSPoint(x: box.minX + 23, y: box.minY + 5))
    }

    private func colorText(_ color: NSColor) -> String {
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())

        switch colorFormat {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return "R \(r) G \(g) B \(b)"
        case .hsl:
            let hsl = hslComponents(color)
            return "H \(hsl.h) S \(hsl.s) L \(hsl.l)"
        }
    }

    private func hslComponents(_ color: NSColor) -> (h: Int, s: Int, l: Int) {
        let r = color.redComponent
        let g = color.greenComponent
        let b = color.blueComponent
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let l = (maxValue + minValue) / 2
        var h: CGFloat = 0
        var s: CGFloat = 0

        if maxValue != minValue {
            let d = maxValue - minValue
            s = l > 0.5 ? d / (2 - maxValue - minValue) : d / (maxValue + minValue)
            switch maxValue {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }

        return (
            Int((h * 360).rounded()),
            Int((s * 100).rounded()),
            Int((l * 100).rounded())
        )
    }

    func prepareSample() {
        guard sampleImage == nil else { return }
        let frame = screen.frame
        Task { [weak self] in
            guard let self, let image = await self.pixels(in: frame) else { return }
            self.sampleImage = image
            self.updateHoverColor(at: self.lastMousePoint)
            self.needsDisplay = true
        }
    }

    /// A region comes out of the frame taken before the overlay opened; a live
    /// capture goes back to ScreenCaptureKit.
    private func pixels(in global: CGRect) async -> CGImage? {
        if let frozenScreen,
           let cropped = ScreenCaptureService.crop(image: frozenScreen, to: global, screenFrame: screen.frame) {
            return cropped
        }
        return await captureBase(global, screen)
    }

    override func flagsChanged(with event: NSEvent) {
        if session.takeoverActive { return }
        let optionNow = event.modifierFlags.contains(.option)
        if optionNow, !optionHeld {
            colorFormat = colorFormat.next
            ScreenshotPreferences.setColorFormat(colorFormat)
            needsDisplay = true
        }
        optionHeld = optionNow
    }

    private func updateHoverColor(at point: CGPoint) {
        guard let sampleImage else {
            hoverColor = nil
            return
        }
        if isPointOnToolbar(point) {
            hoverColor = nil
            return
        }
        if editing {
            hoverColor = nil
            return
        }

        guard sampleImage.width > 0, sampleImage.height > 0 else { return }
        let scaleX = CGFloat(sampleImage.width) / max(1, screen.frame.width)
        let scaleY = CGFloat(sampleImage.height) / max(1, screen.frame.height)
        let column = min(sampleImage.width - 1, max(0, Int(point.x * scaleX)))
        let row = min(sampleImage.height - 1, max(0, Int((screen.frame.height - point.y) * scaleY)))

        guard let color = Self.srgbPixel(of: sampleImage, column: column, row: row) else { return }
        hoverColor = color
    }

    /// The hint band above the pill is decoration: pointing or clicking there
    /// belongs to the selection, not the toolbar.
    private func isPointOnToolbar(_ point: CGPoint) -> Bool {
        guard let toolbarHost, toolbarHost.frame.contains(point) else { return false }
        return !toolbarHost.isInHintBand(point)
    }

    private func sizeText(for rect: CGRect) -> String {
        let scale = screen.backingScaleFactor
        return "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
    }

    // MARK: - Editing lifecycle

    var hasSelectionForDebug: Bool { selection != nil }

    var hasBaseImageForDebug: Bool { baseImage != nil }

    var pendingTextFieldForDebug: NSTextField? { textField }

    func annotationFrameForDebug(_ index: Int) -> CGRect? {
        guard let selection, session.annotations.indices.contains(index) else { return nil }
        return annotationFrame(index, in: selection)
    }

    func finishForDebug(_ output: CaptureSession.Output) {
        finish(output)
    }

    func presetSelection(_ rect: CGRect) {
        windowTargets = []
        selection = clamp(rect)
        startEditing()
    }

    private func startEditing() {
        guard selection != nil, !editing else { return }
        editing = true

        if let finishOnSelect {
            // Capture while the overlay is still up: its windows are then
            // excluded by ID. Capturing after it closes races the window
            // server and can bake the selection outline into the image.
            loadBase()
            finish(finishOnSelect)
            return
        }
        session.annotations = []
        session.extensionToolbarItems = CaptureSession.toolbarEntries(for: session.captureExtensions)
        session.captureActionsAllowed = windowTargets.isEmpty
        session.onUndo = { [weak self] in self?.performHistory(.undo) }
        session.onRedo = { [weak self] in self?.performHistory(.redo) }
        session.onCopy = { [weak self] in self?.finish(.copy) }
        session.onSave = { [weak self] in self?.finish(.save) }
        session.onPin = { [weak self] in self?.finish(.pin) }
        session.onClose = { [weak self] in self?.onCancel?() }

        installToolbar()
        sessionCancellable = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.layoutToolbar()
                self?.updateTextField()
                self?.needsDisplay = true
            }
        }
        loadBase()
        needsDisplay = true
    }

    /// Freeze the selected pixels so mosaic and blur can be shown for real.
    /// A window selection is composited from per-window captures instead of
    /// being cut out of the display, so occluding windows and shadows differ.
    private func loadBase() {
        guard let selection else { return }
        let global = selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let targets = windowTargets
        baseTask?.cancel()
        windowCaptureFailed = false
        baseTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let image: CGImage?
            if targets.isEmpty {
                image = await self.pixels(in: global)
            } else {
                // Never substitute pixels from a different window or the
                // desktop when an explicitly selected window disappears.
                image = await self.captureWindows(targets, selection, self.screen)
            }
            guard !Task.isCancelled else { return }
            self.baseImage = image
            self.windowCaptureFailed = !targets.isEmpty && image == nil
            self.needsDisplay = true
        }
    }

    /// Samples the frozen base image, which is only the selected region and
    /// carries no annotations or toolbar. The view point is brought into the
    /// selection, then scaled to the image's own pixel grid: a Retina capture
    /// has twice the pixels of the rect it is drawn in.
    private func pickColor(at point: CGPoint) {
        guard let selection, let baseImage, baseImage.width > 0, baseImage.height > 0 else { return }
        let scaleX = CGFloat(baseImage.width) / max(1, selection.width)
        let scaleY = CGFloat(baseImage.height) / max(1, selection.height)
        let column = min(baseImage.width - 1, max(0, Int((point.x - selection.minX) * scaleX)))
        let row = min(baseImage.height - 1, max(0, Int((selection.maxY - point.y) * scaleY)))

        guard let pixel = Self.srgbPixel(of: baseImage, column: column, row: row) else { return }
        let color = Color(nsColor: pixel)
        session.activeStyle.color = color
        if let hex = AnnotationPalette.hex(for: color) {
            session.rememberRecentColor(hex)
        }
    }

    /// One pixel of `image` in sRGB; `row` counts from the top. The pixel is
    /// cropped out and drawn into a 1×1 sRGB context instead of read through
    /// `NSBitmapImageRep.colorAt`, whose calibrated colour space shifts the
    /// components it reports (a pure sRGB red came back with green 38).
    static func srgbPixel(of image: CGImage, column: Int, row: Int) -> NSColor? {
        guard let single = image.cropping(to: CGRect(x: column, y: row, width: 1, height: 1)),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        func unit(_ value: UInt8) -> CGFloat { CGFloat(Double(value) / 255) }
        return NSColor(srgbRed: unit(bytes[0]), green: unit(bytes[1]), blue: unit(bytes[2]), alpha: 1)
    }

    /// Shared by the local key monitor and the tests. Returns nil when the event was consumed,
    /// or the event itself when it should continue down the responder chain.
    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Esc abandons a half-typed text annotation before anything else,
        // unless the input method is composing.
        if textField != nil, event.keyCode == 53 {
            return handleTextFieldEscape() ? nil : event
        }
        if window?.firstResponder is NSTextView { return event }

        if session.takeoverActive {
            return routeTakeoverKey(event) ? nil : event
        }

        // Colour picking only exists while framing the region.
        if event.keyCode == 8, !editing {
            if let hoverColor = hoverColor {
                let text = colorText(hoverColor)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ColorToast.show(tf("Copied %@", text))
                onCancel?()
                return nil
            }
            return event
        }

        guard editing else { return event }

        if let command = Self.historyCommand(for: event) {
            performHistory(command)
            return nil
        }

        if applyEditingShortcut(event) { return nil }

        if event.keyCode == 53, dismissEscapeLayer() { return nil }

        switch event.keyCode {
        case 53: // Esc
            onCancel?()
            return nil
        case 36, 76: // Return
            finish(.copy)
            return nil
        case 49: // Space
            finish(.save)
            return nil
        case 35: // P
            finish(.pin)
            return nil
        case 51, 117: // Delete
            if session.tool == .select,
               let index = session.selectionIndex,
               session.annotations.indices.contains(index) {
                session.recordUndoSnapshot()
                session.annotations.remove(at: index)
                session.selectionIndex = nil
                needsDisplay = true
                return nil
            }
            return event
        default:
            return event
        }
    }

    /// Hands a key press to the controller while a takeover is active. True
    /// means the takeover consumed it.
    private func routeTakeoverKey(_ event: NSEvent) -> Bool {
        let key = CaptureKey(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            isRepeat: event.isARepeat
        )
        return onTakeoverKey?(key) ?? false
    }

    private func teardown() {
        baseTask?.cancel()
        outputTask?.cancel()
        outputTask = nil
        sessionCancellable?.cancel()
        sessionCancellable = nil
        removeToolbar()
        removeTextField(refocus: false)
        window?.ignoresMouseEvents = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            teardown()
        }
    }

    private func finish(_ output: CaptureSession.Output) {
        guard !isFinishing else { return }
        commitTextFieldIfNeeded(droppingComposition: true)
        if !windowTargets.isEmpty || finishOnSelect != nil, let baseTask {
            isFinishing = true
            outputTask = Task { [weak self] in
                await baseTask.value
                guard !Task.isCancelled, let self else { return }
                self.outputTask = nil
                self.isFinishing = false
                self.deliver(output)
            }
        } else {
            deliver(output)
        }
    }

    /// Removes this view from the input path before the controller hands an
    /// extension's image to the output pipeline. Does what `deliver(_:)` does
    /// before it calls `onCapture`.
    func prepareForExternalDelivery() {
        teardown()
    }

    private func deliver(_ output: CaptureSession.Output) {
        guard let selection else { return }
        guard windowTargets.isEmpty || baseImage != nil else {
            windowCaptureFailed = true
            needsDisplay = true
            return
        }
        let global = selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let payload = CapturePayload(
            rect: global,
            screen: screen,
            annotations: session.annotations,
            base: baseImage,
            watermark: session.watermarkOptions,
            watermarkVisible: !session.watermarkHidden
        )
        teardown()
        onCapture?(payload, output)
    }

    private func installToolbar() {
        guard toolbarHost == nil else { return }
        let host = CaptureToolbarHost(rootView: CaptureToolbarView(
            session: session,
            popoverPlacement: popoverPlacement,
            onCaptureAction: { [weak self] extensionID, entryID in
                self?.requestCaptureAction(extensionID, entryID)
            }
        ))
        host.frame.size = host.fittingSize
        addSubview(host)
        toolbarHost = host

        layoutToolbar()
    }

    /// A toolbar entry picked by the user. Only a picked region can start an
    /// action: window composites have no region of their own, and annotations
    /// keep the toolbar inactive. The region is converted to global screen
    /// coordinates because the handler sits above the per-screen overlay.
    func requestCaptureAction(_ extensionID: String, _ entryID: String) {
        guard editing, !isFinishing, !session.takeoverActive else { return }
        guard session.annotations.isEmpty else { return }
        guard let selection, selection.width >= 4, selection.height >= 4 else { return }
        guard windowTargets.isEmpty else { return }
        commitTextFieldIfNeeded()
        guard session.annotations.isEmpty else { return }
        let previousTool = session.tool
        session.tool = .select
        cancelCanvasInteractionForHistory()
        interaction = .none
        draft = nil
        onCaptureAction?(
            extensionID,
            entryID,
            selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        )
        // An extension that declines (or ends at once) leaves the selection as the
        // user had it, so the tool they picked comes back.
        if editing, !isFinishing, !session.takeoverActive {
            session.tool = previousTool
        }
    }

    private func layoutToolbar() {
        guard let toolbarHost, let selection else { return }
        toolbarHost.layoutSubtreeIfNeeded()
        let size = toolbarHost.fittingSize
        let reserve = session.showsOptionsRow ? 0 : CaptureToolbarView.optionsRowReserve
        let origin = Self.toolbarOrigin(selection: selection, size: size, bounds: bounds, reserve: reserve)
        toolbarHost.frame = NSRect(origin: origin, size: size)
        toolbarHost.isHidden = !session.toolbarVisible || session.takeoverActive
        let edge = Self.popoverEdge(toolbar: toolbarHost.frame, selection: selection, bounds: bounds)
        if popoverPlacement.edge != edge {
            popoverPlacement.edge = edge
        }
    }

    /// Away from the selection when the toolbar sits outside it. Inside it
    /// (a selection that leaves no room around it) covering is unavoidable,
    /// so the popover takes the side with more screen.
    static func popoverEdge(toolbar: CGRect, selection: CGRect, bounds: CGRect) -> Edge {
        if toolbar.maxY <= selection.minY { return .bottom }
        if toolbar.minY >= selection.maxY { return .top }
        return toolbar.minY - bounds.minY >= bounds.maxY - toolbar.maxY ? .bottom : .top
    }

    /// Re-lays out the toolbar now. The controller calls this when a takeover
    /// starts or ends, so the toolbar hides immediately instead of waiting for
    /// the session's asynchronous change sink.
    func refreshToolbarLayout() {
        layoutToolbar()
    }

    /// Below the selection when it fits, else above it, else along the
    /// selection's bottom edge on the inside: a selection that leaves no room
    /// on either side is mostly the screen, and its bottom strip is the least
    /// costly part to cover.
    static func toolbarOrigin(
        selection: CGRect,
        size: CGSize,
        bounds: CGRect,
        reserve: CGFloat = 0
    ) -> CGPoint {
        let gap: CGFloat = 10
        let margin: CGFloat = 8

        let x = max(margin, min(selection.midX - size.width / 2, bounds.width - size.width - margin))

        let below = selection.minY - size.height - gap
        let above = selection.maxY + gap
        let y: CGFloat
        if below - reserve >= margin {
            y = below
        } else if above + size.height + reserve <= bounds.height - margin {
            y = above
        } else {
            y = max(margin, min(selection.minY + gap, bounds.height - size.height - margin))
        }
        return CGPoint(x: x, y: y)
    }

    private func removeToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        if session.takeoverActive { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        lastMousePoint = convert(event.locationInWindow, from: nil)
        updateHoverColor(at: lastMousePoint)
        updateHover(at: lastMousePoint)
    }

    override func mouseMoved(with event: NSEvent) {
        if session.takeoverActive { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        updateHoverColor(at: lastMousePoint)
        updateHover(at: lastMousePoint)
    }

    override func mouseDown(with event: NSEvent) {
        if session.takeoverActive { return }
        onInteract?()
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        commitTextFieldIfNeeded()

        if editing, session.isPickingColor {
            // One click samples or gives up. No interaction starts, so the
            // following drag and release cannot commit an annotation.
            if let selection, selection.contains(point) {
                pickColor(at: point)
            }
            session.isPickingColor = false
            needsDisplay = true
            return
        }

        if editing {
            session.showsWatermarkBar = false
            if windowTargets.isEmpty, let selection, let handle = handle(at: point, in: selection) {
                interaction = .resizing(handle: handle, rect: selection)
                return
            }
            if let selection, selection.contains(point) {
                if session.tool == .select {
                    beginSelectionInteraction(at: point, in: selection)
                    return
                }
                interaction = .drawing
                startPoint = normalize(point, in: selection)
                penPoints = []
                if session.tool == .text {
                    showTextField(at: point)
                    interaction = .none
                }
                return
            }
            return
        }

        if event.modifierFlags.contains(.shift),
           let hovered = windowUnderMouse(point) {
            toggleWindowTarget(hovered)
            return
        }

        if !windowTargets.isEmpty, let selection, selection.contains(point) {
            startEditing()
            return
        }

        if let selection {
            if windowTargets.isEmpty, let handle = handle(at: point, in: selection) {
                interaction = .resizing(handle: handle, rect: selection)
                return
            }
            if selection.contains(point) {
                interaction = .moving(start: point, rect: selection)
                return
            }
        }

        selection = nil
        interaction = .creating(start: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if session.takeoverActive { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        updateHoverColor(at: lastMousePoint)
        let point = lastMousePoint

        switch interaction {
        case .creating(let start):
            if !windowTargets.isEmpty {
                windowTargets = []
            }
            selection = clamp(rect(from: start, to: point))

        case .moving(let start, let rect):
            let offset = CGPoint(x: point.x - start.x, y: point.y - start.y)
            selection = clamp(rect.offsetBy(dx: offset.x, dy: offset.y))
            layoutToolbar()

        case .resizing(let handle, let rect):
            selection = clamp(resized(rect, handle: handle, to: point))
            layoutToolbar()

        case .drawing:
            guard let selection, let start = startPoint else { return }
            let current = normalize(point, in: selection)
            updateDraft(from: start, to: current)

        case .movingAnnotation(let start, let index, let original):
            guard let selection, session.annotations.indices.contains(index) else { return }
            let delta = CGPoint(
                x: (point.x - start.x) / selection.width,
                y: -(point.y - start.y) / selection.height
            )
            session.annotations[index] = original.moved(by: delta)

        case .resizingAnnotation(let handle, let index, let original, let rect):
            guard let selection, session.annotations.indices.contains(index) else { return }
            let newViewRect = resized(rect, handle: handle, to: point)
            let newBounds = normalizedRect(newViewRect, in: selection)
            guard newBounds.width > 0.005, newBounds.height > 0.005 else { return }
            session.annotations[index] = original.scaled(from: original.bounds, to: newBounds)

        case .none:
            break
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if session.takeoverActive { return }
        let point = convert(event.locationInWindow, from: nil)
        let previous = interaction
        interaction = .none
        defer { needsDisplay = true }

        switch previous {
        case .creating:
            if let selection, selection.width >= 4, selection.height >= 4 {
                windowTargets = []
                startEditing()
            } else {
                self.selection = nil
                if let hovered = windowUnderMouse(point) {
                    let targets = windowTargets.contains(where: { $0.id == hovered.id })
                        ? windowTargets
                        : [CaptureWindowTarget(id: hovered.id, rect: hovered.rect)]
                    applyWindowTargets(targets, startEditing: true)
                } else if windowTargets.isEmpty {
                    onCancel?()
                } else {
                    windowTargets = []
                    needsDisplay = true
                }
            }

        case .drawing:
            guard let selection, let start = startPoint else { return }
            let end = normalize(point, in: selection)

            switch session.tool {
            case .text:
                break
            case .number:
                if hypot(end.x - start.x, end.y - start.y) * selection.width < 4 {
                    commit(.number(nextNumber, at: end))
                }
            case .pen, .highlighter:
                commit(session.tool == .pen ? .pen(points: penPoints) : .highlighter(points: penPoints))
            default:
                commit(draftShape(from: start, to: end))
            }
            draft = nil
            penPoints = []

        case .movingAnnotation, .resizingAnnotation:
            session.endInteractiveChange()

        case .resizing:
            loadBase()

        default:
            break
        }
    }

    private func updateDraft(from start: CGPoint, to current: CGPoint) {
        switch session.tool {
        case .pen, .highlighter:
            penPoints.append(current)
            draft = Annotation(
                shape: session.tool == .pen ? .pen(points: penPoints) : .highlighter(points: penPoints),
                style: session.defaultStyle
            )
        case .text, .number:
            break
        default:
            draft = Annotation(
                shape: draftShape(from: start, to: current),
                style: session.defaultStyle
            )
        }
    }

    private func draftShape(from start: CGPoint, to end: CGPoint) -> Annotation.Shape {
        switch session.tool {
        case .rectangle: return .rectangle(from: start, to: end)
        case .ellipse: return .ellipse(from: start, to: end)
        case .line: return .line(from: start, to: end)
        case .mosaic: return .mosaic(from: start, to: end)
        case .blur: return .blur(from: start, to: end)
        default: return .arrow(from: start, to: end)
        }
    }

    private var nextNumber: Int {
        session.annotations.reduce(1) { count, annotation in
            if case .number = annotation.shape { return count + 1 }
            return count
        }
    }

    private func commit(_ shape: Annotation.Shape) {
        session.recordUndoSnapshot()
        session.annotations.append(Annotation(shape: shape, style: session.defaultStyle))
    }

    // MARK: - Text entry

    private func showTextField(at point: CGPoint) {
        removeTextField()
        textClickPoint = point
        textAnchor = point
        session.isTextEditing = true

        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 12, width: 200, height: 24))
        field.placeholderString = t("Text")
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        // One line, like `draw`; a wrapped field would hide the tail.
        field.cell?.wraps = false
        field.target = self
        field.action = #selector(commitText)
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        updateTextField()
    }

    /// The text as typed, including an input-method composition in progress.
    private func textFieldContents() -> String {
        guard let field = textField else { return "" }
        return (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    /// The mark the open field will commit.
    private func pendingTextAnnotation(_ text: String) -> Annotation {
        Annotation(shape: .text(text, at: .zero), style: session.defaultStyle)
    }

    /// Fits the anchor, then places and restyles the field so it shows the
    /// text where and how `draw` will.
    private func updateTextField() {
        guard let field = textField, let selection else { return }
        let text = textFieldContents()
        let measured = text.isEmpty ? t("Text") : text
        let annotation = pendingTextAnnotation(measured)

        // Fitted anchor: the drawn text stays inside the selection.
        var anchor = textClickPoint
        let probe = AnnotationRenderer.textLayout(measured, at: anchor, annotation: annotation, in: selection)
        let overflow = probe.frame.maxX - selection.maxX
        if overflow > 0 {
            anchor.x = max(selection.minX, anchor.x - overflow)
        }
        let headroom = selection.minY - probe.frame.minY
        if headroom > 0 {
            anchor.y += headroom
        }
        textAnchor = anchor

        let layout = AnnotationRenderer.textLayout(measured, at: anchor, annotation: annotation, in: selection)
        field.font = layout.font
        field.textColor = layout.textColor

        // The editor draws its glyphs at the field's top, one line-fragment
        // padding in from the left; line up the box and the glyphs.
        let editor = field.currentEditor() as? NSTextView
        editor?.insertionPointColor = layout.textColor
        let inset = editor?.textContainer?.lineFragmentPadding ?? 2
        let slack = max(0, min(2, layout.textBox.minY - selection.minY))
        var frame = NSRect(
            x: max(selection.minX, layout.textBox.minX - inset),
            // Extra room goes below, so the field's top stays at the text's top.
            y: layout.textBox.minY - slack,
            width: layout.textBox.width + inset * 2 + 1,
            height: layout.textBox.height + slack
        )
        let available = selection.maxX - frame.minX
        if available > 0 {
            frame.size.width = min(frame.width, available)
        }
        field.frame = frame
        needsDisplay = true
    }

    /// The pending text's bubble, drawn behind the field.
    private func drawTextBubble(in selection: CGRect) {
        guard textField != nil, session.defaultStyle.textBubble else { return }
        let text = textFieldContents()
        let measured = text.isEmpty ? t("Text") : text
        let layout = AnnotationRenderer.textLayout(
            measured,
            at: textAnchor,
            annotation: pendingTextAnnotation(measured),
            in: selection
        )
        guard let bubble = layout.bubble else { return }
        NSColor(session.defaultStyle.color).setFill()
        let radius = layout.font.pointSize * 0.6
        NSBezierPath(roundedRect: bubble, xRadius: radius, yRadius: radius).fill()
    }

    @objc private func commitText() {
        commitTextFieldIfNeeded()
    }

    /// Commits a pending text annotation; an empty field just disappears. Also
    /// called when the field loses focus, so a stray click never leaves a box
    /// hanging around.
    ///
    /// Finishing drops an unconfirmed input-method composition because the
    /// editor closes at once and the user never sees it.
    private func commitTextFieldIfNeeded(droppingComposition: Bool = false) {
        guard let field = textField else { return }
        let editor = field.currentEditor() as? NSTextView
        var raw = editor?.string ?? field.stringValue
        if let editor, editor.hasMarkedText() {
            if droppingComposition {
                let marked = editor.markedRange()
                raw = (raw as NSString).replacingCharacters(in: marked, with: "")
            } else {
                // Accept a composition still open in the input method.
                editor.unmarkText()
                raw = editor.string
            }
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        removeTextField()
        if !text.isEmpty, let selection {
            commit(.text(text, at: normalize(textAnchor, in: selection)))
        }
        needsDisplay = true
    }

    private func removeTextField(refocus: Bool = true) {
        guard let field = textField else { return }
        textField = nil
        session.isTextEditing = false
        let editor = field.currentEditor()
        if refocus, let responder = window?.firstResponder, responder === field || responder === editor {
            window?.makeFirstResponder(self)
        }
        field.delegate = nil
        field.removeFromSuperview()
    }

    /// Esc during input-method composition belongs to the input method.
    @discardableResult
    func handleTextFieldEscape() -> Bool {
        guard let field = textField else { return false }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return false
        }
        removeTextField()
        needsDisplay = true
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if session.takeoverActive { return }
        if editing {
            if let command = Self.historyCommand(for: event) {
                performHistory(command)
                return
            }

            if applyEditingShortcut(event) { return }

            if event.keyCode == 53, dismissEscapeLayer() { return }

            switch event.keyCode {
            case 53: onCancel?()                                  // Esc
            case 36, 76: finish(.copy)                            // Return
            case 49: finish(.save)                                // Space
            case 35: finish(.pin)                                 // P
            default: break
            }
            return
        }

        switch event.keyCode {
        case 53:
            if !windowTargets.isEmpty {
                windowTargets = []
                selection = nil
                needsDisplay = true
            } else if selection != nil {
                selection = nil
                needsDisplay = true
            } else {
                onCancel?()
            }
        case 36, 76:
            if selection != nil {
                startEditing()
            } else {
                selection = bounds
                startEditing()
            }
        case 3:
            windowTargets = []
            selection = bounds
            startEditing()
        case 15:
            if let last = SelectionMemory.lastSelection {
                windowTargets = []
                selection = clamp(last.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
                needsDisplay = true
            }
        default:
            break
        }
    }

    private func dismissEscapeLayer() -> Bool {
        if session.isPickingColor {
            session.isPickingColor = false
            needsDisplay = true
            return true
        }
        if session.showsWatermarkBar {
            session.showsWatermarkBar = false
            return true
        }
        if session.tool != .select {
            cancelCanvasInteractionForHistory()
            session.tool = .select
            needsDisplay = true
            return true
        }
        return false
    }

    /// Tool letters, the Tab toggle and the colour eyedropper only work once
    /// the toolbar is up, no text field (including an input-method composition)
    /// owns the keys, and no ⌘/⌃/⌥ shortcut is meant.
    /// `charactersIgnoringModifiers` keeps this right on layouts such as
    /// Dvorak.
    private func applyEditingShortcut(_ event: NSEvent) -> Bool {
        guard textField == nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }

        if event.keyCode == 48 { // Tab
            if event.isARepeat { return true }
            session.toolbarVisible.toggle()
            return true
        }

        guard let character = event.charactersIgnoringModifiers?.lowercased().first else {
            return false
        }

        // I is the eyedropper. It has no meaning where the colour button is
        // hidden, so those tools keep their keys.
        if character == "i" {
            guard session.showsOptionsRow, session.allowsColorStyles else { return false }
            if event.isARepeat { return true }
            if interaction.isIdle {
                session.isPickingColor.toggle()
            }
            return true
        }

        guard let tool = CaptureSession.Tool.tool(forShortcut: character) else { return false }
        // A drag is finished by the tool that started it; switching mid-drag
        // would commit it as another shape or drop it.
        if event.isARepeat { return true }
        if interaction.isIdle {
            session.isPickingColor = false
            session.toggleTool(tool)
        }
        return true
    }

    /// Shared by the local key monitor and `keyDown` so both entry points treat
    /// ⌘Z and ⇧⌘Z the same way.
    static func historyCommand(for event: NSEvent) -> HistoryCommand? {
        guard event.keyCode == 6, event.modifierFlags.contains(.command) else { return nil }
        return event.modifierFlags.contains(.shift) ? .redo : .undo
    }

    private func performHistory(_ command: HistoryCommand) {
        switch command {
        case .undo:
            guard session.canUndo else { return }
        case .redo:
            guard session.canRedo else { return }
        }
        cancelCanvasInteractionForHistory()
        switch command {
        case .undo: session.undo()
        case .redo: session.redo()
        }
        needsDisplay = true
    }

    /// Undo and redo must end an annotation drag or drawing preview that is
    /// under way; otherwise its cached `original`/`index` would be written over
    /// the restored content by the next `mouseDragged`. Selection geometry is
    /// not part of history, so its drag keeps running to its usual `mouseUp`.
    private func cancelCanvasInteractionForHistory() {
        switch interaction {
        case .movingAnnotation, .resizingAnnotation:
            interaction = .none
            session.endInteractiveChange()
        case .drawing:
            interaction = .none
            draft = nil
            penPoints = []
            startPoint = nil
        case .none, .creating, .moving, .resizing:
            break
        }
    }

    // MARK: - Geometry

    private func beginSelectionInteraction(at point: CGPoint, in selection: CGRect) {
        if let index = session.selectionIndex,
           session.annotations.indices.contains(index),
           hasResizeHandles(session.annotations[index].shape) {
            let rect = annotationFrame(index, in: selection)
            if let handle = handle(at: point, in: rect) {
                session.beginInteractiveChange()
                interaction = .resizingAnnotation(
                    handle: handle,
                    index: index,
                    original: session.annotations[index],
                    rect: rect
                )
                return
            }
        }

        if let index = annotationIndex(at: point, in: selection) {
            session.selectionIndex = index
            session.beginInteractiveChange()
            interaction = .movingAnnotation(
                start: point,
                index: index,
                original: session.annotations[index]
            )
            needsDisplay = true
            return
        }

        session.selectionIndex = nil
        needsDisplay = true
    }

    /// Text and numbers are hit where they are drawn, not at their anchor.
    private func annotationIndex(at point: CGPoint, in selection: CGRect) -> Int? {
        let tolerance = 0.012 * selection.width
        for index in session.annotations.indices.reversed() {
            let annotation = session.annotations[index]
            switch annotation.shape {
            case .text, .number:
                if annotationFrame(index, in: selection)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                    .contains(point) {
                    return index
                }
            default:
                if annotation.contains(normalize(point, in: selection)) {
                    return index
                }
            }
        }
        return nil
    }

    private func annotationFrame(_ index: Int, in selection: CGRect) -> CGRect {
        guard session.annotations.indices.contains(index) else { return .zero }
        let annotation = session.annotations[index]
        return AnnotationRenderer.frame(of: annotation, in: selection)
            ?? viewRect(for: annotation.bounds, in: selection)
    }

    private func viewRect(for bounds: CGRect, in selection: CGRect) -> CGRect {
        CGRect(
            x: selection.minX + bounds.minX * selection.width,
            y: selection.maxY - bounds.maxY * selection.height,
            width: bounds.width * selection.width,
            height: bounds.height * selection.height
        )
    }

    private func normalizedRect(_ rect: CGRect, in selection: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - selection.minX) / max(1, selection.width),
            y: (selection.maxY - rect.maxY) / max(1, selection.height),
            width: rect.width / max(1, selection.width),
            height: rect.height / max(1, selection.height)
        )
    }

    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
            y: min(1, max(0, (rect.maxY - point.y) / max(1, rect.height)))
        )
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// Keeps the region on screen and snaps it to whole device pixels. Mouse
    /// locations can be fractional; a frozen capture drawn into an unaligned
    /// rect is resampled and looks soft next to the live screen.
    private func clamp(_ rect: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull else { return clipped }
        let scale = max(1, screen.backingScaleFactor)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(clipped.minX), minY = snap(clipped.minY)
        let maxX = snap(clipped.maxX), maxY = snap(clipped.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func handleRects(for rect: CGRect) -> [Handle: CGRect] {
        let size: CGFloat = 9
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
        }
        return [
            .topLeft: box(rect.minX, rect.maxY),
            .top: box(rect.midX, rect.maxY),
            .topRight: box(rect.maxX, rect.maxY),
            .right: box(rect.maxX, rect.midY),
            .bottomRight: box(rect.maxX, rect.minY),
            .bottom: box(rect.midX, rect.minY),
            .bottomLeft: box(rect.minX, rect.minY),
            .left: box(rect.minX, rect.midY),
        ]
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        for (handle, box) in handleRects(for: rect) {
            if box.insetBy(dx: -4, dy: -4).contains(point) { return handle }
        }
        return nil
    }

    private func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }

        return CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: abs(maxX - minX), height: abs(maxY - minY)
        )
    }

    private func updateHover(at point: CGPoint) {
        guard !editing, interaction.isIdle else { return }
        guard selection == nil || !windowTargets.isEmpty else { return }
        hovered = windowUnderMouse(point)
        needsDisplay = true
    }

    /// Picks the window under the pointer into the pending set, or removes it.
    private func toggleWindowTarget(_ hovered: (id: CGWindowID, rect: CGRect)) {
        var targets = windowTargets
        if let index = targets.firstIndex(where: { $0.id == hovered.id }) {
            targets.remove(at: index)
        } else {
            targets.append(CaptureWindowTarget(id: hovered.id, rect: hovered.rect))
        }
        applyWindowTargets(targets, startEditing: false)
    }

    private func applyWindowTargets(_ targets: [CaptureWindowTarget], startEditing shouldEdit: Bool) {
        windowTargets = targets
        guard let canvas = WindowComposer.canvas(for: targets, screenBounds: bounds) else {
            windowTargets = []
            selection = nil
            needsDisplay = true
            return
        }
        selection = canvas
        if shouldEdit {
            startEditing()
        } else {
            needsDisplay = true
        }
    }

    private var primaryHeight: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
    }

    private func windowUnderMouse(_ point: CGPoint) -> (id: CGWindowID, rect: CGRect)? {
        let global = CGPoint(x: point.x + screen.frame.minX, y: point.y + screen.frame.minY)
        let mainHeight = primaryHeight
        let topLeftPoint = CGPoint(x: global.x, y: mainHeight - global.y)

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let excluded = SelectionController.overlayWindowIDs

        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !excluded.contains(id),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= NSWindow.Level.normal.rawValue,
                  layer <= NSWindow.Level.modalPanel.rawValue,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            guard rect.width >= 60, rect.height >= 60, rect.contains(topLeftPoint) else { continue }

            let local = CGRect(
                x: rect.minX - screen.frame.minX,
                y: (mainHeight - rect.maxY) - screen.frame.minY,
                width: rect.width,
                height: rect.height
            )
            return (id, local)
        }
        return nil
    }
}

/// Remembers the last region so `R` can reuse it.
private enum SelectionMemory {
    private static let key = "ScreenshotLastSelection"

    static var lastSelection: CGRect? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 4 else {
            return nil
        }
        let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard rect.width > 4, rect.height > 4 else { return nil }
        return rect
    }

    static func save(_ rect: CGRect) {
        UserDefaults.standard.set(
            [rect.origin.x, rect.origin.y, rect.width, rect.height],
            forKey: key
        )
    }
}

extension SelectionView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextFieldIfNeeded()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateTextField()
    }
}

/// Small non-activating toast used for the colour copy and for messages an
/// extension shows during a takeover.
@MainActor
enum ColorToast {
    private static var windows: [NSWindow] = []

    /// The toasts still on screen, oldest first. Internal so tests can inspect
    /// and close them without waiting for the timer.
    static var currentWindows: [NSWindow] { windows }

    /// Shows `text` next to the mouse, on the screen that holds it. A caller
    /// that names a screen the mouse is not on gets the toast centred there
    /// instead. The default placement, used by the colour-copy toast, keeps the
    /// mouse position and the screen that holds it.
    @discardableResult
    static func show(
        _ text: String,
        level: NSWindow.Level = .statusBar,
        screen: NSScreen? = nil
    ) -> NSWindow {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let padding: CGFloat = 14
        let size = NSSize(
            width: label.frame.width + padding * 2,
            height: label.frame.height + padding
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 8
        label.frame.origin = NSPoint(x: padding, y: padding / 2)
        container.addSubview(label)
        window.contentView = container

        let mouse = NSEvent.mouseLocation
        let origin: NSPoint
        let visible: NSRect
        if let screen, !screen.frame.contains(mouse) {
            // The caller named a screen the pointer is not on: centre there.
            visible = screen.visibleFrame
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        } else {
            // Next to the pointer, on the screen that holds it. With no screen
            // passed this is exactly the placement the colour-copy toast has
            // always used.
            let target = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            visible = target?.visibleFrame ?? .zero
            origin = NSPoint(x: mouse.x + 18, y: mouse.y - size.height - 18)
        }
        window.setFrameOrigin(NSPoint(
            x: min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8),
            y: min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        ))

        window.orderFrontRegardless()
        windows.append(window)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            window.orderOut(nil)
            windows.removeAll { $0 === window }
        }
        return window
    }

    /// Closes every toast now. Tests use it so a timer from one case cannot
    /// linger into the next.
    static func closeAll() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

import AppKit
import SwiftUI
import PanelumiKit

/// State for the in-place capture editor: the toolbar that sits under the
/// selection, plus the annotations drawn on it.
@MainActor
final class CaptureSession: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, rectangle, ellipse, line, arrow, pen, highlighter, text, number, mosaic, blur

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .text: return "character"
            case .number: return "1.circle"
            case .mosaic: return "square.grid.3x3"
            case .blur: return "aqi.medium"
            }
        }

        var title: String {
            switch self {
            case .select: return t("Select")
            case .rectangle: return t("Rectangle")
            case .ellipse: return t("Ellipse")
            case .line: return t("Line")
            case .arrow: return t("Arrow")
            case .pen: return t("Freehand")
            case .highlighter: return t("Highlighter")
            case .text: return t("Text")
            case .number: return t("Number")
            case .mosaic: return t("Mosaic")
            case .blur: return t("Blur")
            }
        }

        var shortcut: Character {
            switch self {
            case .select: return "V"
            case .rectangle: return "R"
            case .ellipse: return "O"
            case .line: return "L"
            case .arrow: return "A"
            case .pen: return "D"
            case .highlighter: return "H"
            case .text: return "T"
            case .number: return "N"
            case .mosaic: return "M"
            case .blur: return "B"
            }
        }

        /// Character to tool, so the shortcut follows the layout instead of the
        /// key code.
        static func tool(forShortcut character: Character) -> Tool? {
            let lowered = character.lowercased()
            return allCases.first { String($0.shortcut).lowercased() == lowered }
        }
    }

    enum Output {
        case copy
        case save
        case pin
        /// Read the text (or QR code) in the region and copy that instead.
        case recognizeText
    }

    @Published var tool: Tool = .select {
        didSet {
            if tool != .select {
                selectionIndex = nil
            }
            if tool != oldValue {
                showsWatermarkBar = false
            }
        }
    }

    func toggleTool(_ tool: Tool) {
        self.tool = (self.tool == tool && tool != .select) ? .select : tool
    }

    @Published var selectionIndex: Int? {
        didSet {
            if selectionIndex != nil {
                showsWatermarkBar = false
            }
        }
    }
    @Published var toolbarVisible = true
    /// True while an extension's takeover controls the selection. The
    /// controller is the only writer; views read it instead of keeping a copy.
    @Published var takeoverActive = false
    /// Extensions for the capture toolbar. Set once per capture by the
    /// controller; the views read it.
    var captureExtensions: [any CaptureExtension] = []
    /// The toolbar items of `captureExtensions`, snapshotted when the user
    /// starts editing (once per editing view; a selection spanning two displays
    /// reads the items for each). The toolbar body reads this instead of calling
    /// the extensions.
    /// The size of the capture in screen points, so the toolbar can show a
    /// width in points instead of a slider level. Zero until editing starts.
    @Published var imagePointSize: CGSize = .zero
    @Published var extensionToolbarItems: [CaptureExtensionToolbarEntry] = []
    /// False while the selection is a set of windows: the toolbar actions need a
    /// region, and a window composite is not one.
    @Published var captureActionsAllowed = true
    @Published var defaultStyle = AnnotationStyle() {
        didSet { persistDefaultStyle(from: oldValue) }
    }
    /// The highlighter's drawing mode: freehand, or one straight band per drag.
    @Published var highlighterStraight = true {
        didSet {
            guard hasLoadedPreferences, highlighterStraight != oldValue else { return }
            ScreenshotPreferences.highlighterStraight = highlighterStraight
        }
    }
    @Published private(set) var recentAnnotationColors: [String] = []
    /// True while a click on the screenshot samples a colour instead of
    /// drawing. Reset with every capture.
    @Published var isPickingColor = false
    /// True while the text tool's field is open. The eyedropper is inert then:
    /// a click belongs to the field, not the screenshot.
    @Published var isTextEditing = false
    @Published var annotations: [Annotation] = [] {
        didSet { refreshHistoryAvailability() }
    }
    @Published var watermarkEnabled = ScreenshotPreferences.watermarkOnByDefault
    @Published var watermarkHidden = false
    @Published var watermarkPlacement: AnnotationRenderer.WatermarkOptions.Placement =
        ScreenshotPreferences.defaultWatermarkPlacement
    @Published var watermarkScale: CGFloat = ScreenshotPreferences.defaultWatermarkScale
    @Published var watermarkRotation: CGFloat = ScreenshotPreferences.defaultWatermarkRotation
    @Published var watermarkOpacity: CGFloat = ScreenshotPreferences.defaultWatermarkOpacity
    @Published var watermarkColor: Color =
        AnnotationPalette.color(fromHex: ScreenshotPreferences.defaultWatermarkColor) ?? .white

    @Published var watermarkText: String = ScreenshotPreferences.defaultWatermarkText

    /// True while the watermark submenu replaces the options row.
    @Published var showsWatermarkBar = false

    /// Turning the watermark off also drops the "hidden" flag: hiding is only
    /// meaningful for a watermark that would otherwise be drawn.
    func setWatermarkEnabled(_ enabled: Bool) {
        watermarkEnabled = enabled
        if !enabled { watermarkHidden = false }
    }

    var watermarkEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.watermarkEnabled },
            set: { self.setWatermarkEnabled($0) }
        )
    }

    /// Every capture starts from Settings › Screenshot rather than from
    /// whatever the previous screenshot left behind.
    func prepareForCapture() {
        watermarkEnabled = ScreenshotPreferences.watermarkOnByDefault
        let stored = ScreenshotPreferences.watermarkText
        watermarkText = stored.isEmpty ? ScreenshotPreferences.defaultWatermarkText : stored
        watermarkHidden = false
        watermarkPlacement = ScreenshotPreferences.watermarkPlacement
        watermarkScale = ScreenshotPreferences.watermarkScale
        watermarkRotation = ScreenshotPreferences.watermarkRotation
        watermarkOpacity = ScreenshotPreferences.watermarkOpacity
        if let color = AnnotationPalette.color(fromHex: ScreenshotPreferences.watermarkColor) {
            watermarkColor = color
        }
        toolbarVisible = true
        showsWatermarkBar = false
        isPickingColor = false
        isTextEditing = false
        if let color = AnnotationPalette.color(fromHex: ScreenshotPreferences.annotationColor) {
            defaultStyle.color = color
        }
        defaultStyle.lineWidth = ScreenshotPreferences.annotationLineWidth
        defaultStyle.highlighterWidth = ScreenshotPreferences.highlighterWidth
        highlighterStraight = ScreenshotPreferences.highlighterStraight
        recentAnnotationColors = ScreenshotPreferences.recentAnnotationColors
        hasLoadedPreferences = true
    }

    /// True once the defaults came from Settings. Before that, writes come from
    /// tests or a preview and must not reach the real preferences.
    private var hasLoadedPreferences = false

    private func persistDefaultStyle(from previous: AnnotationStyle) {
        guard hasLoadedPreferences else { return }
        if previous.color != defaultStyle.color,
           let hex = AnnotationPalette.hex(for: defaultStyle.color) {
            ScreenshotPreferences.annotationColor = hex
        }
        if previous.lineWidth != defaultStyle.lineWidth {
            ScreenshotPreferences.annotationLineWidth = defaultStyle.lineWidth
        }
        if previous.highlighterWidth != defaultStyle.highlighterWidth {
            ScreenshotPreferences.highlighterWidth = defaultStyle.highlighterWidth
        }
    }

    /// Adds a colour the user confirmed to the recent list, newest first.
    func rememberRecentColor(_ hex: String) {
        let updated = AnnotationPalette.addingRecent(hex, to: recentAnnotationColors)
        guard updated != recentAnnotationColors else { return }
        recentAnnotationColors = updated
        ScreenshotPreferences.recentAnnotationColors = updated
    }

    /// True while the active tool draws with a colour. Mosaic and blur repaint
    /// pixels instead, so they hide the colour button and the eyedropper.
    var allowsColorStyles: Bool {
        switch displayTool {
        case .mosaic, .blur: return false
        default: return true
        }
    }

    /// Builds the toolbar snapshot for one capture: one entry per extension
    /// that returns an item with at least one entry, in registration order.
    /// Extensions without an item, or with an empty item, are left out.
    @MainActor
    static func toolbarEntries(
        for extensions: [any CaptureExtension]
    ) -> [CaptureExtensionToolbarEntry] {
        extensions.compactMap { ext in
            guard let item = ext.toolbarItem, !item.entries.isEmpty else { return nil }
            return CaptureExtensionToolbarEntry(id: ext.identifier, item: item)
        }
    }

    var watermarkOptions: AnnotationRenderer.WatermarkOptions? {
        guard watermarkEnabled else { return nil }
        return .init(
            text: watermarkText,
            placement: watermarkPlacement,
            scale: watermarkScale,
            rotation: watermarkRotation,
            opacity: watermarkOpacity,
            color: NSColor(watermarkColor)
        )
    }

    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}
    var onPin: () -> Void = {}
    var onClose: () -> Void = {}

    // MARK: - Selection style

    var selectedAnnotation: Annotation? {
        guard let index = selectionIndex,
              annotations.indices.contains(index) else { return nil }
        return annotations[index]
    }

    var hasSelectedAnnotation: Bool { selectedAnnotation != nil }

    var showsOptionsRow: Bool {
        displayTool != .select || showsWatermarkBar
    }

    /// The tool whose options describe what is being edited: the selected
    /// annotation's shape in Select, otherwise the active drawing tool.
    var displayTool: Tool {
        guard let shape = selectedAnnotation?.shape else { return tool }
        return Self.tool(for: shape)
    }

    /// Style writes target the selected annotation and always become the
    /// default for the next mark. Only a real change to a selected annotation
    /// is recorded in history; editing defaults alone is not a content change.
    var activeStyle: AnnotationStyle {
        get { selectedAnnotation?.style ?? defaultStyle }
        set {
            let previous = activeStyle
            if let index = selectionIndex,
               annotations.indices.contains(index),
               newValue != previous {
                recordUndoSnapshot()
                var annotation = annotations[index]
                annotation.style = newValue
                annotations[index] = annotation
            }
            defaultStyle = newValue
        }
    }

    func styleBinding<Value>(
        _ keyPath: WritableKeyPath<AnnotationStyle, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self.activeStyle[keyPath: keyPath] },
            set: { self.activeStyle[keyPath: keyPath] = $0 }
        )
    }

    /// What the shared colour popover edits for annotations: the active style,
    /// one history step per drag, and the recent list both palettes write to.
    var annotationColorPalette: ColorPaletteTarget {
        ColorPaletteTarget(
            color: styleBinding(\.color),
            recentColors: recentAnnotationColors,
            beginInteractiveChange: beginInteractiveChange,
            endInteractiveChange: endInteractiveChange,
            remember: rememberRecentColor
        )
    }

    /// The watermark colour is not content of the annotation history, so a
    /// drag there opens no step; the recent list is still shared.
    var watermarkColorPalette: ColorPaletteTarget {
        ColorPaletteTarget(
            color: Binding(get: { self.watermarkColor }, set: { self.watermarkColor = $0 }),
            recentColors: recentAnnotationColors,
            remember: rememberRecentColor
        )
    }

    static func tool(for shape: Annotation.Shape) -> Tool {
        switch shape {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .text: return .text
        case .number: return .number
        case .mosaic: return .mosaic
        case .blur: return .blur
        }
    }

    // MARK: - History

    private struct HistoryState: Equatable {
        var annotations: [Annotation]
        var defaultStyle: AnnotationStyle
    }

    private static let historyLimit = 50

    /// Published so the toolbar's undo and redo buttons follow the stacks.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [HistoryState] = []
    private var redoStack: [HistoryState] = []
    private var pendingSnapshot: HistoryState?
    private var isCoalescing = false

    private var currentSnapshot: HistoryState {
        HistoryState(annotations: annotations, defaultStyle: defaultStyle)
    }

    /// Records the state before a discrete content change, such as adding an
    /// annotation, deleting one, or editing the selected annotation's style.
    func recordUndoSnapshot() {
        guard !isCoalescing else { return }
        pushUndo(currentSnapshot)
    }

    /// Starts a drag or slider gesture. The snapshot is only pushed by
    /// `endInteractiveChange()` when the content actually changed, so a click
    /// that moves nothing creates no history and keeps the redo stack.
    func beginInteractiveChange() {
        guard !isCoalescing else { return }
        isCoalescing = true
        pendingSnapshot = currentSnapshot
    }

    func endInteractiveChange() {
        resolveInteractiveChange()
    }

    func undo() {
        guard canUndo else { return }
        resolveInteractiveChange()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(previous)
    }

    func redo() {
        guard canRedo else { return }
        resolveInteractiveChange()
        guard let next = redoStack.popLast() else { return }
        pushUndoWithoutClearingRedo(currentSnapshot)
        restore(next)
    }

    /// Starts a fresh capture with no leftover history.
    func resetHistory() {
        cancelInteractiveChange()
        undoStack.removeAll()
        redoStack.removeAll()
        refreshHistoryAvailability()
    }

    private func pushUndo(_ snapshot: HistoryState) {
        pushUndoWithoutClearingRedo(snapshot)
        redoStack.removeAll()
        refreshHistoryAvailability()
    }

    private func pushUndoWithoutClearingRedo(_ snapshot: HistoryState) {
        undoStack.append(snapshot)
        if undoStack.count > Self.historyLimit {
            undoStack.removeFirst(undoStack.count - Self.historyLimit)
        }
    }

    private func restore(_ snapshot: HistoryState) {
        annotations = snapshot.annotations
        defaultStyle = snapshot.defaultStyle
        selectionIndex = nil
        refreshHistoryAvailability()
    }

    /// Commits an in-progress gesture before history navigation. A gesture that
    /// really changed the content becomes one undo step; an unchanged one is
    /// dropped, leaving the redo stack alone.
    @discardableResult
    private func resolveInteractiveChange() -> Bool {
        guard isCoalescing else { return false }
        isCoalescing = false
        guard let snapshot = pendingSnapshot else { return false }
        pendingSnapshot = nil
        guard snapshot.annotations != annotations else {
            refreshHistoryAvailability()
            return false
        }
        pushUndo(snapshot)
        return true
    }

    private func cancelInteractiveChange() {
        isCoalescing = false
        pendingSnapshot = nil
    }

    /// A gesture in progress counts as undoable as soon as it changes content,
    /// and temporarily hides redo so the toolbar and the keyboard agree.
    private var pendingContentChanged: Bool {
        guard let pendingSnapshot else { return false }
        return pendingSnapshot.annotations != annotations
    }

    private func refreshHistoryAvailability() {
        let pendingChanged = pendingContentChanged
        canUndo = !undoStack.isEmpty || pendingChanged
        canRedo = !redoStack.isEmpty && !pendingChanged
    }
}

/// Everything the overlay hands to the coordinator when the user finishes.
struct CapturePayload {
    let rect: CGRect
    let screen: NSScreen
    let annotations: [Annotation]
    let base: CGImage?
    /// Watermark to keep (also when it is hidden on the image).
    let watermark: AnnotationRenderer.WatermarkOptions?
    /// False when the watermark should be invisible but still recorded.
    let watermarkVisible: Bool
}

/// One extension's toolbar item, snapshotted when editing starts so the
/// SwiftUI body never calls back into the extension.
struct CaptureExtensionToolbarEntry: Identifiable {
    /// The extension's identifier; also the toolbar item's identity.
    let id: String
    /// The item to show, with at least one entry.
    let item: CaptureToolbarItem
}

/// Which edge of one toolbar its popovers open from: away from the
/// selection, so they do not cover what is being captured. Each screen's
/// toolbar owns one. On the shared session, two screens wanting opposite
/// edges would overwrite each other through its change sink forever.
@MainActor
final class ToolbarPopoverPlacement: ObservableObject {
    @Published var edge: Edge = .bottom
}

/// The one colour the shared popover edits, with the hooks that differ between
/// callers: annotations record history, the watermark does not.
struct ColorPaletteTarget {
    var color: Binding<Color>
    var recentColors: [String]
    var beginInteractiveChange: () -> Void = {}
    var endInteractiveChange: () -> Void = {}
    var remember: (String) -> Void = { _ in }
}

struct CaptureToolbarView: View {
    @ObservedObject var session: CaptureSession
    @ObservedObject var popoverPlacement = ToolbarPopoverPlacement()
    /// Called with (extension identifier, entry id) when the user picks an
    /// entry. The capture view supplies it; the default does nothing.
    var onCaptureAction: (String, String) -> Void = { _, _ in }
    @State private var showColors = false
    @State private var hovered: HoverItem?

    /// Height of the strip above the pill that names what the pointer is on.
    /// The hosting view's hit test uses the same value.
    static let hintBandHeight: CGFloat = 24
    static let optionsRowHeight: CGFloat = 36
    static let optionsRowSpacing: CGFloat = 5
    static var optionsRowReserve: CGFloat { optionsRowHeight + optionsRowSpacing }

    private enum HoverItem: Equatable {
        case tool(CaptureSession.Tool)
        case action(String)
    }

    /// The extension whose entry popover is open, by identifier.
    @State private var openExtensionPopover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Self.optionsRowSpacing) {
            if popoverPlacement.edge == .top {
                optionsRowIfShown
                mainRow
                hintBand
            } else {
                hintBand
                mainRow
                optionsRowIfShown
            }
        }
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: popoverPlacement.edge == .top ? .bottom : .top)
        .onChange(of: session.showsOptionsRow) { _, shown in
            if !shown {
                showColors = false
            }
        }
    }

    private var hintText: String {
        switch hovered {
        case .tool(let tool): return "\(tool.title)  \(tool.shortcut)"
        case .action(let text): return text
        case nil:
            if session.isPickingColor {
                return t("Click the screenshot to pick a colour · Esc cancels")
            }
            return t("↩ Copy · Space Save · P Pin · ⌘Z Undo · ⌫ Delete · ⇥ Hide · Esc Close")
        }
    }

    private var hoveredTool: CaptureSession.Tool? {
        if case .tool(let tool) = hovered { return tool }
        return nil
    }

    private func hover(_ item: HoverItem, inside: Bool) {
        if inside {
            hovered = item
        } else if hovered == item {
            hovered = nil
        }
    }

    private var hintBand: some View {
        Text(hintText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .frame(height: Self.hintBandHeight)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
    }

    private var mainRow: some View {
        HStack(spacing: 5) {
            ForEach(CaptureSession.Tool.allCases.filter { $0 != .select }) { tool in
                toolButton(tool)
            }

            Divider().frame(height: 18)

            watermarkChip

            Divider().frame(height: 18)

            ForEach(session.extensionToolbarItems) { entry in
                captureActionView(entry)
            }

            icon("arrow.uturn.backward", hint: t("Undo (⌘Z)"), enabled: session.canUndo, action: session.onUndo)
            icon("arrow.uturn.forward", hint: t("Redo (⇧⌘Z)"), enabled: session.canRedo, action: session.onRedo)

            Divider().frame(height: 18)

            primaryIcon("doc.on.doc", hint: t("Copy (↩)"), action: session.onCopy)
            icon("square.and.arrow.down", hint: t("Save (Space)"), action: session.onSave)
            icon("pin", hint: t("Pin (P)"), action: session.onPin)
            icon("xmark", hint: t("Close (Esc)"), action: session.onClose)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .fixedSize()
    }

    private func toolButton(_ tool: CaptureSession.Tool) -> some View {
        let active = session.tool == tool
        return Button {
            session.toggleTool(tool)
            session.isPickingColor = false
            showColors = false
        } label: {
            toolGlyph(tool)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active
                            ? Color.accentColor.opacity(0.14)
                            : hoveredTool == tool ? Color.primary.opacity(0.08) : Color.clear)
                )
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .onHover { hover(.tool(tool), inside: $0) }
    }

    @ViewBuilder
    private func toolGlyph(_ tool: CaptureSession.Tool) -> some View {
        switch tool {
        case .mosaic:
            MosaicToolIcon().frame(width: 15, height: 15)
        case .blur:
            BlurToolIcon().frame(width: 15, height: 15)
        case .arrow:
            Image(systemName: arrowSymbol).font(.system(size: 12.5, weight: .medium))
        case .text:
            // SF Symbols localises `character` (字 in Chinese); the tool should look the same everywhere.
            Text(verbatim: "A").font(.system(size: 14, weight: .medium))
        default:
            Image(systemName: tool.symbol).font(.system(size: 12.5, weight: .medium))
        }
    }

    @ViewBuilder
    private var optionsRowIfShown: some View {
        if session.showsOptionsRow {
            optionsRow
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 5) {
            if session.showsWatermarkBar {
                watermarkBar
            } else {
                if showsColorSwatch {
                    colorControls
                    Divider().frame(height: 18)
                }
                toolOptions
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 7, y: 3)
    }

    var showsColorSwatch: Bool { session.allowsColorStyles }

    /// The colour well and the eyedropper read as one control: both set the
    /// same colour, one from the palette and one from the picture.
    private var colorControls: some View {
        HStack(spacing: 0) {
            colorButton
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
            colorPickButton
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var colorButton: some View {
        Button { showColors.toggle() } label: {
            Circle().fill(session.activeStyle.color).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Annotation color"))
        .onHover { hover(.action(t("Color")), inside: $0) }
        .popover(isPresented: $showColors, arrowEdge: popoverPlacement.edge) {
            ColorPalettePopover(
                target: session.annotationColorPalette,
                onPick: { showColors = false },
                onHover: { hover(.action($0), inside: $1) }
            )
        }
    }

    private var colorPickButton: some View {
        optionButton(
            t("Pick a colour from the screenshot"),
            hoverText: "\(t("Pick a colour from the screenshot"))  I",
            selected: session.isPickingColor
        ) {
            guard !session.isTextEditing else { return }
            session.isPickingColor.toggle()
        } label: {
            Image(systemName: "eyedropper").font(.system(size: 13, weight: .medium))
        }
    }

    @ViewBuilder private var toolOptions: some View {
        let tool = session.displayTool
        switch tool {
        case .arrow:
            ForEach([ArrowStyle.straight, .curved, .elbow, .sCurve], id: \.self) { style in
                optionButton(style.title, selected: session.activeStyle.arrowStyle == style) { session.activeStyle.arrowStyle = style } label: {
                    ArrowOptionIcon(style: style).stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: 20)
                }
            }
            patternControls
            lineWidthSlider
        case .rectangle, .ellipse:
            ForEach(ShapeFillStyle.allCases, id: \.self) { style in
                optionButton(style.title, selected: session.activeStyle.fillStyle == style) { session.activeStyle.fillStyle = style } label: {
                    FillOptionIcon(style: style, ellipse: tool == .ellipse).frame(width: 20, height: 20)
                }
            }
            patternControls
            lineWidthSlider
        case .text:
            ForEach(Self.textSizeChoices) { choice in
                optionButton(
                    choice.name,
                    hoverText: tf("Font size %d", Int((choice.scale * 1000).rounded())),
                    selected: session.activeStyle.textScale == choice.scale
                ) {
                    session.activeStyle.textScale = choice.scale
                } label: {
                    Text(choice.name).font(.system(size: 11, weight: .medium))
                }
            }
            Divider().frame(height: 18)
            optionIcon("text.bubble", t("Bubble background"), selected: session.activeStyle.textBubble) { session.activeStyle.textBubble.toggle() }
        case .number:
            optionIcon("1.circle", t("Circle marker"), selected: session.activeStyle.numberStyle == .circle) { session.activeStyle.numberStyle = .circle }
            optionIcon("1.square", t("Square marker"), selected: session.activeStyle.numberStyle == .square) { session.activeStyle.numberStyle = .square }
        case .mosaic, .blur:
            toolGlyph(tool).frame(width: 26)
            optionSlider(
                t("Strength"),
                value: session.styleBinding(\.mosaicBlock),
                range: 6...32,
                text: "\(Int(session.activeStyle.mosaicBlock.rounded()))"
            )
        case .highlighter:
            optionButton(t("Straight band"), selected: session.highlighterStraight) {
                session.highlighterStraight = true
            } label: {
                StraightBandIcon().frame(width: 21, height: 15)
            }
            optionIcon("scribble", t("Freehand"), selected: !session.highlighterStraight) {
                session.highlighterStraight = false
            }
            highlighterWidthSlider
            Image(systemName: "circle.lefthalf.filled").frame(width: 22)
            optionSlider(
                t("Opacity"),
                value: session.styleBinding(\.highlighterAlpha),
                range: 0.15...0.7,
                text: "\(Int((session.activeStyle.highlighterAlpha * 100).rounded()))%"
            )
        case .line, .pen:
            patternControls
            lineWidthSlider
        case .select:
            Text(t("Click an annotation to adjust its style"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var lineWidthSlider: some View {
        widthSlider(
            session.styleBinding(\.lineWidth),
            range: ScreenshotPreferences.annotationLineWidthRange,
            text: Self.widthLabel(
                for: session.activeStyle.lineWidth,
                in: session.imagePointSize,
                level: Self.lineWidthLevel(for: session.activeStyle.lineWidth)
            )
        )
    }

    private var highlighterWidthSlider: some View {
        widthSlider(
            session.styleBinding(\.highlighterWidth),
            range: ScreenshotPreferences.highlighterWidthRange,
            text: Self.widthLabel(
                for: session.activeStyle.highlighterWidth,
                in: session.imagePointSize,
                level: Self.highlighterWidthLevel(for: session.activeStyle.highlighterWidth)
            )
        )
    }

    /// Widths are stored relative to the capture, so the points they come to
    /// depend on it. Showing points lets the number be compared with a font
    /// size; the level is the fallback before the capture size is known.
    static func widthLabel(for width: CGFloat, in size: CGSize, level: Int) -> String {
        guard size.width > 0 else { return "\(level)" }
        return "\(Int((width * size.width).rounded())) pt"
    }

    private func widthSlider(
        _ value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        text: String
    ) -> some View {
        HStack(spacing: 3) {
            Divider().frame(height: 18)
            Image(systemName: "lineweight").frame(width: 23)
            optionSlider(t("Line width"), value: value, range: range, text: text)
        }
    }

    /// Display-only 1…10 step for the stored width; what is stored keeps the
    /// range of the preference it belongs to.
    static func lineWidthLevel(for width: CGFloat) -> Int {
        widthLevel(for: width, range: ScreenshotPreferences.annotationLineWidthRange)
    }

    static func highlighterWidthLevel(for width: CGFloat) -> Int {
        widthLevel(for: width, range: ScreenshotPreferences.highlighterWidthRange)
    }

    private static func widthLevel(for width: CGFloat, range: ClosedRange<CGFloat>) -> Int {
        let step = (range.upperBound - range.lowerBound) / 9
        let level = ((width - range.lowerBound) / step).rounded() + 1
        return max(1, min(10, Int(level)))
    }

    private var patternControls: some View {
        HStack(spacing: 3) {
            Divider().frame(height: 18)
            ForEach(LinePattern.allCases, id: \.self) { pattern in
                optionButton(pattern.title, selected: session.activeStyle.linePattern == pattern) { session.activeStyle.linePattern = pattern } label: {
                    LinePatternIcon(pattern: pattern).frame(width: 22, height: 18)
                }
            }
        }
    }

    private func optionSlider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        text: String
    ) -> some View {
        HStack(spacing: 4) {
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing {
                    session.beginInteractiveChange()
                } else {
                    session.endInteractiveChange()
                }
            })
            .controlSize(.mini).frame(width: 90)
            .accessibilityLabel(title)
            .onHover { hover(.action(title), inside: $0) }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private func optionIcon(_ symbol: String, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        optionButton(title, selected: selected, action: action) {
            Image(systemName: symbol).font(.system(size: 15))
        }
    }

    private func optionButton<Label: View>(
        _ title: String,
        hoverText: String? = nil,
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().frame(width: 28, height: 26)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hoverText ?? title)
        .onHover { hover(.action(hoverText ?? title), inside: $0) }
    }

    // MARK: - Tool options

    private struct TextSizeChoice: Identifiable {
        let scale: CGFloat
        let name: String
        var id: CGFloat { scale }
    }

    private static let textSizeChoices = [
        TextSizeChoice(scale: 0.016, name: t("Small")),
        TextSizeChoice(scale: 0.022, name: t("Medium")),
        TextSizeChoice(scale: 0.030, name: t("Large")),
    ]

    private var arrowSymbol: String {
        switch session.defaultStyle.arrowStyle {
        case .straight: return "arrow.right"
        case .curved: return "arrow.up.right"
        case .elbow: return "arrow.turn.right.down"
        case .sCurve: return "arrow.up.forward"
        }
    }

    private var watermarkChip: some View {
        let open = session.showsWatermarkBar
        return Button {
            session.showsWatermarkBar.toggle()
        } label: {
            Image(systemName: "signature")
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(watermarkChipFill(open: open))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(open ? Color.accentColor.opacity(0.6) : Color.clear)
            )
            .foregroundStyle(open || session.watermarkEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Watermark settings"))
        .onHover { hover(.action(t("Watermark settings")), inside: $0) }
    }

    private func watermarkChipFill(open: Bool) -> Color {
        if open { return Color.accentColor.opacity(0.28) }
        return session.watermarkEnabled ? Color.accentColor.opacity(0.14) : Color.clear
    }

    // MARK: - Watermark submenu

    private var watermarkBar: some View {
        WatermarkBar(session: session, popoverPlacement: popoverPlacement) { text, inside in
            hover(.action(text), inside: inside)
        }
    }

    private func icon(
        _ symbol: String,
        hint: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .accessibilityLabel(hint)
        .onHover { hover(.action(hint), inside: $0) }
    }

    private func primaryIcon(
        _ symbol: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint)
        .onHover { hover(.action(hint), inside: $0) }
    }

    /// One extension's item: a plain button when it has a single entry, a
    /// popover with one button per entry when it has several. A pop-up menu can
    /// open behind the capture overlay, so this uses the same popover pattern
    /// as the watermark settings.
    @ViewBuilder
    private func captureActionView(_ entry: CaptureExtensionToolbarEntry) -> some View {
        let item = entry.item
        let enabled = session.captureActionsAllowed && session.annotations.isEmpty
        Group {
            if let only = item.entries.first, item.entries.count == 1 {
                Button {
                    onCaptureAction(entry.id, only.id)
                } label: {
                    captureActionImage(item)
                }
            } else {
                Button {
                    openExtensionPopover = entry.id
                } label: {
                    captureActionImage(item)
                }
                .popover(
                    isPresented: Binding(
                        get: { openExtensionPopover == entry.id },
                        set: { openExtensionPopover = $0 ? entry.id : nil }
                    ),
                    arrowEdge: popoverPlacement.edge
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(item.entries) { choice in
                            Button {
                                openExtensionPopover = nil
                                onCaptureAction(entry.id, choice.id)
                            } label: {
                                Text(verbatim: choice.title)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .onHover { hover(.action(item.help ?? item.title), inside: $0) }
        .accessibilityLabel(Text(verbatim: item.accessibilityLabel ?? item.title))
    }

    /// The image shared by the button and the popover trigger, sized like `icon(...)`.
    private func captureActionImage(_ item: CaptureToolbarItem) -> some View {
        Image(systemName: item.systemImage)
            .font(.system(size: 12.5, weight: .medium))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
}

/// The watermark submenu that replaces the options row. It edits the session
/// directly; the settings that do not fit on one 26pt line stay in
/// `WatermarkSettingsView` behind "More…".
struct WatermarkBar: View {
    @ObservedObject var session: CaptureSession
    @ObservedObject var popoverPlacement = ToolbarPopoverPlacement()
    var onHover: (String, Bool) -> Void = { _, _ in }
    @State private var showColors = false
    @State private var showMore = false

    var body: some View {
        HStack(spacing: 6) {
            enabledToggle

            Divider().frame(height: 18)

            placementControls
                .disabled(!session.watermarkEnabled)
                .opacity(session.watermarkEnabled ? 1 : 0.4)

            Divider().frame(height: 18)

            sizeControl
                .disabled(!session.watermarkEnabled)
                .opacity(session.watermarkEnabled ? 1 : 0.4)

            Divider().frame(height: 18)

            colorButton
                .disabled(!session.watermarkEnabled)
                .opacity(session.watermarkEnabled ? 1 : 0.4)

            Divider().frame(height: 18)

            moreButton
        }
    }

    private var enabledToggle: some View {
        Toggle(t("Watermark"), isOn: session.watermarkEnabledBinding)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10.5, weight: .medium))
            .onHover { onHover(t("Watermark"), $0) }
    }

    private var placementControls: some View {
        HStack(spacing: 4) {
            WatermarkPlacementPicker(
                placement: $session.watermarkPlacement,
                onHover: { placement, inside in onHover(placement.title, inside) }
            )
            iconButton(
                "square.grid.3x3",
                t("Tiled"),
                selected: session.watermarkPlacement == .tiled
            ) {
                session.watermarkPlacement = .tiled
            }
        }
    }

    private var sizeControl: some View {
        HStack(spacing: 4) {
            Slider(value: $session.watermarkScale, in: ScreenshotPreferences.watermarkScaleRange)
                .controlSize(.mini)
                .frame(width: 72)
                .accessibilityLabel(t("Size"))
                .onHover { onHover(t("Size"), $0) }
            Text(String(format: "%.1f%%", Double(session.watermarkScale) * 100))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var colorButton: some View {
        Button { showColors.toggle() } label: {
            Circle().fill(session.watermarkColor).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Color"))
        .onHover { onHover(t("Color"), $0) }
        .popover(isPresented: $showColors, arrowEdge: popoverPlacement.edge) {
            ColorPalettePopover(
                target: session.watermarkColorPalette,
                onPick: { showColors = false },
                onHover: onHover
            )
        }
    }

    private var moreButton: some View {
        iconButton("ellipsis.circle", t("More…"), selected: showMore) {
            showMore.toggle()
        }
        .popover(isPresented: $showMore, arrowEdge: popoverPlacement.edge) {
            WatermarkSettingsView(session: session)
        }
    }

    private func iconButton(
        _ symbol: String,
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15))
                .frame(width: 28, height: 26)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { onHover(title, $0) }
    }
}

/// The colour popover shared by the annotation toolbar and the watermark
/// submenu: the presets and recent colours, then the hex card and channel
/// sliders on their own page.
private struct ColorPalettePopover: View {
    let target: ColorPaletteTarget
    var onPick: () -> Void = {}
    var onHover: (String, Bool) -> Void = { _, _ in }
    @State private var tab: Tab = .swatches

    private enum Tab: Hashable {
        case swatches
        case custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tab {
            case .swatches: swatches
            case .custom: ColorCustomTab(target: target)
            }

            Divider()

            Picker("", selection: $tab) {
                Text(t("Swatches")).tag(Tab.swatches)
                Text(t("Custom")).tag(Tab.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(width: 142)
        .padding(12)
    }

    @ViewBuilder private var swatches: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 5),
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(AnnotationPalette.presets) { swatch in
                colorSwatch(swatch)
            }
        }

        if !target.recentColors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Recently Used"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(target.recentColors, id: \.self) { hex in
                        recentSwatch(hex)
                    }
                }
            }
        }
    }

    private func colorSwatch(_ swatch: AnnotationPalette.Swatch) -> some View {
        AnnotationColorSwatch(
            color: swatch.color,
            name: swatch.name,
            selected: AnnotationPalette.hex(for: target.color.wrappedValue) == swatch.hex,
            diameter: 22
        ) {
            target.color.wrappedValue = swatch.color
            onPick()
        }
        .onHover { onHover(swatch.name, $0) }
    }

    private func recentSwatch(_ hex: String) -> some View {
        let color = AnnotationPalette.color(fromHex: hex) ?? .black
        return AnnotationColorSwatch(
            color: color,
            name: hex,
            selected: AnnotationPalette.hex(for: target.color.wrappedValue) == hex,
            diameter: 22
        ) {
            target.color.wrappedValue = color
            target.remember(hex)
            onPick()
        }
        .onHover { onHover(hex, $0) }
    }
}

/// The popover's custom page: preview, hex field and one slider per channel.
/// Edits apply while dragging; a slider drag is one undo step, and the recent
/// list is only written once the value is final.
private struct ColorCustomTab: View {
    let target: ColorPaletteTarget
    @State private var hexText = ""
    @FocusState private var hexFocused: Bool
    @State private var hexEdited = false
    @State private var copied = false
    @State private var copyTask: Task<Void, Never>?

    private var currentHex: String {
        AnnotationPalette.hex(for: target.color.wrappedValue) ?? "#000000"
    }

    private var components: AnnotationPalette.RGB {
        AnnotationPalette.rgb(for: target.color.wrappedValue) ?? .init(red: 0, green: 0, blue: 0)
    }

    /// The card is both the preview and the hex field: the value appears once,
    /// on the colour it describes.
    private var ink: Color {
        AnnotationPalette.prefersDarkText(on: target.color.wrappedValue) ? .black : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hexCard
            ChannelSlider(
                label: "R",
                tint: .red,
                value: channelBinding(\.red),
                valueText: "\(components.red)",
                onEditingChanged: channelEditingChanged
            )
            ChannelSlider(
                label: "G",
                tint: .green,
                value: channelBinding(\.green),
                valueText: "\(components.green)",
                onEditingChanged: channelEditingChanged
            )
            ChannelSlider(
                label: "B",
                tint: .blue,
                value: channelBinding(\.blue),
                valueText: "\(components.blue)",
                onEditingChanged: channelEditingChanged
            )
        }
        .onAppear { hexText = currentHex }
        .onDisappear { copyTask?.cancel() }
    }

    private var hexCard: some View {
        TextField("", text: $hexText)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(ink)
            .tint(ink)
            .padding(.horizontal, 30)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(target.color.wrappedValue)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        hexFocused ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: hexFocused ? 2 : 1
                    )
            }
            .overlay(alignment: .trailing) {
                copyButton.padding(.trailing, 6)
            }
            .focused($hexFocused)
            .onSubmit { commitHex() }
            .onChange(of: hexText) { _, text in
                guard hexFocused,
                      let canonical = AnnotationPalette.canonicalHex(text),
                      let color = AnnotationPalette.color(fromHex: canonical)
                else { return }
                hexEdited = canonical != currentHex
                target.color.wrappedValue = color
            }
            .onChange(of: hexFocused) { _, focused in
                if focused {
                    hexText = currentHex
                    hexEdited = false
                } else {
                    commitHex()
                }
            }
            .onChange(of: currentHex) { _, hex in
                guard !hexFocused else { return }
                hexText = hex
            }
            .accessibilityLabel(t("Hex colour"))
    }

    /// Copies without touching the field: selecting the code to copy left the
    /// whole card highlighted, which read as editing rather than copying.
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(currentHex, forType: .string)
            copied = true
            copyTask?.cancel()
            copyTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.9))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t("Copy hex colour"))
        .accessibilityLabel(t("Copy hex colour"))
    }

    /// An incomplete or malformed hex applies nothing and shows no error; on
    /// leaving the field the text goes back to the colour in use.
    private func commitHex() {
        if hexEdited, let color = AnnotationPalette.color(fromHex: hexText) {
            target.color.wrappedValue = color
            if let hex = AnnotationPalette.hex(for: color) {
                target.remember(hex)
            }
        }
        hexEdited = false
        hexText = currentHex
    }

    private func channelEditingChanged(_ editing: Bool) {
        if editing {
            // The drag does not take focus from the field. Left focused, it
            // stops following the sliders and its stale text is replayed on the
            // next submit or blur, undoing the drag.
            if hexFocused {
                commitHex()
                hexFocused = false
            }
            target.beginInteractiveChange()
        } else {
            target.endInteractiveChange()
            if let hex = AnnotationPalette.hex(for: target.color.wrappedValue) {
                target.remember(hex)
            }
        }
    }

    private func channelBinding(
        _ keyPath: WritableKeyPath<AnnotationPalette.RGB, Int>
    ) -> Binding<Double> {
        Binding(
            get: { Double(components[keyPath: keyPath]) },
            set: { value in
                var updated = components
                updated[keyPath: keyPath] = min(255, max(0, Int(value.rounded())))
                target.color.wrappedValue = AnnotationPalette.color(updated)
            }
        )
    }
}

/// A one-channel slider whose track shows the channel ramp. A native mini
/// Slider draws a monochrome track, so its tint never reached the popover.
private struct ChannelSlider: View {
    let label: String
    let tint: Color
    @Binding var value: Double
    let valueText: String
    let onEditingChanged: (Bool) -> Void

    @State private var dragging = false

    private let knob: CGFloat = 12
    private let trackHeight: CGFloat = 4

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .leading)

            GeometryReader { proxy in
                let travel = max(1, proxy.size.width - knob)
                let fraction = min(1, max(0, value / 255))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.black, tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: trackHeight)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.22)))
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: travel * fraction)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !dragging {
                                dragging = true
                                onEditingChanged(true)
                            }
                            let x = min(travel, max(0, gesture.location.x - knob / 2))
                            value = (x / travel * 255).rounded()
                        }
                        .onEnded { _ in
                            dragging = false
                            onEditingChanged(false)
                        }
                )
            }
            .frame(height: 16)

            Text(valueText)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(255, value + 5)
            case .decrement: value = max(0, value - 5)
            @unknown default: break
            }
        }
    }
}

/// The hint band is decoration: clicks and drags there belong to the selection
/// view underneath, so the hosting view drops them before any SwiftUI button
/// could claim them.
final class CaptureToolbarHost: NSHostingView<CaptureToolbarView> {
    /// One cursor over the whole capture surface: the buttons keep the
    /// crosshair, and a rect here is also what resets a cursor the drawing
    /// view set further out.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isInHintBand(point) else { return nil }
        return super.hitTest(point)
    }

    /// `point` is in the superview's coordinate space, like `hitTest(_:)`.
    func isInHintBand(_ point: NSPoint) -> Bool {
        hintBandRect.contains(convert(point, from: superview))
    }

    var hintBandRect: NSRect {
        let height = min(CaptureToolbarView.hintBandHeight, bounds.height)
        let atBottom = rootView.popoverPlacement.edge == .top
        return isFlipped
            ? NSRect(x: 0, y: atBottom ? bounds.maxY - height : 0, width: bounds.width, height: height)
            : NSRect(x: 0, y: atBottom ? bounds.minY : bounds.maxY - height, width: bounds.width, height: height)
    }
}

private struct WatermarkSettingsView: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Watermark"))
                .font(.headline)

            Toggle(t("Show watermark"), isOn: session.watermarkEnabledBinding)

            Toggle(t("Hide watermark"), isOn: $session.watermarkHidden)
                .disabled(!session.watermarkEnabled)

            Divider()

            TextField(t("Watermark text"), text: $session.watermarkText)
                .textFieldStyle(.roundedBorder)

            Picker(t("Position"), selection: $session.watermarkPlacement) {
                ForEach(AnnotationRenderer.WatermarkOptions.Placement.allCases) { placement in
                    Label(placement.title, systemImage: placement.symbol).tag(placement)
                }
            }
            .pickerStyle(.menu)

            sliderRow(
                t("Size"),
                value: $session.watermarkScale,
                range: ScreenshotPreferences.watermarkScaleRange,
                text: String(format: "%.1f%%", session.watermarkScale * 100)
            )

            sliderRow(
                t("Angle"),
                value: $session.watermarkRotation,
                range: ScreenshotPreferences.watermarkRotationRange,
                text: "\(Int(session.watermarkRotation))°"
            )

            sliderRow(
                t("Opacity"),
                value: $session.watermarkOpacity,
                range: ScreenshotPreferences.watermarkOpacityRange,
                text: "\(Int(session.watermarkOpacity * 100))%"
            )

            HStack(alignment: .top, spacing: 8) {
                Text(t("Color"))
                    .frame(width: 54, alignment: .leading)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(16), spacing: 6), count: 5),
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(AnnotationPalette.presets) { swatch in
                            AnnotationColorSwatch(
                                color: swatch.color,
                                name: swatch.name,
                                selected: AnnotationPalette.hex(for: session.watermarkColor) == swatch.hex,
                                diameter: 16
                            ) {
                                session.watermarkColor = swatch.color
                            }
                        }
                    }

                    if !session.recentAnnotationColors.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(session.recentAnnotationColors, id: \.self) { hex in
                                let color = AnnotationPalette.color(fromHex: hex) ?? .black
                                AnnotationColorSwatch(
                                    color: color,
                                    name: hex,
                                    selected: AnnotationPalette.hex(for: session.watermarkColor) == hex,
                                    diameter: 16
                                ) {
                                    session.watermarkColor = color
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func sizeButton(_ scale: CGFloat, _ title: String) -> some View {
        Button(title) {
            session.watermarkScale = scale
        }
        .buttonStyle(.bordered)
        .tint(session.watermarkScale == scale ? .accentColor : nil)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        text: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 54, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

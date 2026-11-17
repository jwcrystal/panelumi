import AppKit
import SwiftUI
import SwitchKit

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
        }
    }
    @Published var selectionIndex: Int?
    @Published var toolbarVisible = true
    @Published var defaultStyle = AnnotationStyle()
    @Published var annotations: [Annotation] = [] {
        didSet { refreshHistoryAvailability() }
    }
    @Published var watermarkEnabled = ScreenshotPreferences.watermarkOnByDefault
    @Published var watermarkHidden = false
    @Published var watermarkPlacement: AnnotationRenderer.WatermarkOptions.Placement = .bottomRight
    @Published var watermarkScale: CGFloat = 0.02
    @Published var watermarkRotation: CGFloat = 0
    @Published var watermarkOpacity: CGFloat = 0.6
    @Published var watermarkColor: Color = .white

    @Published var watermarkText: String = ScreenshotPreferences.defaultWatermarkText

    /// Every capture starts from Settings › Screenshot rather than from
    /// whatever the previous screenshot left behind.
    func prepareForCapture() {
        watermarkEnabled = ScreenshotPreferences.watermarkOnByDefault
        let stored = ScreenshotPreferences.watermarkText
        watermarkText = stored.isEmpty ? ScreenshotPreferences.defaultWatermarkText : stored
        watermarkHidden = false
        toolbarVisible = true
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

struct CaptureToolbarView: View {
    @ObservedObject var session: CaptureSession
    @State private var showWatermarkSettings = false
    @State private var showColors = false
    @State private var hovered: HoverItem?

    /// Height of the strip above the pill that names what the pointer is on.
    /// The hosting view's hit test uses the same value.
    static let hintBandHeight: CGFloat = 24

    private enum HoverItem: Equatable {
        case tool(CaptureSession.Tool)
        case action(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            hintBand
            mainRow
            optionsRow
        }
        .fixedSize()
    }

    private var hintText: String {
        switch hovered {
        case .tool(let tool): return "\(tool.title)  \(tool.shortcut)"
        case .action(let text): return text
        case nil: return t("↩ Copy · Space Save · P Pin · ⌘Z Undo · ⇥ Hide · Esc Close")
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
            ForEach(CaptureSession.Tool.allCases) { tool in
                toolButton(tool)
            }

            Divider().frame(height: 18)

            watermarkChip

            Divider().frame(height: 18)

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
            session.tool = tool
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

    private var optionsRow: some View {
        HStack(spacing: 5) {
            if showsColorSwatch {
                colorButton
                Divider().frame(height: 18)
            }
            toolOptions
        }
        .frame(height: 26)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 7, y: 3)
    }

    private var showsColorSwatch: Bool {
        switch session.displayTool {
        case .select, .mosaic, .blur: return false
        default: return true
        }
    }

    private var colorButton: some View {
        Button { showColors.toggle() } label: {
            Circle().fill(session.activeStyle.color).frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Annotation color"))
        .onHover { hover(.action(t("Color")), inside: $0) }
        .popover(isPresented: $showColors, arrowEdge: .bottom) {
            HStack(spacing: 9) {
                ForEach(Annotation.palette, id: \.self) { color in
                    Button { session.activeStyle.color = color; showColors = false } label: {
                        Circle().fill(color).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(session.activeStyle.color == color ? 0.7 : 0.15), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.description)
                }
            }.padding(12)
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
            lineWidthSlider
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
            Text(t("Select an annotation to adjust its style"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var lineWidthSlider: some View {
        HStack(spacing: 3) {
            Divider().frame(height: 18)
            Image(systemName: "lineweight").frame(width: 23)
            optionSlider(
                t("Line width"),
                value: session.styleBinding(\.lineWidth),
                range: 0.0015...0.016,
                text: "\(Self.lineWidthLevel(for: session.activeStyle.lineWidth))"
            )
        }
    }

    /// Display-only 1…10 step for the stored width; what is stored keeps its
    /// 0.0015…0.016 range.
    static func lineWidthLevel(for width: CGFloat) -> Int {
        let step = (0.016 - 0.0015) / 9
        let level = ((width - 0.0015) / step).rounded() + 1
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
        Button {
            showWatermarkSettings.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "signature")
                    .font(.system(size: 12.5, weight: .medium))
                Text(t("Watermark"))
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(session.watermarkEnabled ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .foregroundStyle(session.watermarkEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Watermark settings"))
        .onHover { hover(.action(t("Watermark settings")), inside: $0) }
        .popover(isPresented: $showWatermarkSettings, arrowEdge: .bottom) {
            WatermarkSettingsView(session: session)
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
}

/// The hint band is decoration: clicks and drags there belong to the selection
/// view underneath, so the hosting view drops them before any SwiftUI button
/// could claim them.
final class CaptureToolbarHost: NSHostingView<CaptureToolbarView> {
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
        return isFlipped
            ? NSRect(x: 0, y: 0, width: bounds.width, height: height)
            : NSRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
    }
}

private struct WatermarkSettingsView: View {
    @ObservedObject var session: CaptureSession

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { session.watermarkEnabled },
            set: { enabled in
                session.watermarkEnabled = enabled
                if !enabled { session.watermarkHidden = false }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Watermark"))
                .font(.headline)

            Toggle(t("Show watermark"), isOn: enabledBinding)

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
                range: 0.01...0.06,
                text: String(format: "%.1f%%", session.watermarkScale * 100)
            )

            sliderRow(
                t("Angle"),
                value: $session.watermarkRotation,
                range: -90...90,
                text: "\(Int(session.watermarkRotation))°"
            )

            sliderRow(
                t("Opacity"),
                value: $session.watermarkOpacity,
                range: 0.15...1,
                text: "\(Int(session.watermarkOpacity * 100))%"
            )

            HStack(spacing: 8) {
                Text(t("Color"))
                    .frame(width: 54, alignment: .leading)
                    .foregroundStyle(.secondary)

                ForEach(Self.palette, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().strokeBorder(
                                Color.primary.opacity(session.watermarkColor == color ? 0.6 : 0.12),
                                lineWidth: 2
                            )
                        }
                        .padding(2)
                        .contentShape(Circle())
                        .onTapGesture { session.watermarkColor = color }
                }
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private static let palette: [Color] = [.white, .black, .red, .yellow, .blue]

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

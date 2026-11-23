import AppKit
import PanelumiKit

/// Options for starting the app. A hook for packages that embed the app; more
/// fields can be added later without changing the call.
public struct LaunchOptions: Equatable, Sendable {
    /// Update feed, links and support folder the app uses.
    public var identity: AppIdentity
    /// Extensions for the capture toolbar. Empty by default; with none, capture behaves as before.
    public var captureExtensions: [any CaptureExtension]
    /// Providers of extra status-bar menu rows. Empty by default; with none, the menu is unchanged.
    public var menuItemProviders: [any MenuItemProvider]
    /// Providers of extra Settings pages. Empty by default; with none, the window is unchanged.
    public var settingsPageProviders: [any SettingsPageProvider]

    public init(
        identity: AppIdentity = .standard,
        captureExtensions: [any CaptureExtension] = [],
        menuItemProviders: [any MenuItemProvider] = [],
        settingsPageProviders: [any SettingsPageProvider] = []
    ) {
        self.identity = identity
        self.captureExtensions = captureExtensions
        self.menuItemProviders = menuItemProviders
        self.settingsPageProviders = settingsPageProviders
    }

    /// Two options are equal when they share an identity and list the same
    /// extension, menu item and settings page provider identifiers in the
    /// same order.
    public static func == (lhs: LaunchOptions, rhs: LaunchOptions) -> Bool {
        lhs.identity == rhs.identity
            && lhs.captureExtensions.map(\.identifier) == rhs.captureExtensions.map(\.identifier)
            && lhs.menuItemProviders.map(\.identifier) == rhs.menuItemProviders.map(\.identifier)
            && lhs.settingsPageProviders.map(\.identifier) == rhs.settingsPageProviders.map(\.identifier)
    }
}

/// Entry point of the app, called by the `Panelumi` executable.
///
/// The app is a menu-bar accessory: no Dock icon, no main menu.
public enum PanelumiLauncher {
    /// Reads the process arguments, then either runs one diagnostic command
    /// (`--dump`, `--menu`, `--capture-test`, …) or starts the app.
    ///
    /// Call it once per process, on the main thread. Starting the app never
    /// returns, and some diagnostic commands end the process with `exit()`.
    @MainActor
    public static func run(_ options: LaunchOptions = LaunchOptions()) {
        AppIdentity.current = options.identity
        let arguments = CommandLine.arguments

        if arguments.contains("--dump") {
            Dump.printAll()
            return
        }

        if let index = arguments.firstIndex(of: "--run"), arguments.count > index + 1 {
            Dump.run(id: arguments[index + 1], itemProviders: options.menuItemProviders)
            return
        }

        if arguments.contains("--hotkeys") {
            Dump.checkHotkeys(itemProviders: options.menuItemProviders)
            return
        }

        if arguments.contains("--menu") {
            Dump.printMenu(itemProviders: options.menuItemProviders)
            return
        }

        if arguments.contains("--permissions") {
            Dump.printPermissions()
            return
        }

        if arguments.contains("--audio-inputs") {
            Dump.printAudioInputs()
            return
        }

        if arguments.contains("--probe-automation") {
            Dump.probeAutomation()
            return
        }

        if arguments.contains("--capture-test") {
            Dump.captureTest()
            return
        }

        if arguments.contains("--window-check") {
            Dump.windowCheck()
            return
        }

        if arguments.contains("--window-capture-test") {
            Dump.windowCaptureTest()
            return
        }

        if arguments.contains("--region-bench") {
            Dump.regionBench()
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate(
            captureExtensions: options.captureExtensions,
            menuItemProviders: options.menuItemProviders,
            settingsPageProviders: options.settingsPageProviders
        )
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

/// Prints every switch with its current state. Used by `scripts/smoke.sh` and
/// helpful when a switch misbehaves: `build/Panelumi.app/Contents/MacOS/Panelumi --dump`.
enum Dump {
    @MainActor
    static func printAll() {
        let screenshot = ScreenshotCoordinator()
        defer { withExtendedLifetime(screenshot) {} }
        for item in AppCatalog.make(screenshot: screenshot).items {
            print(line(for: item))
        }
    }

    /// Runs one switch without opening the menu: `--run keepAwake`.
    /// Toggles flip state, so the printed state afterwards shows the result.
    /// Rows added by menu item providers can be run by id too.
    @MainActor
    static func run(id: String, itemProviders: [any MenuItemProvider] = []) {
        // The screenshot switches hold the coordinator weakly, so it has to
        // outlive perform() or they silently do nothing.
        let screenshot = ScreenshotCoordinator()
        defer { withExtendedLifetime(screenshot) {} }
        let outcome: Result<String, RunFailure> = withScratchModel(
            catalog: AppCatalog.make(screenshot: screenshot),
            itemProviders: itemProviders
        ) { model in
            let item: SwitchItem
            switch resolveRunTarget(id: id, model: model) {
            case .success(let found):
                item = found
            case .failure(.unknown):
                return .failure(RunFailure(message: "Unknown switch: \(id)", exitCode: 2))
            case .failure(.disabled(let title)):
                return .failure(RunFailure(message: "\(title) is not available right now.", exitCode: 1))
            }
            do {
                try item.perform()
            } catch {
                return .failure(RunFailure(message: "\(item.title) failed: \(error.localizedDescription)", exitCode: 1))
            }
            return .success(line(for: item))
        }
        switch outcome {
        case .success(let output):
            print(output)
        case .failure(let failure):
            FileHandle.standardError.write(Data("\(failure.message)\n".utf8))
            exit(failure.exitCode)
        }
    }

    struct RunFailure: Error {
        let message: String
        let exitCode: Int32
    }

    /// Builds a model on a throwaway copy of the user's config so a short-lived
    /// dump process never writes the real file: `AppModel.init` seeds the
    /// default screenshot shortcut on a fresh profile, which would be saved.
    /// The copy marks the seed as done and carries the user's switches, order
    /// and shortcuts, so `--menu` still describes the real menu. The copy is
    /// removed before this returns, so callers may `exit` afterwards.
    @MainActor
    static func withScratchModel<T>(
        source: URL = ConfigStore.defaultURL(),
        catalog: SwitchCatalog,
        itemProviders: [any MenuItemProvider],
        _ body: (AppModel) -> T
    ) -> T {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("panelumi-dump-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var copy = ConfigStore(url: source).config
        copy.didSeedScreenshotShortcut = true
        let store = ConfigStore(url: url)
        store.update { $0 = copy }
        return body(AppModel(catalog: catalog, store: store, itemProviders: itemProviders))
    }

    enum RunTargetError: Error, Equatable {
        case unknown
        case disabled(title: String)
    }

    /// Built-in switches first, hidden ones included, because `--run` never
    /// depended on the menu. Then the rows providers add, under the menu's rules.
    /// A provider row that reports itself disabled is refused, as in the menu.
    @MainActor
    static func resolveRunTarget(id: String, model: AppModel) -> Result<SwitchItem, RunTargetError> {
        if let builtIn = model.catalog.item(id: id) {
            return .success(builtIn)
        }
        guard let injected = model.menuItems.first(where: { $0.id == id }) else {
            return .failure(.unknown)
        }
        return injected.isEnabled() ? .success(injected) : .failure(.disabled(title: injected.title))
    }

    private static func line(for item: SwitchItem) -> String {
        let state: String
        switch item.kind {
        case .toggle: state = item.state() ? "on" : "off"
        case .action: state = "-"
        }
        let subtitle = item.subtitle().map { " (\($0))" } ?? ""
        return "\(item.id)\t\(item.title)\t\(state)\(subtitle)"
    }

    /// Prints the menu exactly as the status item builds it, including hidden
    /// switches being absent. Useful when the menu looks wrong.
    @MainActor
    static func printMenu(itemProviders: [any MenuItemProvider] = []) {
        let screenshot = ScreenshotCoordinator()
        defer { withExtendedLifetime(screenshot) {} }
        let lines = withScratchModel(catalog: AppCatalog.make(screenshot: screenshot), itemProviders: itemProviders) {
            menuLines(model: $0)
        }
        for line in lines { print(line) }
    }

    /// The lines `--menu` prints: a header, then one line per row in menu order.
    /// Each row shows the shortcut saved for its id, added rows included.
    @MainActor
    static func menuLines(model: AppModel) -> [String] {
        var seen = Set<String>()
        let items = model.menuItems.filter { seen.insert($0.id).inserted }
        let builtIn = items.filter { model.catalog.item(id: $0.id) != nil }.count

        var lines = ["menu items: \(items.count) (\(builtIn) of \(model.catalog.items.count) switches, \(model.config.disabled.count) hidden; \(items.count - builtIn) added)"]
        for (index, item) in items.enumerated() {
            var parts = [item.title]
            if let subtitle = item.subtitle() { parts.append("(\(subtitle))") }
            let shortcut = model.shortcutLabel(for: item.id)
            if let shortcut { parts.append("[\(shortcut)]") }
            lines.append(String(format: "%2d", index + 1) + " " + parts.joined(separator: " "))
        }
        return lines
    }

    /// Prints the permission state the app itself sees. Also writes
    /// `/tmp/panelumi-permissions.txt` for a GUI launch.
    @MainActor
    static func printPermissions() {
        let center = PermissionCenter()
        center.refresh()

        func label(_ state: PermissionCenter.AutomationState) -> String {
            switch state {
            case .granted: return "granted"
            case .denied: return "missing"
            case .unknown: return "unknown"
            }
        }

        var lines = [
            "accessibility\t\(center.accessibility ? "granted" : "missing")",
            "screenRecording\t\(center.screenRecording ? "granted" : "missing")",
            "screenRecording:relaunchNeeded\t\(center.screenRecordingRelaunchNeeded ? "yes" : "no")",
            "automation:systemEvents\t\(label(center.systemEvents))",
            "automation:finder\t\(label(center.finder))",
        ]

        switch center.microphone {
        case .authorized: lines.append("microphone\tgranted")
        case .notDetermined: lines.append("microphone\tnot asked")
        case .denied: lines.append("microphone\tmissing")
        case .restricted: lines.append("microphone\trestricted")
        @unknown default: lines.append("microphone\tunknown")
        }
        lines.append("allGranted\t\(center.allGranted)")

        for line in lines { print(line) }
        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/panelumi-permissions.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Lists the microphones CoreAudio offers, marking the default. Used to
    /// check the Settings › Recording picker without opening the window.
    static func printAudioInputs() {
        let devices = AudioInput.devices()
        for device in devices {
            print("\(device.id)\t\(device.name)\(device.isDefault ? "\t(default)" : "")")
        }
        if devices.isEmpty { print("no input devices") }
    }

    /// Sends one harmless event per target, the same call the Grant button
    /// makes, and prints what macOS answered. Also writes the same lines to
    /// `/tmp/panelumi-probe.txt`, because a GUI launch has no stdout.
    @MainActor
    static func probeAutomation() {
        let targets = [
            ("System Events", #"tell application "System Events" to get name"#),
            ("Finder", #"tell application "Finder" to get name of startup disk"#),
        ]

        var lines: [String] = []
        for (name, script) in targets {
            do {
                let result = try Automation.run(script)
                lines.append("\(name)\tok\t\(result.stringValue ?? "")")
            } catch {
                lines.append("\(name)\tfailed\t\(error.localizedDescription)")
            }
        }

        for line in lines {
            print(line)
        }
        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/panelumi-probe.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Captures the main display to /tmp and writes the outcome next to it.
    /// Verifies ScreenCaptureKit and the Screen Recording grant without any UI.
    @MainActor
    static func captureTest() {
        let service = ScreenCaptureService()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()

        func write(_ text: String) {
            print(text)
            try? text.write(
                to: URL(fileURLWithPath: "/tmp/panelumi-capture.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        Task {
            do {
                let image = try await service.captureDisplay(displayID: displayID)
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "/tmp/panelumi-capture.png"))
                }
                write("ok \(image.width)x\(image.height)")
            } catch {
                write("failed \(error.localizedDescription)")
            }
            exit(0)
        }

        RunLoop.main.run()
    }

    /// Debug: times single-region captures.
    @MainActor
    static func regionBench() {
        let service = ScreenCaptureService()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let rect = CGRect(
            x: screen.frame.midX - 300,
            y: screen.frame.midY - 200,
            width: 600,
            height: 400
        )

        Task {
            // First call warms the shareable-content cache; time the rest.
            _ = try? await service.captureRegion(
                displayID: displayID, rect: rect, screenFrame: screen.frame,
                excludingWindowIDs: SelectionController.overlayWindowIDs
            )

            var size = CGSize.zero
            var failures = 0
            let start = Date()
            for _ in 0..<10 {
                if let image = try? await service.captureRegion(
                    displayID: displayID, rect: rect, screenFrame: screen.frame,
                    excludingWindowIDs: SelectionController.overlayWindowIDs
                ) {
                    size = CGSize(width: image.width, height: image.height)
                } else {
                    failures += 1
                }
            }
            let ms = Date().timeIntervalSince(start) * 100
            print("region \(Int(rect.width))x\(Int(rect.height)) pts → \(Int(size.width))x\(Int(size.height)) px, \(String(format: "%.0f", ms)) ms/frame, \(failures) failures")
            exit(0)
        }

        RunLoop.main.run()
    }

    /// Prints the window a pick would land on under the mouse, using the same
    /// coordinate conversion and layer rule as the selection overlay.
    @MainActor
    static func windowCheck() {
        let mouse = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            print("no primary screen")
            return
        }
        let topLeft = CGPoint(x: mouse.x, y: primary.frame.height - mouse.y)
        print("mouse=\(mouse) cg=\(topLeft)")

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let excluded = SelectionController.overlayWindowIDs

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !excluded.contains(id),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  WindowPick.isPickable(layer: layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict)
            else { continue }
            let minimum = WindowPick.minimumSize(layer: layer)
            guard rect.width >= minimum, rect.height >= minimum, rect.contains(topLeft) else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            if WindowPick.isDock(layer: layer) {
                // The Dock's window is the whole display; the pick is its strip.
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? primary
                let strip = WindowPick.dockStrip(frame: screen.frame, visible: screen.visibleFrame)
                print("hit owner=\(owner) id=\(id) pid=\(pid) layer=\(layer) source=dock strip bounds=\(String(describing: strip))")
                return
            }
            let source = WindowPick.isFrozenOnly(layer: layer) ? "frozen frame" : "live window"
            print("hit owner=\(owner) id=\(id) pid=\(pid) layer=\(layer) source=\(source) bounds=\(rect)")
            return
        }
        print("no window at cursor")
    }

    /// Captures the window under the pointer exactly as a click would, composes
    /// it with the editor shadow and writes /tmp/panelumi-window.png and
    /// /tmp/panelumi-composed.png.
    @MainActor
    static func windowCaptureTest() {
        let mouse = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        else {
            print("no screen")
            return
        }

        let topLeft = CGPoint(x: mouse.x, y: primary.frame.height - mouse.y)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let excluded = SelectionController.overlayWindowIDs

        guard let info = list.first(where: { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !excluded.contains(id),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  WindowPick.isPickable(layer: layer),
                  // This debug path captures live windows only: it holds no
                  // frozen frame, so a high-layer pick would have nothing to
                  // cut its pixels from.
                  !WindowPick.isFrozenOnly(layer: layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict)
            else { return false }
            return rect.width >= 60 && rect.height >= 60 && rect.contains(topLeft)
        }),
        let dict = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: dict),
        let id = info[kCGWindowNumber as String] as? CGWindowID
        else {
            print("no window at cursor")
            return
        }

        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: (primary.frame.height - rect.maxY) - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
        let target = CaptureWindowTarget(id: id, rect: local)
        guard let canvas = WindowComposer.canvas(
            for: [target],
            screenBounds: CGRect(origin: .zero, size: screen.frame.size)
        ) else {
            print("no canvas")
            return
        }

        Task {
            do {
                let image = try await ScreenCaptureService().captureWindow(windowID: id)
                let composed = WindowComposer.compose(
                    shots: [(image, local)],
                    canvas: canvas,
                    scale: screen.backingScaleFactor
                )

                for (name, cg) in [("window", image), ("composed", composed)] {
                    guard let cg else { continue }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/panelumi-\(name).png"))
                    }
                    print("\(name) \(cg.width)x\(cg.height)")
                }
                print("window id=\(id) local=\(local) canvas=\(canvas)")
            } catch {
                print("failed \(error.localizedDescription)")
            }
            exit(0)
        }

        RunLoop.main.run()
    }

    /// Registers a probe shortcut through the real Carbon path and reports the
    /// result. Uses a throwaway config file so the user's shortcuts stay alone.
    @MainActor
    static func checkHotkeys(itemProviders: [any MenuItemProvider] = []) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("panelumi-hotkey-check.json")
        try? FileManager.default.removeItem(at: url)

        let store = ConfigStore(url: url)
        store.update { config in
            config.setHotkey(
                HotkeyBinding(
                    keyCode: 40, // K
                    modifiers: HotkeyBinding.controlModifier | HotkeyBinding.optionModifier,
                    label: "K"
                ),
                for: "keepAwake"
            )
        }

        let model = AppModel(store: store, itemProviders: itemProviders)
        let binding = model.config.hotkey(for: "keepAwake")?.displayString ?? "none"
        print("registered\t\(binding)")
        if model.hotkeyIssues.isEmpty {
            print("issues\tnone")
        } else {
            for issue in model.hotkeyIssues {
                print("issue\t\(issue)")
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

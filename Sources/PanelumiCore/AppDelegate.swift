import AppKit
import SwiftUI
import PanelumiKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let screenshot: ScreenshotCoordinator
    private lazy var model: AppModel = {
        AppModel(catalog: AppCatalog.make(screenshot: screenshot), itemProviders: menuItemProviders)
    }()
    private let menuItemProviders: [any MenuItemProvider]
    private let settingsSectionProviders: [any SettingsSectionProvider]
    private let permissions = PermissionCenter()
    private var menuController: MenuController?
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var instanceLockFD: Int32 = -1

    /// Creates the delegate; extensions are handed to the screenshot coordinator
    /// and menu item providers to the model that builds the status-bar menu.
    init(
        captureExtensions: [any CaptureExtension] = [],
        menuItemProviders: [any MenuItemProvider] = [],
        settingsSectionProviders: [any SettingsSectionProvider] = []
    ) {
        self.menuItemProviders = menuItemProviders
        self.settingsSectionProviders = settingsSectionProviders
        screenshot = ScreenshotCoordinator(captureExtensions: captureExtensions)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One menu-bar icon per user: a second instance would add a duplicate
        // status item with an identical menu. The flock also covers a race
        // between two launches started at the same moment.
        guard acquireInstanceLock() else {
            NSApp.terminate(nil)
            return
        }

        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = others.first {
                other.activate()
                NSApp.terminate(nil)
                return
            }
        }

        let controller = MenuController(model: model, permissions: permissions)
        controller.openSettings = { [weak self] in self?.showSettings() }
        controller.openPermissions = { [weak self] in self?.showSetup() }
        menuController = controller

        // A capture that failed on a missing grant sends the user to the
        // checklist, which explains the relaunch rule and offers it.
        screenshot.onPermissionFailure = { [weak self] in self?.showSetup() }

        // Load the text-recognition models in the background, so the first
        // recognition after login does not wait for them.
        if model.config.isEnabled(ScreenshotCoordinator.recognizeTextID) {
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                TextRecognizer.warmUp()
            }
        }

        permissions.refresh()
        let launchingForScreenshot = CommandLine.arguments.contains("--show-settings")
        if !model.config.didCompleteSetup && !launchingForScreenshot {
            showSetup()
        }

        if launchingForScreenshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showSettings()
            }
        }

        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak controller] in
                controller?.openMenuForDebug()
            }
        }

        if CommandLine.arguments.contains("--editor-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginEditorDemo()
            }
        }
        if CommandLine.arguments.contains("--ocr-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginRecognitionDemo()
            }
        }
        if CommandLine.arguments.contains("--selection-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginDemo()
            }
        }

        if CommandLine.arguments.contains("--timed-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginTimedDemo()
            }
        }

        if CommandLine.arguments.contains("--watermark-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginWatermarkDemo()
            }
        }

        if CommandLine.arguments.contains("--save-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginDemoSave()
            }
        }

        if CommandLine.arguments.contains("--copy-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginDemoCopy()
            }
        }

        if CommandLine.arguments.contains("--capture-compare") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.screenshot.beginDemo()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.screenshot.compareCaptures()
            }
        }
    }

    /// The single place the app asks for permissions: shown at launch while
    /// something is missing, and reachable later from the menu.
    func showSetup() {
        if let window = setupWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SetupView(permissions: permissions) { [weak self] in
            self?.model.markSetupComplete()
            self?.setupWindow?.close()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = t("Set up Panelumi")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        setupWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// `--pane customize` opens Settings on a given page, built-in or injected;
    /// used for screenshots and quick checks.
    private func initialPage(sections: [SettingsSection]) -> SettingsView.Page {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--pane"), arguments.indices.contains(index + 1) else {
            return .builtin(.general)
        }
        let raw = arguments[index + 1]
        if let pane = SettingsView.Pane(rawValue: raw) {
            return .builtin(pane)
        }
        if sections.contains(where: { $0.id == raw }) {
            return .section(raw)
        }
        return .builtin(.general)
    }

    /// One list, in provider order; an id repeated by a later provider is
    /// dropped, the same rule the menu uses.
    private func settingsSections() -> [SettingsSection] {
        var all: [SettingsSection] = []
        for provider in settingsSectionProviders {
            all.append(contentsOf: provider.sections)
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private func acquireInstanceLock() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.current.supportFolderName)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let fd = open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    func showSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let sections = settingsSections()
        let hosting = NSHostingController(rootView: SettingsView(
            model: model,
            permissions: permissions,
            sections: sections,
            initialPage: initialPage(sections: sections)
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Panelumi"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

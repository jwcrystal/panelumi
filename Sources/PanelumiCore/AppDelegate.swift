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
    private let settingsPageProviders: [any SettingsPageProvider]
    private let permissions = PermissionCenter()
    private var menuController: MenuController?
    private lazy var settingsHost = SettingsWindowHost(
        pages: { [settingsPageProviders] in Self.settingsPages(from: settingsPageProviders) },
        makeView: { [unowned self] pages, initialPage in
            AnyView(SettingsView(model: model, permissions: permissions, pages: pages, initialPage: initialPage))
        }
    )
    private var setupWindow: NSWindow?
    private var instanceLockFD: Int32 = -1

    /// Creates the delegate; extensions are handed to the screenshot coordinator,
    /// menu item providers to the model that builds the status-bar menu, and
    /// settings page providers to the Settings window.
    init(
        captureExtensions: [any CaptureExtension] = [],
        menuItemProviders: [any MenuItemProvider] = [],
        settingsPageProviders: [any SettingsPageProvider] = []
    ) {
        self.menuItemProviders = menuItemProviders
        self.settingsPageProviders = settingsPageProviders
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

    /// The menu's rules apply: a repeated provider identifier is skipped and a
    /// taken page id is dropped.
    static func settingsPages(from providers: [any SettingsPageProvider]) -> [SettingsPage] {
        var seenProviders = Set<String>()
        var seenPages = Set<String>()
        var result: [SettingsPage] = []
        for provider in providers {
            guard seenProviders.insert(provider.identifier).inserted else {
                #if DEBUG
                NSLog("Panelumi: %@", "settings page provider \(provider.identifier) is listed more than once; only the first is used.")
                #endif
                continue
            }
            for page in provider.pages where seenPages.insert(page.id).inserted {
                result.append(page)
            }
        }
        return result
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
        let window = settingsHost.prepareWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

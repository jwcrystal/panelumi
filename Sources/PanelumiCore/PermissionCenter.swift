import AppKit
import AVFoundation
import CoreServices
import PanelumiKit

/// One permission a shipped feature needs, in the order the checklist lists them.
enum MissingPermission {
    case accessibility
    case screenRecording
    case microphone
    case systemEvents
    case finder
}

/// The permission state without the system calls behind it, so the rules that
/// decide what is missing stay testable without touching TCC.
struct PermissionSnapshot: Equatable {
    var accessibility = false
    var screenRecording = false
    /// Whether Screen Recording was already granted when this process started.
    var screenRecordingAtLaunch = false
    var microphone: AVAuthorizationStatus = .notDetermined
    var systemEvents: PermissionCenter.AutomationState = .unknown
    var finder: PermissionCenter.AutomationState = .unknown

    var missing: [MissingPermission] {
        var missing: [MissingPermission] = []
        if !accessibility { missing.append(.accessibility) }
        if !screenRecording { missing.append(.screenRecording) }
        if microphone != .authorized { missing.append(.microphone) }
        // `unknown` means the target app is not running, not that the grant was
        // refused, so it must not read as something the user has to fix.
        if systemEvents == .denied { missing.append(.systemEvents) }
        if finder == .denied { missing.append(.finder) }
        return missing
    }

    var missingCount: Int { missing.count }
    var allGranted: Bool { missing.isEmpty }

    /// macOS applies a Screen Recording grant to new processes only, so one that
    /// arrived while this process was running still needs a relaunch.
    var screenRecordingRelaunchNeeded: Bool {
        screenRecording && !screenRecordingAtLaunch
    }
}

/// Reads and requests the permissions Panelumi's shipped features can need.
///
/// The app asks once, in the setup window shown at launch. Switches never call a
/// prompting API themselves, so using the menu cannot trigger another dialog.
@MainActor
final class PermissionCenter: ObservableObject {
    enum AutomationState: Equatable {
        case granted
        case denied
        case unknown
    }

    @Published private(set) var accessibility = false
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var screenRecording = false
    @Published private(set) var screenRecordingAtLaunch = false
    @Published private(set) var screenRecordingRequested = false
    @Published private(set) var systemEvents: AutomationState = .unknown
    @Published private(set) var finder: AutomationState = .unknown
    /// Result of the last "Grant" attempt, shown under the rows.
    @Published private(set) var automationMessage: String?
    @Published private(set) var automationMessageIsError = false

    private var refreshTimer: Timer?
    private var readScreenRecordingAtLaunch = false

    var snapshot: PermissionSnapshot {
        PermissionSnapshot(
            accessibility: accessibility,
            screenRecording: screenRecording,
            screenRecordingAtLaunch: screenRecordingAtLaunch,
            microphone: microphone,
            systemEvents: systemEvents,
            finder: finder
        )
    }

    var missing: [MissingPermission] { snapshot.missing }
    var missingCount: Int { snapshot.missingCount }
    var allGranted: Bool { snapshot.allGranted }
    var screenRecordingRelaunchNeeded: Bool { snapshot.screenRecordingRelaunchNeeded }

    /// Live status while a settings or setup window is open, so a toggle in
    /// System Settings shows up without relaunching.
    func startMonitoring() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        screenRecording = CGPreflightScreenCaptureAccess()
        if !readScreenRecordingAtLaunch {
            screenRecordingAtLaunch = screenRecording
            readScreenRecordingAtLaunch = true
        }

        // Unknown usually means the target app is not running, not that the
        // grant is missing; keep the last known answer instead of flapping.
        let systemEventsState = Self.automationState(bundleID: "com.apple.systemevents")
        if systemEventsState != .unknown { systemEvents = systemEventsState }

        let finderState = Self.automationState(bundleID: "com.apple.finder")
        if finderState != .unknown { finder = finderState }
    }

    /// First-launch check: send one harmless event per target. A grant that is
    /// already in place returns instantly; otherwise this is where macOS asks.
    func verifyAutomationAtLaunch() {
        for bundleID in ["com.apple.systemevents", "com.apple.finder"] where state(for: bundleID) != .granted {
            do {
                _ = try Automation.run(Self.probeScript(for: bundleID))
                setAutomationState(.granted, for: bundleID)
            } catch {
                setAutomationState(.denied, for: bundleID)
            }
        }
    }

    private func state(for bundleID: String) -> AutomationState {
        switch bundleID {
        case "com.apple.systemevents": return systemEvents
        case "com.apple.finder": return finder
        default: return .unknown
        }
    }

    // MARK: - Requests

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestScreenRecording() {
        screenRecordingRequested = true
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAutomation(bundleID: String) {
        automationMessage = nil
        automationMessageIsError = false

        do {
            // Sending a harmless real event is what makes macOS show the
            // Automation prompt; asking the permission API alone can return
            // without any dialog.
            _ = try Automation.run(Self.probeScript(for: bundleID))
            refresh()
            // A successful send is the ground truth, even if the query API
            // lags behind right after a grant.
            setAutomationState(.granted, for: bundleID)
            automationMessage = tf("%@ is allowed.", Self.displayName(for: bundleID))
        } catch {
            refresh()
            automationMessage = "\(Self.displayName(for: bundleID)): \(error.localizedDescription)"
            automationMessageIsError = true
        }
    }

    private func setAutomationState(_ state: AutomationState, for bundleID: String) {
        switch bundleID {
        case "com.apple.systemevents": systemEvents = state
        case "com.apple.finder": finder = state
        default: break
        }
    }

    private static func probeScript(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.systemevents":
            return #"tell application "System Events" to get name"#
        case "com.apple.finder":
            return #"tell application "Finder" to get name of startup disk"#
        default:
            return "tell application id \"\(bundleID)\" to get name"
        }
    }

    private static func displayName(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.systemevents": return "System Events"
        case "com.apple.finder": return "Finder"
        default: return bundleID
        }
    }

    func openPrivacyPane(_ pane: String) {
        if pane == "Privacy_ScreenCapture" { screenRecordingRequested = true }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    private static func automationState(bundleID: String) -> AutomationState {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else {
            return .unknown
        }
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            // procNotFound and friends: no answer, not a refusal.
            return .unknown
        }
    }
}

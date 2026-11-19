import Foundation

/// The version and edition strings the About pane and the menu share.
///
/// An edition build sets `PanelumiEdition` in its Info.plist; the Free build
/// leaves the key out, so its UI shows no edition at all.
struct BuildInfo: Equatable {
    let shortVersion: String
    let buildVersion: String?
    let edition: String

    init(shortVersion: String, buildVersion: String?, edition: String = "") {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.edition = edition.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `0.11.0`, or `0.11.0 (12)` when the build number says something else.
    var version: String {
        guard let buildVersion, !buildVersion.isEmpty, buildVersion != shortVersion else {
            return shortVersion
        }
        return "\(shortVersion) (\(buildVersion))"
    }

    static var current: BuildInfo {
        let info = Bundle.main.infoDictionary
        return BuildInfo(
            shortVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            buildVersion: info?["CFBundleVersion"] as? String,
            edition: info?["PanelumiEdition"] as? String ?? ""
        )
    }
}

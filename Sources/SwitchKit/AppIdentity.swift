import Foundation

/// Where the app finds its update feed, project links and support folder.
///
/// A package that depends on `SwitchDeckCore` can supply its own values
/// through `LaunchOptions`. The defaults are the app's own values.
public struct AppIdentity: Equatable, Sendable {
    /// Folder name inside Application Support. Used for the config file and
    /// the single-instance lock.
    public var supportFolderName: String
    /// Endpoint the update check calls. It must answer like the GitHub
    /// "latest release" API: a JSON object with `tag_name` and `html_url`.
    public var updateFeedURL: URL
    public var repositoryURL: URL
    public var issuesURL: URL

    public init(
        supportFolderName: String = "SwitchDeck",
        updateFeedURL: URL = URL(
            string: "https://api.github.com/repos/jwcrystal/switchdeck/releases/latest"
        )!,
        repositoryURL: URL = URL(string: "https://github.com/jwcrystal/switchdeck")!,
        issuesURL: URL = URL(string: "https://github.com/jwcrystal/switchdeck/issues")!
    ) {
        self.supportFolderName = supportFolderName
        self.updateFeedURL = updateFeedURL
        self.repositoryURL = repositoryURL
        self.issuesURL = issuesURL
    }

    public static let standard = AppIdentity()

    /// The identity the app reads. Process-wide and written once at launch by
    /// `SwitchDeckLauncher.run`, which overwrites any earlier value. Hosts pass
    /// their identity through `LaunchOptions` instead of setting this directly.
    public static var current: AppIdentity = .standard
}

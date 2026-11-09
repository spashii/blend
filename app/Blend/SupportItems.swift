import Foundation

/// The items between Settings… and Quit in the menu bar panel, in the order it shows them.
/// The panel draws this list, so BlendTests checks the panel's order by reading it.
enum SupportItem: CaseIterable {
    case checkForUpdates
    case reportIssue
    case viewOnGitHub

    var title: String {
        switch self {
        case .checkForUpdates: "Check for Updates…"
        case .reportIssue: "Report an Issue…"
        case .viewOnGitHub: "View on GitHub"
        }
    }

    static let repository = URL(string: "https://github.com/spashii/blend")!

    /// A new issue whose body holds the two versions and nothing else from this Mac: no logs,
    /// no mixes, no settings.
    static func issueURL(appVersion: String, macOS: String) -> URL {
        let body = "App version: \(appVersion)\nmacOS: \(macOS)\n\n"
        var components = URLComponents(url: repository.appending(path: "issues/new"),
                                       resolvingAgainstBaseURL: false)!
        // Encoded here because URLQueryItem leaves a + as it is, and GitHub reads it as a space.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "body", value: body.addingPercentEncoding(withAllowedCharacters: queryValue)),
        ]
        return components.url!
    }

    /// The issue link for this copy of Blend Mic on this Mac.
    static var issueURL: URL {
        issueURL(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                     ?? "unknown",
                 macOS: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
}

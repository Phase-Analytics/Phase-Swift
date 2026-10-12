import Foundation

extension PhaseSDK {
    private static let camelCaseRegex = try? NSRegularExpression(pattern: "([a-z])([A-Z])")
    private static let disallowedCharacterRegex = try? NSRegularExpression(pattern: "[^a-z0-9_./ -]")

    /// Turns a view name or path into a screen name the server accepts:
    /// - "HomeView" → "/home-view" (CamelCase to kebab)
    /// - "//home//" → "/home" (repeated and trailing slashes)
    /// - "/path?query#hash" → "/path" (query string and fragment removed)
    /// - "Café & Bar" → "/caf- - bar" (characters outside `[a-z0-9_./ -]` become "-")
    ///
    /// Numeric segments ("/users/123") are left for the server, which normalizes them to
    /// "/users/:id" after validation; ":" itself is not an accepted character.
    internal static func formatScreenName(_ name: String) -> String {
        var path = name

        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }
        if let hashIndex = path.firstIndex(of: "#") {
            path = String(path[..<hashIndex])
        }

        path = replacingMatches(of: camelCaseRegex, in: path, with: "$1-$2")
        path = path.lowercased()
        path = replacingMatches(of: disallowedCharacterRegex, in: path, with: "-")

        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }

        if path.hasSuffix("/") && path.count > 1 {
            path = String(path.dropLast())
        }

        if !path.hasPrefix("/") {
            path = "/" + path
        }

        return String(path.prefix(ValidationConstants.EventName.maxLength))
    }

    private static func replacingMatches(of regex: NSRegularExpression?, in string: String, with template: String)
        -> String
    {
        guard let regex else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }
}

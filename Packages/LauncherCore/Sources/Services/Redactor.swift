import Foundation

/// Removes personal and secret-looking data from text before it leaves the machine.
public struct Redactor: Sendable {
    public let homeDirectory: String
    public let userName: String

    public init(homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName()) {
        self.homeDirectory = homeDirectory
        self.userName = userName
    }

    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Wine maps the macOS user into C:\users\<name>.
            (#"(?i)([\\/]users[\\/])(?!public\b|<user>)[^\\/\s"']+"#, "$1<user>"),
            // key=value or key: value secrets.
            (#"(?i)\b(password|passwd|token|secret|cookie|authorization|api[_-]?key|session[_-]?id|refresh[_-]?token|access[_-]?token)\b(\s*[=:]\s*)("[^"]*"|\S+)"#, "$1$2<redacted>"),
            // JSON Web Tokens (Steam uses them for login sessions).
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "<redacted-jwt>"),
        ]
        return patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    public func redact(_ text: String) -> String {
        var result = text
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        for (regex, template) in Self.rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        if userName.count >= 3 {
            let escaped = NSRegularExpression.escapedPattern(for: userName)
            if let regex = try? NSRegularExpression(pattern: "(?i)\\b\(escaped)\\b") {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<user>")
            }
        }
        return result
    }
}

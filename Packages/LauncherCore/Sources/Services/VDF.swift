import Foundation

/// Minimal reader for Valve's text KeyValues format (libraryfolders.vdf, appmanifest_*.acf).
public indirect enum VDFNode: Sendable, Equatable {
    case string(String)
    case object([(String, VDFNode)])

    public static func == (lhs: VDFNode, rhs: VDFNode) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Case-insensitive lookup; Steam is inconsistent about key casing.
    public subscript(key: String) -> VDFNode? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var children: [(String, VDFNode)] {
        if case .object(let pairs) = self { return pairs }
        return []
    }

    public static func parse(_ text: String) throws -> VDFNode {
        var parser = VDFParser(scalars: Array(text.unicodeScalars))
        return .object(try parser.parsePairs(topLevel: true))
    }
}

public struct VDFParseError: Error, Equatable {
    public var message: String
}

private struct VDFParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    mutating func parsePairs(topLevel: Bool) throws -> [(String, VDFNode)] {
        var pairs: [(String, VDFNode)] = []
        while true {
            skipTrivia()
            guard index < scalars.count else {
                if topLevel { return pairs }
                throw VDFParseError(message: "unexpected end of input")
            }
            if scalars[index] == "}" {
                if topLevel { throw VDFParseError(message: "unbalanced }") }
                index += 1
                return pairs
            }
            let key = try readToken()
            skipTrivia()
            guard index < scalars.count else { throw VDFParseError(message: "missing value for \(key)") }
            if scalars[index] == "{" {
                index += 1
                pairs.append((key, .object(try parsePairs(topLevel: false))))
            } else {
                pairs.append((key, .string(try readToken())))
            }
        }
    }

    mutating func skipTrivia() {
        while index < scalars.count {
            let c = scalars[index]
            if c.properties.isWhitespace {
                index += 1
            } else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else {
                return
            }
        }
    }

    mutating func readToken() throws -> String {
        var result = String.UnicodeScalarView()
        if scalars[index] == "\"" {
            index += 1
            while index < scalars.count, scalars[index] != "\"" {
                if scalars[index] == "\\", index + 1 < scalars.count {
                    index += 1
                    switch scalars[index] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(scalars[index])
                    }
                } else {
                    result.append(scalars[index])
                }
                index += 1
            }
            guard index < scalars.count else { throw VDFParseError(message: "unterminated string") }
            index += 1
        } else {
            while index < scalars.count, !scalars[index].properties.isWhitespace,
                  scalars[index] != "{", scalars[index] != "}", scalars[index] != "\"" {
                result.append(scalars[index])
                index += 1
            }
            if result.isEmpty { throw VDFParseError(message: "empty token") }
        }
        return String(result)
    }
}

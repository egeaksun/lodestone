import Foundation

/// A transform failed because the input isn't what it expects. `summary` is short enough for a
/// toast ("Not valid JSON"); `message` adds where and why, for the CLI.
public struct TextTransformError: Error, Equatable, CustomStringConvertible {
    public var summary: String
    public var detail: String?

    public init(_ summary: String, detail: String? = nil) {
        self.summary = summary
        self.detail = detail
    }

    public var message: String { detail.map { "\(summary): \($0)" } ?? summary }
    public var description: String { message }
    public var ipcError: IPCError { IPCError("invalid_input", message) }
}

/// Developer text transforms, applied to the clipboard from the menu (`text.<rawValue>` commands)
/// and to arguments, stdin or the clipboard from `lodestone text <name>`.
public enum TextTransform: String, CaseIterable, Sendable {
    case jsonPretty, jsonPrettySorted, jsonMinify, jsonEscape, jsonUnescape
    case base64Encode, base64Decode, base64UrlEncode, base64UrlDecode
    case urlEncode, urlDecode
    case htmlEncode, htmlDecode
    case jwtDecode
    case timestamp
    case uuid
    case camelCase, pascalCase, snakeCase, kebabCase, constantCase, titleCase, upperCase, lowerCase
    case trim, collapseWhitespace
    case sortLines, dedupeLines, reverseLines
    case count
    case md5, sha1, sha256

    /// The CLI name: `json-pretty`, `base64-url-decode`, `sha256`.
    public var name: String { TextCase.convert(rawValue, to: .kebab) }

    /// The command id: `text.jsonPretty`.
    public var commandID: String { "text.\(rawValue)" }

    /// Accepts the CLI name, the raw value or the command id, ignoring case, dashes and underscores.
    public init?(name: String) {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let bare = name.lowercased().hasPrefix("text.") ? String(name.dropFirst(5)) : name
        guard let match = Self.allCases.first(where: { key($0.rawValue) == key(bare) }) else { return nil }
        self = match
    }

    public var title: String {
        switch self {
        case .jsonPretty: "Pretty-Print JSON"
        case .jsonPrettySorted: "Pretty-Print JSON, Sorted Keys"
        case .jsonMinify: "Minify JSON"
        case .jsonEscape: "Escape as JSON String"
        case .jsonUnescape: "Unescape JSON String"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .base64UrlEncode: "Base64 URL-Safe Encode"
        case .base64UrlDecode: "Base64 URL-Safe Decode"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .htmlEncode: "Encode HTML Entities"
        case .htmlDecode: "Decode HTML Entities"
        case .jwtDecode: "Decode JWT"
        case .timestamp: "Unix Timestamp ↔ ISO 8601"
        case .uuid: "New UUID"
        case .camelCase: "camelCase"
        case .pascalCase: "PascalCase"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .constantCase: "CONSTANT_CASE"
        case .titleCase: "Title Case"
        case .upperCase: "UPPERCASE"
        case .lowerCase: "lowercase"
        case .trim: "Trim"
        case .collapseWhitespace: "Collapse Whitespace"
        case .sortLines: "Sort Lines"
        case .dedupeLines: "Remove Duplicate Lines"
        case .reverseLines: "Reverse Lines"
        case .count: "Count Characters, Words & Lines"
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        }
    }

    /// Menu groups, in order.
    public static let groups: [(title: String, transforms: [TextTransform])] = [
        ("JSON", [.jsonPretty, .jsonPrettySorted, .jsonMinify, .jsonEscape, .jsonUnescape]),
        ("Encode & Decode", [.base64Encode, .base64Decode, .base64UrlEncode, .base64UrlDecode, .urlEncode, .urlDecode,
                             .htmlEncode, .htmlDecode, .jwtDecode, .timestamp]),
        ("Case", [.camelCase, .pascalCase, .snakeCase, .kebabCase, .constantCase, .titleCase, .upperCase, .lowerCase]),
        ("Whitespace & Lines", [.trim, .collapseWhitespace, .sortLines, .dedupeLines, .reverseLines]),
        ("Hash", [.md5, .sha1, .sha256]),
        ("Other", [.uuid, .count]),
    ]

    /// False for transforms that ignore their input (UUID).
    public var takesInput: Bool { self != .uuid }
    /// False for transforms that report on the text instead of replacing it (count).
    public var replacesText: Bool { self != .count }

    public func apply(_ text: String, now: Date = Date()) throws -> String {
        switch self {
        case .jsonPretty: return try JSONText.pretty(text)
        case .jsonPrettySorted: return try JSONText.pretty(text, sortKeys: true)
        case .jsonMinify: return try JSONText.minify(text)
        case .jsonEscape: return JSONText.escape(text)
        case .jsonUnescape: return try JSONText.unescape(text)
        case .base64Encode: return TextCodec.base64Encode(text)
        case .base64Decode: return try TextCodec.base64Decode(text)
        case .base64UrlEncode: return TextCodec.base64Encode(text, urlSafe: true)
        case .base64UrlDecode: return try TextCodec.base64Decode(text)
        case .urlEncode: return TextCodec.urlEncode(text)
        case .urlDecode: return try TextCodec.urlDecode(text)
        case .htmlEncode: return HTMLEntities.encode(text)
        case .htmlDecode: return HTMLEntities.decode(text)
        case .jwtDecode: return try JWT.decode(text, now: now).text
        case .timestamp: return try Timestamp.convert(text)
        case .uuid: return UUID().uuidString.lowercased()
        case .camelCase: return TextCase.convert(text, to: .camel)
        case .pascalCase: return TextCase.convert(text, to: .pascal)
        case .snakeCase: return TextCase.convert(text, to: .snake)
        case .kebabCase: return TextCase.convert(text, to: .kebab)
        case .constantCase: return TextCase.convert(text, to: .constant)
        case .titleCase: return TextCase.convert(text, to: .title)
        case .upperCase: return text.uppercased()
        case .lowerCase: return text.lowercased()
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseWhitespace: return TextLines.collapseWhitespace(text)
        case .sortLines: return TextLines.sort(text)
        case .dedupeLines: return TextLines.dedupe(text)
        case .reverseLines: return TextLines.reverse(text)
        case .count: return TextCounts(text).description
        case .md5: return TextHash.hex(text, .md5)
        case .sha1: return TextHash.hex(text, .sha1)
        case .sha256: return TextHash.hex(text, .sha256)
        }
    }

    /// A short confirmation for a toast after the clipboard was transformed: "Pretty-printed JSON".
    public var doneMessage: String {
        switch self {
        case .jsonPretty, .jsonPrettySorted: "Pretty-printed JSON"
        case .jsonMinify: "Minified JSON"
        case .jsonEscape: "Escaped as a JSON string"
        case .jsonUnescape: "Unescaped JSON string"
        case .base64Encode, .base64UrlEncode: "Encoded as Base64"
        case .base64Decode, .base64UrlDecode: "Decoded Base64"
        case .urlEncode: "URL-encoded"
        case .urlDecode: "URL-decoded"
        case .htmlEncode: "Encoded HTML entities"
        case .htmlDecode: "Decoded HTML entities"
        case .jwtDecode: "Decoded JWT"
        case .timestamp: "Converted timestamp"
        case .uuid: "Copied a new UUID"
        case .camelCase, .pascalCase, .snakeCase, .kebabCase, .constantCase, .titleCase, .upperCase, .lowerCase: "Converted to \(title)"
        case .trim: "Trimmed"
        case .collapseWhitespace: "Collapsed whitespace"
        case .sortLines: "Sorted lines"
        case .dedupeLines: "Removed duplicate lines"
        case .reverseLines: "Reversed lines"
        case .count: "Counted"
        case .md5, .sha1, .sha256: "Copied \(title) hash"
        }
    }
}

import CryptoKit
import Foundation

/// Base64 and URL encoding of UTF-8 text.
public enum TextCodec {
    public static func base64Encode(_ text: String, urlSafe: Bool = false) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        guard urlSafe else { return encoded }
        return encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts the standard and URL-safe alphabets, with or without padding, ignoring whitespace.
    public static func base64Decode(_ text: String) throws -> String {
        let data = try base64Data(text)
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw TextTransformError("Decoded Base64 isn't text", detail: "it is \(data.count) bytes of binary data")
        }
        return decoded
    }

    public static func base64Data(_ text: String) throws -> Data {
        var s = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty else { throw TextTransformError("Not valid Base64", detail: "the text is empty") }
        if s.count % 4 != 0 { s += String(repeating: "=", count: 4 - s.count % 4) }
        guard let data = Data(base64Encoded: s) else {
            throw TextTransformError("Not valid Base64", detail: "only A–Z, a–z, 0–9, +, /, - and _ are allowed")
        }
        return data
    }

    /// Unreserved characters (RFC 3986: letters, digits, - . _ ~) stay; everything else is %-encoded.
    public static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func urlDecode(_ text: String) throws -> String {
        guard let decoded = text.removingPercentEncoding else {
            throw TextTransformError("Not valid URL encoding", detail: "a % must be followed by two hex digits forming UTF-8")
        }
        return decoded
    }
}

/// HTML character references.
public enum HTMLEntities {
    /// Escapes the five characters that matter in HTML text and attributes.
    public static func encode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "bull": "•", "middot": "·", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³", "micro": "µ",
        "iexcl": "¡", "iquest": "¿", "shy": "\u{AD}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    /// Decodes named (`&amp;`), decimal (`&#39;`) and hex (`&#x27;`) references. Unknown ones are left as written.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while let amp = text[i...].firstIndex(of: "&") {
            out += text[i..<amp]
            let afterAmp = text.index(after: amp)
            let limit = text.index(afterAmp, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
            if let semi = text[afterAmp..<limit].firstIndex(of: ";"), let decoded = reference(text[afterAmp..<semi]) {
                out += decoded
                i = text.index(after: semi)
            } else {
                out += "&"
                i = afterAmp
            }
        }
        out += text[i...]
        return out
    }

    private static func reference(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" { value = UInt32(digits.dropFirst(), radix: 16) } else { value = UInt32(digits) }
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[String(name)]
    }
}

/// Decodes a JSON Web Token's header and payload. The signature is not verified.
public enum JWT {
    public struct Decoded {
        public var header: String
        public var payload: String
        /// `iat`, `nbf` and `exp` claims that are numbers, in that order.
        public var dates: [(claim: String, date: Date)]
        public var text: String
    }

    public static func decode(_ token: String, now: Date = Date()) throws -> Decoded {
        var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 5 else {
            throw TextTransformError("Not a JWT", detail: "a JWT has three parts separated by dots, found \(parts.count)")
        }
        guard parts.count == 3 else { throw TextTransformError("Encrypted JWTs (JWE) can't be decoded without the key") }
        func json(_ part: Substring, _ name: String) throws -> (pretty: String, data: Data) {
            guard let data = try? TextCodec.base64Data(String(part)), let text = String(data: data, encoding: .utf8),
                  let pretty = try? JSONText.pretty(text) else {
                throw TextTransformError("Not a JWT", detail: "the \(name) isn't Base64-encoded JSON")
            }
            return (pretty, data)
        }
        let header = try json(parts[0], "header")
        let payload = try json(parts[1], "payload")

        var dates: [(String, Date)] = []
        if let claims = (try? JSONSerialization.jsonObject(with: payload.data)) as? [String: Any] {
            for claim in ["iat", "nbf", "exp"] {
                if let n = claims[claim] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                    dates.append((claim, Date(timeIntervalSince1970: n.doubleValue)))
                }
            }
        }

        var lines = ["Header", header.pretty, "", "Payload", payload.pretty]
        if !dates.isEmpty {
            lines.append("")
            let labels = ["iat": "Issued at (iat): ", "nbf": "Not before (nbf):", "exp": "Expires (exp):   "]
            for (claim, date) in dates {
                var line = "\(labels[claim]!) \(Timestamp.iso(date))"
                if claim == "exp" { line += date < now ? " (expired)" : " (not expired)" }
                if claim == "nbf", date > now { line += " (not yet valid)" }
                lines.append(line)
            }
        }
        lines += ["", parts[2].isEmpty ? "No signature (alg: none)." : "Signature not verified."]
        return Decoded(header: header.pretty, payload: payload.pretty, dates: dates, text: lines.joined(separator: "\n"))
    }
}

/// Unix timestamps and ISO 8601 dates.
public enum Timestamp {
    public enum Unit: String, Sendable { case seconds, milliseconds, microseconds, nanoseconds }

    /// Guesses the unit from the magnitude: anything below 10^11 is seconds (until the year 5138),
    /// then milliseconds, microseconds and nanoseconds.
    public static func unit(of value: Double) -> Unit {
        switch abs(value) {
        case ..<1e11: .seconds
        case ..<1e14: .milliseconds
        case ..<1e17: .microseconds
        default: .nanoseconds
        }
    }

    /// A number becomes an ISO 8601 date in UTC; a date becomes Unix seconds.
    public static func convert(_ text: String) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(t), t.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
            let divisor: Double = switch unit(of: value) {
            case .seconds: 1
            case .milliseconds: 1e3
            case .microseconds: 1e6
            case .nanoseconds: 1e9
            }
            return iso(Date(timeIntervalSince1970: value / divisor))
        }
        guard let date = parseISO(t) else {
            throw TextTransformError("Not a timestamp or date", detail: "expected Unix time like 1700000000 or ISO 8601 like 2023-11-14T22:13:20Z")
        }
        let seconds = date.timeIntervalSince1970
        let ms = (seconds * 1000).rounded()
        return ms.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int64(ms / 1000)) : String(format: "%.3f", ms / 1000)
    }

    /// UTC, with milliseconds only when there are any: `2023-11-14T22:13:20Z`, `2023-11-14T22:13:20.123Z`.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        f.formatOptions = ms.truncatingRemainder(dividingBy: 1000) == 0 ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// Accepts `2023-11-14T22:13:20Z`, fractional seconds, offsets (`+03:00`), a space instead of `T`,
    /// no zone (read as UTC) and bare dates (`2023-11-14`, midnight UTC).
    public static func parseISO(_ text: String) -> Date? {
        var s = text
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime], [.withFullDate],
        ]
        for options in variants {
            f.formatOptions = options
            if let date = f.date(from: s) { return date }
        }
        return nil
    }
}

/// Identifier case conversions. Each line is converted on its own; indentation is kept.
public enum TextCase {
    public enum Style: Sendable { case camel, pascal, snake, kebab, constant, title }

    public static func convert(_ text: String, to style: Style) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let body = line.drop { $0 == " " || $0 == "\t" }
            let indent = line[line.startIndex..<body.startIndex]
            let trailingCR = body.hasSuffix("\r")
            let content = trailingCR ? body.dropLast() : body
            return String(indent) + convertLine(content, to: style) + (trailingCR ? "\r" : "")
        }.joined(separator: "\n")
    }

    static func convertLine(_ line: Substring, to style: Style) -> String {
        // Sentences ("the quick brown fox") keep their punctuation in Title Case.
        if style == .title, line.contains(where: \.isWhitespace) {
            return line.split(separator: " ", omittingEmptySubsequences: false).map { capitalized($0.lowercased()) }.joined(separator: " ")
        }
        let parts = words(line)
        guard !parts.isEmpty else { return String(line) }
        switch style {
        case .camel: return parts.enumerated().map { $0 == 0 ? $1.lowercased() : capitalized($1.lowercased()) }.joined()
        case .pascal: return parts.map { capitalized($0.lowercased()) }.joined()
        case .snake: return parts.map { $0.lowercased() }.joined(separator: "_")
        case .kebab: return parts.map { $0.lowercased() }.joined(separator: "-")
        case .constant: return parts.map { $0.uppercased() }.joined(separator: "_")
        case .title: return parts.map { capitalized($0.lowercased()) }.joined(separator: " ")
        }
    }

    /// Splits on anything that isn't a letter or digit, and at case changes: `fooBar`, `HTTPServer`
    /// (HTTP | Server), `base64Url` (base64 | Url). Digits stay with the word before them.
    public static func words<S: StringProtocol>(_ text: S) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if !current.isEmpty, c.isUppercase {
                let prev = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = prev.isLowercase || prev.isNumber
                let acronymEnd = prev.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnd { words.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}

/// Line-based operations. A trailing line break is kept, and `\r\n` line endings survive.
public enum TextLines {
    public static func sort(_ text: String) -> String {
        map(text) { lines in
            lines.sorted { a, b in
                let order = a.compare(b, options: [.caseInsensitive, .numeric])
                return order == .orderedSame ? a < b : order == .orderedAscending
            }
        }
    }

    /// Keeps the first occurrence of each line, in order.
    public static func dedupe(_ text: String) -> String {
        map(text) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    public static func reverse(_ text: String) -> String {
        map(text) { $0.reversed() }
    }

    /// Every run of whitespace, line breaks included, becomes one space; ends are trimmed.
    public static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func map(_ text: String, _ transform: ([String]) -> [String]) -> String {
        // "\r\n" is a single Character in Swift, so split on both forms explicitly.
        let separator = text.contains("\r\n") ? "\r\n" : "\n"
        var body = text
        let trailing = body.hasSuffix(separator)
        if trailing { body.removeLast() } // "\r\n" is one Character
        let lines = body.components(separatedBy: separator)
        return transform(lines).joined(separator: separator) + (trailing ? separator : "")
    }
}

/// Character, word and line counts.
public struct TextCounts: Codable, Equatable, Sendable, CustomStringConvertible {
    public var characters: Int
    public var words: Int
    public var lines: Int

    public init(_ text: String) {
        characters = text.count
        words = text.split(whereSeparator: \.isWhitespace).count
        if text.isEmpty {
            lines = 0
        } else {
            let breaks = text.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
            lines = breaks + (text.last!.isNewline ? 0 : 1)
        }
    }

    public var description: String {
        func n(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
        return "\(n(characters, "character")), \(n(words, "word")), \(n(lines, "line"))"
    }
}

/// Hex digests of the text's UTF-8 bytes.
public enum TextHash {
    public enum Algorithm: Sendable { case md5, sha1, sha256 }

    public static func hex(_ text: String, _ algorithm: Algorithm) -> String {
        let data = Data(text.utf8)
        let digest: [UInt8] = switch algorithm {
        case .md5: Array(Insecure.MD5.hash(data: data))
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        case .sha256: Array(SHA256.hash(data: data))
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

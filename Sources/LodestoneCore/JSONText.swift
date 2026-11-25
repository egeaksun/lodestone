import Foundation

/// JSON reformatting that keeps the document as written: key order, number literals (`1.50`,
/// `1e10`, 20-digit integers) and string escapes come out exactly as they went in. Only whitespace
/// changes, plus key order when sorting is asked for. Foundation's JSONSerialization can't do this:
/// it reorders keys and rewrites numbers.
public enum JSONText {
    /// Indented with two spaces, `"key": value`.
    public static func pretty(_ text: String, sortKeys: Bool = false) throws -> String {
        var node = try parse(text)
        if sortKeys { node = node.sorted() }
        var out = ""
        node.write(to: &out, indent: 0, pretty: true)
        return out
    }

    /// Everything on one line, no spaces.
    public static func minify(_ text: String) throws -> String {
        let node = try parse(text)
        var out = ""
        node.write(to: &out, indent: 0, pretty: false)
        return out
    }

    /// The contents of a JSON string literal for `text`, without the surrounding quotes:
    /// `He said "hi"⏎` becomes `He said \"hi\"\n`.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The text a JSON string literal stands for. Surrounding quotes are optional.
    public static func unescape(_ text: String) throws -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") { body = String(body.dropFirst().dropLast()) }
        // Unescaped quotes and line breaks are tolerated: people paste half-escaped text.
        return try decodeString("\"" + body + "\"")
    }

    // MARK: Parsing

    indirect enum Node {
        case object([(key: String, literal: String, value: Node)])
        case array([Node])
        /// A string, number, true, false or null, exactly as written.
        case scalar(String)

        func sorted() -> Node {
            switch self {
            case .object(let members):
                // Stable, so duplicate keys keep their relative order.
                return .object(members.map { ($0.key, $0.literal, $0.value.sorted()) }
                    .enumerated().sorted { a, b in a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0 }
                    .map { (key: $0.element.0, literal: $0.element.1, value: $0.element.2) })
            case .array(let items): return .array(items.map { $0.sorted() })
            case .scalar: return self
            }
        }

        func write(to out: inout String, indent: Int, pretty: Bool) {
            let pad = String(repeating: "  ", count: indent + 1)
            let closePad = String(repeating: "  ", count: indent)
            switch self {
            case .scalar(let s):
                out += s
            case .array(let items):
                if items.isEmpty { out += "[]"; return }
                out += pretty ? "[\n" : "["
                for (i, item) in items.enumerated() {
                    if pretty { out += pad }
                    item.write(to: &out, indent: indent + 1, pretty: pretty)
                    if i < items.count - 1 { out += "," }
                    if pretty { out += "\n" }
                }
                out += pretty ? closePad + "]" : "]"
            case .object(let members):
                if members.isEmpty { out += "{}"; return }
                out += pretty ? "{\n" : "{"
                for (i, member) in members.enumerated() {
                    if pretty { out += pad }
                    out += member.literal
                    out += pretty ? ": " : ":"
                    member.value.write(to: &out, indent: indent + 1, pretty: pretty)
                    if i < members.count - 1 { out += "," }
                    if pretty { out += "\n" }
                }
                out += pretty ? closePad + "}" : "}"
            }
        }
    }

    static func parse(_ text: String) throws -> Node {
        var parser = Parser(Array(text.utf8))
        parser.skipWhitespace()
        // Tolerate a byte order mark.
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipWhitespace()
        if parser.atEnd { throw TextTransformError("Not valid JSON", detail: "the text is empty") }
        let node = try parser.value(depth: 0)
        parser.skipWhitespace()
        if !parser.atEnd { throw parser.error("unexpected \(parser.describeCurrent()) after the end of the JSON value") }
        return node
    }

    /// Decodes the escapes of a string literal (with its quotes).
    static func decodeString(_ literal: String) throws -> String {
        let bytes = Array(literal.utf8.dropFirst().dropLast())
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var scalars = String.UnicodeScalarView()
        func flush() {
            if !out.isEmpty { scalars.append(contentsOf: String(decoding: out, as: UTF8.self).unicodeScalars); out.removeAll() }
        }
        var i = 0
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16) else { return nil }
            return v
        }
        while i < bytes.count {
            let b = bytes[i]
            guard b == UInt8(ascii: "\\"), i + 1 < bytes.count else { out.append(b); i += 1; continue }
            let e = bytes[i + 1]
            i += 2
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                guard var v = hex4(i) else { throw TextTransformError("Not a valid JSON string", detail: "\\u needs four hex digits") }
                i += 4
                if (0xD800...0xDBFF).contains(v), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u"),
                   let low = hex4(i + 2), (0xDC00...0xDFFF).contains(low) {
                    v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                flush()
                scalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
            default:
                throw TextTransformError("Not a valid JSON string", detail: "invalid escape '\\\(String(decoding: [e], as: UTF8.self))'")
            }
        }
        flush()
        return String(scalars)
    }

    struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func describeCurrent() -> String {
            guard !atEnd else { return "end of text" }
            let scalar = String(decoding: bytes[index..<min(index + 4, bytes.count)], as: UTF8.self).first.map(String.init) ?? "?"
            return "'\(scalar)'"
        }

        func error(_ message: String) -> TextTransformError {
            var line = 1, column = 1
            for b in bytes[0..<min(index, bytes.count)] {
                if b == 0x0A { line += 1; column = 1 } else if b & 0xC0 != 0x80 { column += 1 }
            }
            return TextTransformError("Not valid JSON", detail: "\(message) at line \(line), column \(column)")
        }

        mutating func value(depth: Int) throws -> Node {
            guard depth < 512 else { throw error("nesting is too deep") }
            skipWhitespace()
            guard !atEnd else { throw error("unexpected end of text") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .scalar(try stringLiteral())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .scalar(try number())
            default:
                for word in ["true", "false", "null"] where bytes[index...].starts(with: Array(word.utf8)) {
                    index += word.utf8.count
                    return .scalar(word)
                }
                throw error("unexpected \(describeCurrent())")
            }
        }

        mutating func object(depth: Int) throws -> Node {
            index += 1
            var members: [(key: String, literal: String, value: Node)] = []
            skipWhitespace()
            if !atEnd, bytes[index] == UInt8(ascii: "}") { index += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard !atEnd, bytes[index] == UInt8(ascii: "\"") else {
                    throw error(atEnd ? "unexpected end of text, expected a key" : "expected a quoted key, found \(describeCurrent())")
                }
                let literal = try stringLiteral()
                skipWhitespace()
                guard !atEnd, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':' after a key, found \(describeCurrent())") }
                index += 1
                let value = try self.value(depth: depth + 1)
                members.append((try JSONText.decodeString(literal), literal, value))
                skipWhitespace()
                guard !atEnd else { throw error("unexpected end of text, expected ',' or '}'") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw error("expected ',' or '}', found \(describeCurrent())")
            }
        }

        mutating func array(depth: Int) throws -> Node {
            index += 1
            var items: [Node] = []
            skipWhitespace()
            if !atEnd, bytes[index] == UInt8(ascii: "]") { index += 1; return .array([]) }
            while true {
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard !atEnd else { throw error("unexpected end of text, expected ',' or ']'") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("expected ',' or ']', found \(describeCurrent())")
            }
        }

        /// A string literal including its quotes, validated.
        mutating func stringLiteral() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                }
                if b < 0x20 { throw error(b == 0x0A ? "line break inside a string (use \\n)" : "control character inside a string") }
                if b == UInt8(ascii: "\\") {
                    guard index + 1 < bytes.count else { break }
                    let e = bytes[index + 1]
                    if e == UInt8(ascii: "u") {
                        let hex = bytes[min(index + 2, bytes.count)..<min(index + 6, bytes.count)]
                        guard hex.count == 4, hex.allSatisfy({ isHex($0) }) else { throw error("\\u needs four hex digits") }
                        index += 6
                        continue
                    }
                    guard Array("\"\\/bfnrt".utf8).contains(e) else {
                        throw error("invalid escape '\\\(String(decoding: [e], as: UTF8.self))'")
                    }
                    index += 2
                    continue
                }
                index += 1
            }
            index = start
            throw error("unterminated string")
        }

        mutating func number() throws -> String {
            let start = index
            func digits() -> Int {
                let s = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - s
            }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            let intStart = index
            guard digits() > 0 else { throw error("expected a digit") }
            if bytes[intStart] == UInt8(ascii: "0"), index - intStart > 1 {
                index = intStart
                throw error("numbers can't have leading zeros")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("expected a digit after '.'") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("expected a digit in the exponent") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        private func isHex(_ b: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(b)
        }
    }
}

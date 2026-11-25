import Foundation

/// A user setting that features declare, so the Settings window and the CLI (`lodestone settings`)
/// can list, read, validate and change it in one place. Values live in UserDefaults under `key`.
public struct SettingDefinition: Sendable {
    public enum Kind: Sendable {
        case bool
        case int(range: ClosedRange<Int>)
        case double(range: ClosedRange<Double>)
        case string
        case choice([String])
    }

    /// "<feature>.<name>", for example "snapping.dragToSnap".
    public let key: String
    public let title: String
    public let kind: Kind
    public let defaultValue: JSONValue
    public let help: String

    public init(_ key: String, title: String, kind: Kind, default defaultValue: JSONValue, help: String = "") {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.help = help
    }

    public var kindDescription: String {
        switch kind {
        case .bool: "bool"
        case .int(let r): "int (\(r.lowerBound)…\(r.upperBound))"
        case .double(let r): "number (\(r.lowerBound)…\(r.upperBound))"
        case .string: "string"
        case .choice(let c): "one of: \(c.joined(separator: ", "))"
        }
    }

    /// Parses CLI text ("true", "42", "webp") into a validated value.
    public func parse(_ text: String) throws -> JSONValue {
        switch kind {
        case .bool:
            switch text.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: throw IPCError.invalidParams("\(key) expects true or false")
            }
        case .int(let range):
            guard let n = Int(text), range.contains(n) else { throw IPCError.invalidParams("\(key) expects \(kindDescription)") }
            return .number(Double(n))
        case .double(let range):
            guard let n = Double(text), range.contains(n) else { throw IPCError.invalidParams("\(key) expects \(kindDescription)") }
            return .number(n)
        case .string:
            return .string(text)
        case .choice(let choices):
            guard choices.contains(text) else { throw IPCError.invalidParams("\(key) expects \(kindDescription)") }
            return .string(text)
        }
    }

    /// Checks a value of the right JSON type and range.
    public func validate(_ value: JSONValue) throws -> JSONValue {
        switch (kind, value) {
        case (.bool, .bool): return value
        case (.int(let r), .number(let n)) where r.contains(Int(n)) && n == n.rounded(): return value
        case (.double(let r), .number(let n)) where r.contains(n): return value
        case (.string, .string): return value
        case (.choice(let c), .string(let s)) where c.contains(s): return value
        case (_, .string(let s)): return try parse(s)
        default: throw IPCError.invalidParams("\(key) expects \(kindDescription)")
        }
    }
}

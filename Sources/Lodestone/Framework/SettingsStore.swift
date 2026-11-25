import Foundation
import LodestoneCore
import LodestoneKit

/// Typed access to the settings features declare. Values are stored in UserDefaults under the
/// definition's key. Changes made here (from the Settings window or the CLI) are logged and
/// forwarded to features through `onChange`.
@MainActor
final class SettingsStore {
    private(set) var definitions: [SettingDefinition] = []
    private var byKey: [String: SettingDefinition] = [:]
    private let defaults: UserDefaults
    var onChange: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func register(_ definitions: [SettingDefinition]) {
        for d in definitions where byKey[d.key] == nil {
            self.definitions.append(d)
            byKey[d.key] = d
        }
    }

    func definition(_ key: String) -> SettingDefinition? { byKey[key] }

    func value(_ key: String) -> JSONValue {
        guard let d = byKey[key] else { return .null }
        guard let stored = defaults.object(forKey: key) else { return d.defaultValue }
        switch stored {
        case let b as Bool where CFGetTypeID(b as CFTypeRef) == CFBooleanGetTypeID(): return .bool(b)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String: return .string(s)
        default: return d.defaultValue
        }
    }

    func bool(_ key: String) -> Bool { value(key).bool ?? false }
    func int(_ key: String) -> Int { value(key).int ?? 0 }
    func double(_ key: String) -> Double { value(key).double ?? 0 }
    func string(_ key: String) -> String { value(key).string ?? "" }

    /// Validates and stores a value. Throws `IPCError` for unknown keys or invalid values.
    func set(_ key: String, _ value: JSONValue) throws {
        guard let d = byKey[key] else { throw IPCError.notFound("Unknown setting '\(key)'. Run `lodestone settings list`.") }
        let valid = try d.validate(value)
        switch valid {
        case .bool(let b): defaults.set(b, forKey: key)
        case .number(let n):
            if case .int = d.kind { defaults.set(Int(n), forKey: key) } else { defaults.set(n, forKey: key) }
        case .string(let s): defaults.set(s, forKey: key)
        default: throw IPCError.invalidParams("Unsupported value for \(key)")
        }
        Log.shared.info("settings", "set", ["key": .string(key), "value": valid])
        onChange?(key)
    }

    func reset(_ key: String) throws {
        guard byKey[key] != nil else { throw IPCError.notFound("Unknown setting '\(key)'") }
        defaults.removeObject(forKey: key)
        Log.shared.info("settings", "reset", ["key": .string(key)])
        onChange?(key)
    }

    /// Moves a value stored under an old key (from an earlier version) to its new key.
    func migrate(from oldKey: String, to newKey: String) {
        guard let old = defaults.object(forKey: oldKey) else { return }
        if defaults.object(forKey: newKey) == nil { defaults.set(old, forKey: newKey) }
        defaults.removeObject(forKey: oldKey)
    }
}

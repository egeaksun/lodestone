import Foundation

/// A key combination: a virtual key code plus Carbon modifier bits (cmdKey, shiftKey, optionKey, controlKey).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// The shortcut for each command: built-in defaults plus the user's changes, saved in UserDefaults.
/// Only changes are stored, so commands added in later versions pick up their defaults.
///
/// Commands are identified by string IDs. Snap actions use their raw value (for example "leftHalf"),
/// other features use "<feature>.<command>" (for example "clipboard.history").
public final class ShortcutStore {
    public private(set) var defaults: [String: KeyCombo]
    /// Every known command ID, in registration order. Used for conflict checks.
    public private(set) var ids: [String]
    private let storage: UserDefaults
    private let storageKey = "shortcuts"
    /// A nil value means the user cleared that shortcut.
    private var overrides: [String: KeyCombo?] = [:]

    public init(defaults: [String: KeyCombo] = [:], ids: [String]? = nil, storage: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = ids ?? defaults.keys.sorted()
        self.storage = storage
        if let data = storage.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for (id, combo) in saved { overrides.updateValue(combo, forKey: id) }
        }
    }

    /// Adds a command and its default shortcut (nil for none). Registering an ID again replaces its default.
    public func register(_ id: String, default combo: KeyCombo?) {
        if !ids.contains(id) { ids.append(id) }
        defaults[id] = combo
    }

    public func combo(for id: String) -> KeyCombo? {
        if let override = overrides[id] { return override }
        return defaults[id]
    }

    public func id(for combo: KeyCombo) -> String? {
        ids.first { self.combo(for: $0) == combo }
    }

    /// Assigns `combo` to `id`, or clears it when nil. Any other command using the same combination
    /// loses it, so one key combination never triggers two commands.
    public func set(_ combo: KeyCombo?, for id: String) {
        if let combo {
            for other in ids where other != id && self.combo(for: other) == combo {
                assign(nil, to: other)
            }
        }
        assign(combo, to: id)
        save()
    }

    public func resetToDefaults() {
        overrides.removeAll()
        save()
    }

    private func assign(_ combo: KeyCombo?, to id: String) {
        if combo == defaults[id] {
            overrides.removeValue(forKey: id)
        } else {
            overrides.updateValue(combo, forKey: id)
        }
    }

    private func save() {
        if overrides.isEmpty {
            storage.removeObject(forKey: storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(overrides) { storage.set(data, forKey: storageKey) }
    }
}

public extension ShortcutStore {
    func combo(for action: SnapAction) -> KeyCombo? { combo(for: action.rawValue) }
    func set(_ combo: KeyCombo?, for action: SnapAction) { set(combo, for: action.rawValue) }
}

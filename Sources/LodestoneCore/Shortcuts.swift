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

/// The shortcut for each action: built-in defaults plus the user's changes, saved in UserDefaults.
/// Only changes are stored, so actions added in later versions pick up their defaults.
public final class ShortcutStore {
    public let defaults: [SnapAction: KeyCombo]
    private let storage: UserDefaults
    private let storageKey = "shortcuts"
    /// A nil value means the user cleared that shortcut.
    private var overrides: [SnapAction: KeyCombo?] = [:]

    public init(defaults: [SnapAction: KeyCombo], storage: UserDefaults = .standard) {
        self.defaults = defaults
        self.storage = storage
        if let data = storage.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for (raw, combo) in saved {
                if let action = SnapAction(rawValue: raw) { overrides.updateValue(combo, forKey: action) }
            }
        }
    }

    public func combo(for action: SnapAction) -> KeyCombo? {
        if let override = overrides[action] { return override }
        return defaults[action]
    }

    public func action(for combo: KeyCombo) -> SnapAction? {
        SnapAction.allCases.first { self.combo(for: $0) == combo }
    }

    /// Assigns `combo` to `action`, or clears it when nil. Any other action using the same combination
    /// loses it, so one key combination never triggers two actions.
    public func set(_ combo: KeyCombo?, for action: SnapAction) {
        if let combo {
            for other in SnapAction.allCases where other != action && self.combo(for: other) == combo {
                assign(nil, to: other)
            }
        }
        assign(combo, to: action)
        save()
    }

    public func resetToDefaults() {
        overrides.removeAll()
        save()
    }

    private func assign(_ combo: KeyCombo?, to action: SnapAction) {
        if combo == defaults[action] {
            overrides.removeValue(forKey: action)
        } else {
            overrides.updateValue(combo, forKey: action)
        }
    }

    private func save() {
        if overrides.isEmpty {
            storage.removeObject(forKey: storageKey)
            return
        }
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { storage.set(data, forKey: storageKey) }
    }
}

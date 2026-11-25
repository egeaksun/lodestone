import Foundation

/// Text form of key combinations for the CLI: "ctrl+opt+left", "cmd+shift+v", "ctrl+opt+1".
/// Key codes are the US ANSI virtual key codes (kVK_*); modifiers are Carbon bits.
public enum KeyComboText {
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096

    static let keys: [(String, UInt32)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
        ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
        ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("return", 36), ("l", 37),
        ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46),
        (".", 47), ("tab", 48), ("space", 49), ("`", 50), ("delete", 51), ("escape", 53),
        ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97), ("f7", 98), ("f8", 100),
        ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111), ("f13", 105), ("f14", 107), ("f15", 113),
        ("f16", 106), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90),
        ("home", 115), ("pageup", 116), ("forwarddelete", 117), ("end", 119), ("pagedown", 121),
        ("left", 123), ("right", 124), ("down", 125), ("up", 126), ("enter", 76),
    ]

    private static let aliases: [String: String] = [
        "ret": "return", "backspace": "delete", "del": "forwarddelete", "esc": "escape",
        "←": "left", "→": "right", "↑": "up", "↓": "down", "↩": "return", "⌫": "delete", "⎋": "escape",
        "plus": "=", "minus": "-", "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
    ]

    private static let byName = Dictionary(keys, uniquingKeysWith: { a, _ in a })
    private static let byCode = Dictionary(keys.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })

    /// Parses "ctrl+opt+left". Modifier names: ctrl/control/⌃, opt/option/alt/⌥, cmd/command/⌘, shift/⇧.
    public static func parse(_ text: String) throws -> KeyCombo {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        // "ctrl++" means ctrl and the "+" key; treat a trailing empty part as "=" (the + key).
        var modifiers: UInt32 = 0
        var key: UInt32?
        for (i, part) in parts.enumerated() {
            switch part {
            case "ctrl", "control", "⌃": modifiers |= control
            case "opt", "option", "alt", "⌥": modifiers |= option
            case "cmd", "command", "⌘": modifiers |= command
            case "shift", "⇧": modifiers |= shift
            default:
                guard key == nil, i == parts.count - 1 else {
                    throw IPCError.invalidParams("Unrecognized shortcut '\(text)'. Example: ctrl+opt+left")
                }
                let name = part.isEmpty ? "=" : (aliases[part] ?? part)
                guard let code = byName[name] else {
                    throw IPCError.invalidParams("Unknown key '\(part)' in '\(text)'")
                }
                key = code
            }
        }
        guard let key else { throw IPCError.invalidParams("Shortcut '\(text)' has no key") }
        return KeyCombo(keyCode: key, modifiers: modifiers)
    }

    /// Formats as "ctrl+opt+left".
    public static func format(_ combo: KeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers & control != 0 { parts.append("ctrl") }
        if combo.modifiers & option != 0 { parts.append("opt") }
        if combo.modifiers & shift != 0 { parts.append("shift") }
        if combo.modifiers & command != 0 { parts.append("cmd") }
        parts.append(byCode[combo.keyCode] ?? "key\(combo.keyCode)")
        return parts.joined(separator: "+")
    }
}

import Foundation

/// The text formats the color picker copies and `lodestone color convert` writes.
public enum ColorFormat: String, CaseIterable, Codable, Sendable {
    case hex, rgb, hsl, swiftui, nscolor, uicolor

    public var title: String {
        switch self {
        case .hex: "Hex"
        case .rgb: "CSS rgb()"
        case .hsl: "CSS hsl()"
        case .swiftui: "SwiftUI Color"
        case .nscolor: "NSColor"
        case .uicolor: "UIColor"
        }
    }

    /// Accepts the raw value or a few obvious aliases ("css", "swift", "appkit", "uikit").
    public init?(name: String) {
        let n = name.lowercased().filter { $0.isLetter }
        let aliases: [String: ColorFormat] = ["css": .rgb, "rgba": .rgb, "hsla": .hsl, "swift": .swiftui, "color": .swiftui,
                                              "appkit": .nscolor, "uikit": .uicolor]
        guard let format = ColorFormat(rawValue: n) ?? aliases[n] else { return nil }
        self = format
    }
}

/// An sRGB color with components in 0...1.
public struct ColorValue: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(1, max(0, v)) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
        self.alpha = clamp(alpha)
    }

    /// 8-bit channels, rounded.
    public var rgb255: (r: Int, g: Int, b: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    private var hasAlpha: Bool { (alpha * 255).rounded() < 255 }

    // MARK: Formatting

    public func formatted(_ format: ColorFormat) -> String {
        switch format {
        case .hex: return hex
        case .rgb:
            let c = rgb255
            return hasAlpha ? "rgba(\(c.r), \(c.g), \(c.b), \(Self.number(alpha, places: 2)))" : "rgb(\(c.r), \(c.g), \(c.b))"
        case .hsl:
            let (h, s, l) = hsl
            let body = "\(Int(h.rounded()) % 360), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
            return hasAlpha ? "hsla(\(body), \(Self.number(alpha, places: 2)))" : "hsl(\(body))"
        case .swiftui:
            let base = "Color(red: \(Self.number(red)), green: \(Self.number(green)), blue: \(Self.number(blue))"
            return hasAlpha ? base + ", opacity: \(Self.number(alpha)))" : base + ")"
        case .nscolor:
            return "NSColor(srgbRed: \(Self.number(red)), green: \(Self.number(green)), blue: \(Self.number(blue)), alpha: \(Self.number(alpha)))"
        case .uicolor:
            return "UIColor(red: \(Self.number(red)), green: \(Self.number(green)), blue: \(Self.number(blue)), alpha: \(Self.number(alpha)))"
        }
    }

    /// `#ff8800`, or `#ff880080` when not opaque.
    public var hex: String {
        let c = rgb255
        var s = String(format: "#%02x%02x%02x", c.r, c.g, c.b)
        if hasAlpha { s += String(format: "%02x", Int((alpha * 255).rounded())) }
        return s
    }

    /// Hue in degrees 0..<360, saturation and lightness in 0...1.
    public var hsl: (h: Double, s: Double, l: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch maxC {
        case red: h = ((green - blue) / d).truncatingRemainder(dividingBy: 6)
        case green: h = (blue - red) / d + 2
        default: h = (red - green) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(1, s), l)
    }

    public init(hue: Double, saturation s: Double, lightness l: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// Up to `places` decimals, trailing zeros dropped: 1, 0.5, 0.533.
    static func number(_ v: Double, places: Int = 3) -> String {
        var s = String(format: "%.\(places)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    // MARK: Parsing

    /// Reads hex (`#f80`, `#ff8800`, `#ff880080`, `0xff8800`, `ff8800`), CSS `rgb()`/`rgba()`
    /// (commas or spaces, numbers or percentages, `/ alpha`), `hsl()`/`hsla()`, and the Swift forms
    /// this type writes (`Color(red: 1, green: 0.5, blue: 0)`, `NSColor(...)`, `UIColor(...)`).
    public static func parse(_ text: String) throws -> ColorValue {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func fail() -> TextTransformError {
            TextTransformError("Not a color", detail: "expected hex like #ff8800, rgb(255, 136, 0), hsl(32, 100%, 50%) or Color(red: 1, green: 0.533, blue: 0)")
        }
        if let open = t.firstIndex(of: "("), t.hasSuffix(")") {
            let name = t[..<open].trimmingCharacters(in: .whitespaces)
            let inner = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
            switch name {
            case "rgb", "rgba": return try parseRGB(inner) ?? { throw fail() }()
            case "hsl", "hsla": return try parseHSL(inner) ?? { throw fail() }()
            default:
                if inner.contains("red:") { return try parseLabeled(inner) ?? { throw fail() }() }
                throw fail()
            }
        }
        return try parseHex(t) ?? { throw fail() }()
    }

    static func parseHex(_ text: String) -> ColorValue? {
        var s = Substring(text)
        if s.hasPrefix("#") { s = s.dropFirst() } else if s.hasPrefix("0x") { s = s.dropFirst(2) }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy(\.isHexDigit) else { return nil }
        let digits = s.count <= 4 ? s.map { "\($0)\($0)" }.joined() : String(s)
        guard let v = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        return ColorValue(red: Double((v >> (16 + shift)) & 0xFF) / 255, green: Double((v >> (8 + shift)) & 0xFF) / 255,
                          blue: Double((v >> shift) & 0xFF) / 255, alpha: hasAlpha ? Double(v & 0xFF) / 255 : 1)
    }

    /// Splits CSS function arguments: "255, 136, 0", "255 136 0 / 50%", "255,136,0,0.5".
    private static func arguments(_ inner: String) -> [String] {
        inner.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
    }

    /// A number or percentage; percentages are scaled to `percentScale`.
    private static func value(_ s: String, percentScale: Double) -> Double? {
        if s.hasSuffix("%") { return Double(s.dropLast()).map { $0 / 100 * percentScale } }
        return Double(s)
    }

    private static func parseRGB(_ inner: String) -> ColorValue? {
        let a = arguments(inner)
        guard a.count == 3 || a.count == 4 else { return nil }
        guard let r = value(a[0], percentScale: 255), let g = value(a[1], percentScale: 255), let b = value(a[2], percentScale: 255) else { return nil }
        let alpha = a.count == 4 ? value(a[3], percentScale: 1) : 1
        guard let alpha else { return nil }
        return ColorValue(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    private static func parseHSL(_ inner: String) -> ColorValue? {
        let a = arguments(inner)
        guard a.count == 3 || a.count == 4 else { return nil }
        guard let h = Double(a[0].replacingOccurrences(of: "deg", with: "")),
              let s = value(a[1], percentScale: 1), let l = value(a[2], percentScale: 1) else { return nil }
        // Bare numbers for s and l mean percent, as in CSS: hsl(32 100 50).
        let sat = a[1].hasSuffix("%") ? s : s / 100
        let light = a[2].hasSuffix("%") ? l : l / 100
        let alpha = a.count == 4 ? value(a[3], percentScale: 1) : 1
        guard let alpha else { return nil }
        return ColorValue(hue: h, saturation: sat, lightness: light, alpha: alpha)
    }

    /// `red: 1, green: 0.5, blue: 0[, alpha|opacity: 1]`, with an optional `srgbRed:` label.
    private static func parseLabeled(_ inner: String) -> ColorValue? {
        var values: [String: Double] = [:]
        for part in inner.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Double(kv[1]) else { return nil }
            values[kv[0] == "srgbred" ? "red" : kv[0]] = v
        }
        guard let r = values["red"], let g = values["green"], let b = values["blue"] else { return nil }
        return ColorValue(red: r, green: g, blue: b, alpha: values["alpha"] ?? values["opacity"] ?? 1)
    }

    /// Every format by name.
    public var allFormats: [String: String] {
        Dictionary(uniqueKeysWithValues: ColorFormat.allCases.map { ($0.rawValue, formatted($0)) })
    }

    /// The JSON the app and CLI report for a color: every format, the 0...1 components, and
    /// `format`/`value` when one format was asked for.
    public func report(format: ColorFormat? = nil) -> JSONValue {
        var o: [String: JSONValue] = allFormats.mapValues { .string($0) }
        o["red"] = .number(red); o["green"] = .number(green); o["blue"] = .number(blue); o["alpha"] = .number(alpha)
        if let format {
            o["format"] = .string(format.rawValue)
            o["value"] = .string(formatted(format))
        }
        return .object(o)
    }
}

/// The most recent picked colors, newest first, without duplicates.
public struct ColorHistory: Equatable, Sendable {
    public static let limit = 10
    public private(set) var colors: [ColorValue]

    public init(_ colors: [ColorValue] = []) { self.colors = Array(colors.prefix(Self.limit)) }

    /// Stored as hex strings.
    public init(hexStrings: [String]) { self.init(hexStrings.compactMap(ColorValue.parseHex)) }
    public var hexStrings: [String] { colors.map(\.hex) }

    public mutating func add(_ color: ColorValue) {
        colors.removeAll { $0.hex == color.hex }
        colors.insert(color, at: 0)
        if colors.count > Self.limit { colors.removeLast(colors.count - Self.limit) }
    }
}

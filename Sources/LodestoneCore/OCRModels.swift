import Foundation

/// A rectangle in image pixels, origin at the top-left.
public struct OCRBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }
}

/// One line of recognized text.
public struct OCRLine: Codable, Equatable, Sendable {
    public var text: String
    /// 0...1, Vision's confidence in the top candidate.
    public var confidence: Double
    public var box: OCRBox

    public init(text: String, confidence: Double, box: OCRBox) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// A QR code or barcode.
public struct OCRCode: Codable, Equatable, Sendable {
    public var payload: String
    /// "qr", "aztec", "ean13", "code128", "pdf417", "datamatrix", ...
    public var symbology: String
    public var box: OCRBox

    public init(payload: String, symbology: String, box: OCRBox) {
        self.payload = payload
        self.symbology = symbology
        self.box = box
    }

    /// Whether the payload is a web link (http, https).
    public var isLink: Bool {
        let p = payload.lowercased()
        return (p.hasPrefix("http://") || p.hasPrefix("https://")) && !p.contains(" ")
    }

    var kindName: String {
        switch symbology {
        case "qr", "microqr": "QR"
        case "aztec": "Aztec"
        case "pdf417", "micropdf417": "PDF417"
        case "datamatrix": "Data Matrix"
        default: "barcode"
        }
    }
}

/// Text and codes found in one image.
public struct OCRResult: Codable, Equatable, Sendable {
    /// All lines in reading order, with line breaks.
    public var text: String
    public var lines: [OCRLine]
    public var codes: [OCRCode]
    /// Image size in pixels.
    public var width: Int
    public var height: Int
    /// Recognition languages used; empty means automatic detection.
    public var languages: [String]
    /// Recognition time in milliseconds.
    public var ms: Double

    public init(lines: [OCRLine], codes: [OCRCode], width: Int, height: Int, languages: [String], ms: Double) {
        self.lines = lines
        self.codes = codes
        self.width = width
        self.height = height
        self.languages = languages
        self.ms = ms
        text = OCRLayout.text(lines)
    }

    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    public var isEmpty: Bool { text.isEmpty && codes.isEmpty }
}

/// What to copy when an image contains both text and a code.
public enum OCRPreference: String, CaseIterable, Sendable {
    /// The code's payload wins (default: the code is usually the point).
    case code
    /// The text wins; codes are copied only when there is no text.
    case text
    /// Text, then each payload on its own line.
    case both
}

/// What gets copied after a capture, and the toast that confirms it.
public struct OCRClipboard: Equatable, Sendable {
    public var text: String
    public var message: String

    /// Nil when nothing was found.
    public init?(_ result: OCRResult, preference: OCRPreference) {
        let payloads = result.codes.map(\.payload)
        let hasText = !result.text.isEmpty
        let codeMessage: String = {
            guard let first = result.codes.first else { return "" }
            if result.codes.count > 1 { return "Copied \(result.codes.count) codes" }
            return "Copied \(first.kindName) \(first.isLink ? "link" : first.kindName == "barcode" ? "value" : "code")"
        }()
        let words = result.wordCount
        let textMessage = "Copied \(words) word\(words == 1 ? "" : "s")"

        switch (hasText, !payloads.isEmpty) {
        case (false, false): return nil
        case (true, false): text = result.text; message = textMessage
        case (false, true): text = payloads.joined(separator: "\n"); message = codeMessage
        case (true, true):
            switch preference {
            case .code: text = payloads.joined(separator: "\n"); message = codeMessage
            case .text: text = result.text; message = textMessage
            case .both:
                text = ([result.text] + payloads).joined(separator: "\n\n")
                message = "\(textMessage) and \(result.codes.count == 1 ? "a code" : "\(result.codes.count) codes")"
            }
        }
    }
}

/// Puts recognized lines back into reading order.
public enum OCRLayout {
    /// Lines whose vertical centers fall inside the same band form one row, joined left to right with
    /// a space. Rows are separated by a line break, and by a blank line where the gap is wider than
    /// one and a half line heights (a new paragraph).
    public static func text(_ lines: [OCRLine]) -> String {
        let sorted = lines.filter { !$0.text.isEmpty }.sorted { $0.box.y < $1.box.y }
        var rows: [[OCRLine]] = []
        for line in sorted {
            if let last = rows.last, let top = last.map(\.box.y).min(), let bottom = last.map(\.box.maxY).max(),
               line.box.midY >= top, line.box.midY <= bottom {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        guard !rows.isEmpty else { return "" }
        let heights = sorted.map(\.box.height).sorted()
        let typical = heights[heights.count / 2]
        var out = ""
        var previousBottom: Double?
        for row in rows {
            let top = row.map(\.box.y).min()!
            if let previousBottom {
                out += top - previousBottom > typical * 1.5 ? "\n\n" : "\n"
            }
            out += row.sorted { $0.box.x < $1.box.x }.map(\.text).joined(separator: " ")
            previousBottom = row.map(\.box.maxY).max()!
        }
        return out
    }
}

/// Recognition language lists: "en, tr" in settings and `--languages`.
public enum OCRLanguages {
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init).filter { !$0.isEmpty }
    }

    /// Maps each requested code to a supported identifier: exact matches first ("zh-Hant"), then the
    /// first supported identifier with the same language ("en" → "en-US"). Unknown codes are returned
    /// separately so callers can report them.
    public static func resolve(_ requested: [String], supported: [String]) -> (languages: [String], unsupported: [String]) {
        var languages: [String] = []
        var unsupported: [String] = []
        for code in requested {
            let lower = code.lowercased().replacingOccurrences(of: "_", with: "-")
            let match = supported.first { $0.lowercased() == lower }
                ?? supported.first { $0.lowercased().split(separator: "-").first.map(String.init) == lower.split(separator: "-").first.map(String.init) }
            if let match {
                if !languages.contains(match) { languages.append(match) }
            } else {
                unsupported.append(code)
            }
        }
        return (languages, unsupported)
    }
}

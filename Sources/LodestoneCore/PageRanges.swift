import Foundation

/// Page selections like "1-3,5,8-": comma-separated items, each a page ("5"), a range ("1-3"), an
/// open range ("8-" to the end, "-3" from the start), or "last". Pages are 1-based. A reversed range
/// ("5-3") selects pages in reverse order.
public struct PageRanges: Equatable, Sendable {
    public enum Bound: Equatable, Sendable {
        case page(Int)
        case last
    }

    public struct Item: Equatable, Sendable {
        public var from: Bound
        public var to: Bound
    }

    public let items: [Item]

    public init(items: [Item]) { self.items = items }

    /// Every page.
    public static let all = PageRanges(items: [Item(from: .page(1), to: .last)])

    public static func parse(_ text: String) throws -> PageRanges {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.allSatisfy(\.isEmpty) else {
            throw IPCError.invalidParams("No pages given. Use a selection like 1-3,5,8-")
        }
        var items: [Item] = []
        for part in parts {
            guard !part.isEmpty else {
                throw IPCError.invalidParams("Empty item in page selection '\(text)'. Use a selection like 1-3,5,8-")
            }
            items.append(try parseItem(part, in: text))
        }
        return PageRanges(items: items)
    }

    private static func parseItem(_ part: String, in text: String) throws -> Item {
        func bound(_ s: Substring, default value: Bound) throws -> Bound {
            let s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return value }
            if s.lowercased() == "last" { return .last }
            guard let n = Int(s), n >= 1 else {
                throw IPCError.invalidParams("'\(s)' isn't a page number in '\(text)'. Pages start at 1.")
            }
            return .page(n)
        }
        let pieces = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if pieces.count == 1 {
            let b = try bound(pieces[0], default: .last)
            return Item(from: b, to: b)
        }
        if pieces[0].trimmingCharacters(in: .whitespaces).isEmpty && pieces[1].trimmingCharacters(in: .whitespaces).isEmpty {
            throw IPCError.invalidParams("'-' alone isn't a page range in '\(text)'")
        }
        return Item(from: try bound(pieces[0], default: .page(1)), to: try bound(pieces[1], default: .last))
    }

    /// Page numbers for each item, in order. Throws if a page is past the end of the document.
    public func groups(pageCount: Int) throws -> [[Int]] {
        guard pageCount > 0 else { throw IPCError.invalidParams("The document has no pages") }
        func resolve(_ b: Bound) throws -> Int {
            switch b {
            case .last: return pageCount
            case .page(let n):
                guard n <= pageCount else {
                    throw IPCError.invalidParams("Page \(n) is out of range: the document has \(pageCount) page\(pageCount == 1 ? "" : "s").")
                }
                return n
            }
        }
        return try items.map { item in
            let a = try resolve(item.from), b = try resolve(item.to)
            return a <= b ? Array(a...b) : Array((b...a).reversed())
        }
    }

    /// All selected page numbers, flattened, in order.
    public func pages(pageCount: Int) throws -> [Int] {
        try groups(pageCount: pageCount).flatMap { $0 }
    }

    /// Short label for file names: "1-3", "5", "8-12".
    public static func label(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "" }
        if pages.count == 1 { return String(first) }
        let contiguous = first <= last ? pages == Array(first...last) : pages == Array((last...first).reversed())
        return contiguous ? "\(first)-\(last)" : pages.map(String.init).joined(separator: ",")
    }
}

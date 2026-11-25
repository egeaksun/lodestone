import ArgumentParser
import Foundation
import LodestoneCore

/// Options every command shares.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false
}

enum Output {
    /// Prints a result: pretty JSON with --json, otherwise the human-readable text.
    static func emit(_ value: JSONValue, json: Bool, human: (JSONValue) -> String) {
        if json {
            print(value.prettyJSONString)
        } else {
            let text = human(value)
            if !text.isEmpty { print(text) }
        }
    }

    static func emit<T: Encodable>(_ value: T, json: Bool, human: (T) -> String) throws {
        if json {
            print(try JSONValue(encoding: value).prettyJSONString)
        } else {
            let text = human(value)
            if !text.isEmpty { print(text) }
        }
    }

    /// Aligned columns. The last column isn't padded.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { i in all.map { $0.indices.contains(i) ? $0[i].count : 0 }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// A JSON value as plain text: strings unquoted, null as "-".
    static func plain(_ value: JSONValue?) -> String {
        switch value {
        case .none, .some(.null): "-"
        case .some(.string(let s)): s
        case .some(.bool(let b)): b ? "true" : "false"
        case .some(.number(let n)): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .some(let other): other.jsonString
        }
    }
}

extension IPCError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Turns a path argument into an absolute file URL (expands ~, resolves relative to the working directory).
func fileURL(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

import ArgumentParser
import Foundation
import LodestoneCore

/// Selects the window a command acts on. Default: the focused window of the frontmost app.
struct WindowTargetOptions: ParsableArguments {
    @Option(help: "App name or bundle id; acts on its focused (or first) window.") var app: String?
    @Option(help: "Window id from `lodestone window list`.") var window: UInt32?

    var params: [String: JSONValue] {
        var p: [String: JSONValue] = [:]
        if let app { p["app"] = .string(app) }
        if let window { p["window"] = .number(Double(window)) }
        return p
    }
}

struct WindowGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "List, snap, move and focus windows.",
        discussion: "Frames are in points, origin at the top-left of the primary display, y growing down. Displays are numbered 1… from left to right.",
        subcommands: [List.self, Snap.self, Move.self, Focus.self, Actions.self, Displays.self])

    static func describe(_ w: JSONValue) -> String {
        let f = w["frame"]
        let frame = [f?["x"], f?["y"], f?["width"], f?["height"]].map { Output.plain($0) }.joined(separator: ",")
        return "\(Output.plain(w["app"])) — \"\(Output.plain(w["title"]))\" on display \(Output.plain(w["display"])) at \(frame)"
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List windows of running apps.")
        @Option(help: "Only this app (name or bundle id).") var app: String?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let list = try AppConnection.call("window.list", app.map { ["app": .string($0)] })
            Output.emit(list, json: global.json) { l in
                Output.table(["ID", "APP", "DISPLAY", "FRAME (x,y,w,h)", "FLAGS", "TITLE"], (l.array ?? []).map { w in
                    let f = w["frame"]
                    let frame = [f?["x"], f?["y"], f?["width"], f?["height"]].map { Output.plain($0) }.joined(separator: ",")
                    var flags: [String] = []
                    if w["focused"]?.bool == true { flags.append("focused") }
                    if w["minimized"]?.bool == true { flags.append("minimized") }
                    if let s = w["snappedAs"]?.string { flags.append(s) }
                    return [Output.plain(w["id"]), Output.plain(w["app"]), Output.plain(w["display"]), frame,
                            flags.isEmpty ? "-" : flags.joined(separator: ","), Output.plain(w["title"])]
                })
            }
        }
    }

    struct Snap: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Snap a window to a position (see `lodestone window actions`).")
        @Argument(help: "Action, for example leftHalf, lastTwoThirds, sixth3, maximize, center, restore, nextDisplay.") var action: String
        @OptionGroup var target: WindowTargetOptions
        @Option(help: "Put the window on this display (1 = leftmost).") var display: Int?
        @Flag(help: "Behave like a repeated shortcut press: if already there, move to the next display.") var cycle = false
        @OptionGroup var global: GlobalOptions

        func run() throws {
            var p = target.params
            p["action"] = .string(action)
            if let display { p["display"] = .number(Double(display)) }
            if cycle { p["cycle"] = .bool(true) }
            let info = try AppConnection.call("window.snap", .object(p))
            Output.emit(info, json: global.json) { WindowGroup.describe($0) }
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a window's exact frame.")
        @Option(help: "x,y,width,height in points (top-left origin).") var frame: String
        @OptionGroup var target: WindowTargetOptions
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let parts = frame.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { throw ValidationError("--frame expects x,y,width,height") }
            var p = target.params
            p["x"] = .number(parts[0]); p["y"] = .number(parts[1]); p["width"] = .number(parts[2]); p["height"] = .number(parts[3])
            let info = try AppConnection.call("window.move", .object(p))
            Output.emit(info, json: global.json) { WindowGroup.describe($0) }
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Bring a window and its app to the front.")
        @OptionGroup var target: WindowTargetOptions
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let info = try AppConnection.call("window.focus", .object(target.params))
            Output.emit(info, json: global.json) { WindowGroup.describe($0) }
        }
    }

    struct Actions: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List snap actions and their shortcuts.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let list = try AppConnection.call("snap.actions")
            Output.emit(list, json: global.json) { l in
                Output.table(["ACTION", "SHORTCUT", "TITLE"], (l.array ?? []).map {
                    [Output.plain($0["action"]), Output.plain($0["shortcut"]), Output.plain($0["title"])]
                })
            }
        }
    }

    struct Displays: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List displays from left to right.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let list = try AppConnection.call("displays.list")
            Output.emit(list, json: global.json) { l in
                Output.table(["#", "NAME", "FRAME", "VISIBLE FRAME", "MAIN"], (l.array ?? []).map { d in
                    func r(_ v: JSONValue?) -> String { [v?["x"], v?["y"], v?["width"], v?["height"]].map { Output.plain($0) }.joined(separator: ",") }
                    return [Output.plain(d["index"]), Output.plain(d["name"]), r(d["frame"]), r(d["visibleFrame"]), d["main"]?.bool == true ? "yes" : ""]
                })
            }
        }
    }
}

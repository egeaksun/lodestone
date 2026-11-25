# Lodestone

macOS menu bar utility (Swift, AppKit, no SwiftUI): window snapping, plus file conversion, clipboard
and screen tools. The `lodestone` CLI drives the same features over IPC. `ROADMAP.md` lists what's
planned.

## Layout

- `LodestoneCore`: pure logic (geometry, models, text transforms, argument builders). Unit tested.
- `LodestoneKit`: engines shared by app and CLI (log, IPC, external tools, media/document work).
- `Lodestone`: the app. `Framework/` is the plumbing, `Features/<Name>/` one folder per feature.
- `LodestoneCLI`: ArgumentParser commands, one file per feature under `Commands/`.

## Adding a feature

1. `Features/<Name>/<Name>Feature.swift` conforming to `Feature` (`Framework/Feature.swift`); add it to
   `FeatureRegistry`. `Features/Snapping/SnappingFeature.swift` is the worked example.
2. Declare settings as `SettingDefinition`s (key `<feature>.<name>`) and build the Settings tab from
   `SettingsUI` controls bound to those keys.
3. Declare commands as `AppCommand`s (id `<feature>.<name>`) so they get a shortcut, a menu item via
   `context.menuItem(id)` and `lodestone run <id>`.
4. Register IPC methods in `registerIPC` and add a CLI command group in `LodestoneCLI/Commands/`,
   listed in `LodestoneCommand.subcommands`.

**Parity**: everything a person can do in the app, an agent can do through the CLI with `--json`
output. Stateless work (converting a file, transforming text) runs inside the CLI process through
`LodestoneKit`, so it works without the app. Work that needs the app's permissions or state (windows,
clipboard history, screen capture) goes through IPC.

## Rules

- **Idle cost is zero.** Monitors, timers and observers exist only while their feature is enabled and
  needed. Hot paths (mouse events, clipboard polling) do arithmetic only: no Accessibility calls, no
  allocation, no logging. Accessibility and other blocking calls run off the main thread.
- **Log outcomes, not contents.** Every user-visible action and every failure goes to `Log.shared`
  (category = feature id, short stable message, triage data: paths, durations, errors). Clipboard
  text, OCR text and file contents never go in the log.
- Errors crossing IPC are `IPCError` with a stable `code`; messages tell the user what to do next.
- External tools (`ffmpeg`, `cwebp`, `avifenc`, `gs`) are optional: find them with `ExternalTool`,
  and when one is missing, throw `require()`'s install hint.

## Verifying

- `swift build` and `swift test`. Put logic in `LodestoneCore` so it's testable.
- CLI commands that run in-process can be run straight from `.build/debug/lodestone-cli`.
- `make install` replaces /Applications/Lodestone.app, links `~/.local/bin/lodestone`, and resets the
  Accessibility grant (ad-hoc signature). Only one Lodestone may run at a time.
- To check a window or Settings view without launching the app, render it offscreen to a PNG: put the
  window at an off-screen origin, `orderFrontRegardless()`, then `cacheDisplay(in:to:)` on the
  window's frame view.

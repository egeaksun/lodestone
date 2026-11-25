# Lodestone

A macOS menu bar utility: window snapping, plus file conversion, clipboard and screen tools that
macOS is missing. Everything it does is also a `lodestone` command, with `--json` output for scripts
and agents. Features cost nothing while idle.

## Install

```sh
make install   # builds, copies to /Applications, links ~/.local/bin/lodestone, launches
```

Then grant, in System Settings → Privacy & Security:

- **Accessibility**: window snapping, and pasting from clipboard history and Paste as Plain Text.
- **Screen & System Audio Recording**: Copy Text from Screen. Quit and reopen Lodestone after
  turning it on.

Quit Magnet first: both apps register the same snapping shortcuts.

The build is ad-hoc signed, so macOS treats every rebuild as a new app: after `make install`, remove
and re-add Lodestone under Accessibility (and Screen Recording). To avoid that, sign with a stable
certificate: `make install SIGN_ID="Apple Development: …"`.

Optional tools for more formats: `brew install ffmpeg webp libavif ghostscript` (video and audio,
WebP, AVIF, stronger PDF compression). Lodestone works without them and says which one to install
when it needs it.

## Features

| Feature | What it does | Docs |
| --- | --- | --- |
| Window snapping | Shortcuts and drag-to-edge snapping, repeat a shortcut to move across displays | below |
| Converter | Images, video and audio with HandBrake-style presets; resize, compress, strip metadata and location | [docs/converter.md](docs/converter.md) |
| Folder rules | Convert new files in a folder automatically, e.g. screen recordings → MP4 | [docs/rules.md](docs/rules.md) |
| PDF tools | Merge, compress, images → PDF, extract/split, rotate, PDF → images, OCR | [docs/pdf-and-image-tools.md](docs/pdf-and-image-tools.md) |
| Background removal | Cut out an image's subject into a transparent PNG | [docs/pdf-and-image-tools.md](docs/pdf-and-image-tools.md) |
| Clipboard history | Searchable, pinned items, skips passwords; Paste as Plain Text | [docs/clipboard.md](docs/clipboard.md) |
| Copy text from screen | Select a region, get its text or QR code on the clipboard | [docs/screen-and-text.md](docs/screen-and-text.md) |
| Color picker | Pick a screen color as hex, rgb(), hsl(), SwiftUI, NSColor or UIColor | [docs/screen-and-text.md](docs/screen-and-text.md) |
| Clipboard transforms | JSON, Base64, URL, JWT, timestamps, UUIDs, case, hashes, … on the clipboard in place | [docs/screen-and-text.md](docs/screen-and-text.md) |

Lodestone lives in the menu bar and never shows a Dock icon. The menu lists every action with its
current shortcut. Drop files on the menu bar icon, or use Finder's Services menu, for the converter,
PDF and image actions. Settings… (⌘,) has a tab per feature. Activity (never clipboard, OCR or file
contents) is logged for 7 days: `lodestone logs`.

To change a shortcut, click it in Settings and press the new combination. It needs at least one of
⌃ ⌥ ⌘, or an F-key. Press Delete to remove a shortcut, or Escape to cancel. Giving one action a
combination that another action uses takes it from the other action. A shortcut shown in red is
held by another app. Every command can get a shortcut, including each clipboard transform and PDF
action.

## Default shortcuts

| Action | Keys |
| --- | --- |
| Clipboard history | ⌃⌥ V |
| Paste as plain text | ⌃⌥⇧ V |
| Copy text from screen | ⌃⌥⇧ T |
| Pick color | ⌃⌥⇧ C |

Window snapping, taken from the Magnet configuration this replaces (Magnet's defaults plus sixths):
| Action | Keys |
| --- | --- |
| 1/6 … 6/6 (six columns, left to right) | ⌃⌥ 1 2 3 4 5 6 |
| Left / Right / Top / Bottom half | ⌃⌥ ← → ↑ ↓ |
| Top left / Top right / Bottom left / Bottom right | ⌃⌥ U I J K |
| Left / Center / Right third | ⌃⌥ D F G |
| Left / Center / Right two thirds | ⌃⌥ E R T |
| Maximize | ⌃⌥ ↩ |
| Center | ⌃⌥ C |
| Restore | ⌃⌥ ⌫ |
| Next / Previous display | ⌃⌥⌘ → ← |

## Moving across displays

Press a shortcut again on a window that is already in that position, and the window moves to the same
position on the next display. For example, ⌃⌥T puts a window on the right two thirds of the left
monitor; pressing it again moves it to the right two thirds of the center monitor.

- Displays are ordered by where they physically sit, left to right, not by macOS's internal order.
- Left-side positions (left half, left third, sixths 1–3, …) move left. Right-side positions move
  right. Centered positions (maximize, center, center third, …) move right. It wraps around at the
  last display.
- A repeat is detected both from the last action Lodestone applied to the window and from the window's
  frame, so it also works for windows snapped by dragging, or apps that adjust the requested size.
- Restore still returns the window to its size and place from before the first snap.
- ⌃⌥⌘ → / ← move a window to the display on the right or left, keeping its relative position.

Turn it off in Settings → General.

## Drag to snap

Drag a window by its title bar to a screen edge. The zones follow Magnet's default layout: the screen
is a 24 × 12 grid, and the cell along the edge the cursor touches picks the action.

- Corners (one cell each): quarters
- Top edge: maximize
- Left / right edge: top half (upper quarter of the edge), left / right half (middle), bottom half
  (lower quarter)
- Bottom edge, left to right: left third, left two thirds, center third, right two thirds, right third

Portrait screens use a 12 × 24 grid: the side edges stack top half, thirds, two-thirds and bottom half,
and the bottom edge splits into left and right halves.

A snapped window that is dragged away goes back to its previous size.

If macOS's own edge tiling is on, turn it off so the two don't compete: System Settings → Desktop &
Dock → "Drag windows to screen edges to tile".

## Why it doesn't lag

Snapping apps usually make window dragging choppy for one of two reasons:

1. **An active event tap.** With an active `CGEventTap`, the window server hands every mouse event to
   the app and waits for it to return the event before continuing. Any hiccup in that app turns into
   cursor and window stutter.
2. **Accessibility calls per mouse event.** Each AX call is a synchronous IPC round-trip into the app
   that owns the window. Making one on every dragged event (60 to 120 per second) loads both processes.

Lodestone avoids both:

- Mouse input comes from passive `NSEvent` global monitors. These receive copies of events after the
  fact, so the event stream never waits on Lodestone.
- The drag monitor is installed on mouse-down and removed on mouse-up. While idle, Lodestone receives
  nothing but clicks.
- Per dragged event the work is a point-in-rectangle test against a cached screen layout.
- A drag gesture makes about three AX calls in total (find the window under the cursor, confirm it is
  moving, set its frame), all on a background queue with a 0.3 s timeout. A hung app can't stall the
  cursor or the overlay.
- Position and size are read in one round-trip (`AXUIElementCopyMultipleAttributeValues`).
- The preview overlay is one reused, layer-backed window with no blur and no animation. It is only
  touched when the target zone changes.
- Shortcuts use Carbon `RegisterEventHotKey`: the system matches the key combination itself, with no
  keyboard event tap.
- `AXEnhancedUserInterface` is switched off while resizing, so Chromium and Electron apps don't
  animate the resize.

## Command line

`lodestone` drives every feature. Conversions, PDF work, OCR of files and text transforms run inside
the CLI process, so they work without the app. Windows, clipboard history, screen capture, the color
picker and folder rules go through the running app (started if needed). Every command takes `--json`.

```sh
lodestone --help                 # command groups
lodestone methods                # every IPC method with its parameters
lodestone commands               # every shortcut-able command; run one with `lodestone run <id>`
lodestone window snap leftHalf   # windows and displays
lodestone convert clip.mov --to mp4 --preset share      # docs/converter.md
lodestone presets list
lodestone rules add ~/Desktop --kinds video --to mp4 --match 'Screen Recording*'   # docs/rules.md
lodestone pdf merge a.pdf b.pdf -o both.pdf             # docs/pdf-and-image-tools.md
lodestone image remove-background photo.jpg --crop
lodestone clipboard history --search invoice            # docs/clipboard.md
lodestone ocr screenshot.png                            # docs/screen-and-text.md
lodestone text json-pretty < response.json
lodestone color convert '#ff8800' --to swiftui
lodestone shortcuts list         # and `shortcuts set <id> ctrl+opt+x`
lodestone settings list          # and `settings set <key> <value>`
lodestone logs --since 2h --category converter
```

## Icons

`Assets/AppIcon.svg` and `Assets/MenuBarIcon.svg` are the sources, generated by
`scripts/generate-icon-svgs.py`. The stone is 11 flat facets, hand-traced from a generated reference
illustration. It sits on a porcelain-white squircle; `copper`, `silver` and `midnight` frames are also
built in (pass the name as the script's second argument). The menu bar icon uses the same
facets as alpha levels, so macOS can tint it for light and dark menu bars. `make icons` regenerates them and renders `Resources/AppIcon.icns`
and the menu bar template PNGs with AppKit's SVG support. The rendered files are committed, so a
normal build doesn't need this step.

## Layout

- `Sources/LodestoneCore`: pure logic (snap geometry, presets and ffmpeg arguments, folder rule
  matching, text transforms, colors, page ranges, clipboard history), unit tested with `make test`.
- `Sources/LodestoneKit`: engines shared by the app and the CLI: log, IPC, external tools, converter,
  PDF, background removal, OCR, clipboard store, folder watcher.
- `Sources/Lodestone`: the app. `Framework/` is the plumbing, `Features/<Name>/` one folder per feature.
- `Sources/LodestoneCLI`: the `lodestone` command, one file per command group.

`AGENTS.md` describes how to add a feature. `ROADMAP.md` lists what's planned.

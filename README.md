# Lodestone

A menu bar window snapper for macOS, written to cost nothing while windows are being moved.

## Install

```sh
make install   # builds, copies to /Applications, launches
```

On first launch, grant Accessibility access (System Settings → Privacy & Security → Accessibility).
Quit Magnet first: both apps register the same shortcuts.

The build is ad-hoc signed, so macOS treats every rebuild as a new app and the Accessibility grant
has to be removed and re-added after `make install`. To avoid that, sign with a stable certificate:
`make install SIGN_ID="Apple Development: …"`.

## Shortcuts

Taken from the Magnet configuration this replaces (Magnet's defaults plus sixths).

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

## Layout

- `Sources/LodestoneCore`: pure geometry (snap rectangles, edge zones, coordinate conversion), unit
  tested with `make test`.
- `Sources/Lodestone`: the app (Accessibility, hotkeys, drag tracking, overlay, menu).

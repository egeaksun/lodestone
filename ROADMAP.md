# Roadmap

Quick utilities macOS is missing. Each ships with Settings, shortcuts where they make sense, a
`lodestone` CLI command group and activity logging.

## Done

- Window snapping: shortcuts, drag to edges, cycling across displays (`lodestone window`)
- Activity log, 7-day retention (`lodestone logs`)
- CLI over IPC (`lodestone --help`, `lodestone methods`)

## Now: files and media

1. Converter: images, video and audio with HandBrake-style presets. Drop on the menu bar icon,
   Finder service, menu. Defaults in Settings.
2. Image quick fixes: resize, compress, strip metadata and location, remove background.
3. PDF tools: merge, compress, images to PDF.
4. Automatic conversion: folder rules, for example new screen recordings become small MP4s.

## Now: clipboard and text

5. Clipboard history: searchable, pinned items, skips passwords.
6. Paste as plain text.
7. Copy text (and QR codes) from any region of the screen.
8. Clipboard transforms for development: JSON format/minify, Base64, URL, JWT decode, timestamps,
   UUIDs, case conversion.
9. Screen color picker: hex, RGB, SwiftUI.

## Later

- Saved window layouts per display setup, restored when displays reconnect
- Window switcher (per window, with previews)
- External display brightness and volume keys (DDC)
- Move the cursor to the next display / find the cursor
- Keep awake with a timer
- Global microphone mute with an indicator
- Menu bar calendar
- Quick capture into the Obsidian inbox
- Hide menu bar icons behind the notch (fragile on macOS 15)

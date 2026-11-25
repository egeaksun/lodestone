# Roadmap

Quick utilities macOS is missing. Each ships with Settings, shortcuts where they make sense, a
`lodestone` CLI command group and activity logging.

## Done

- Window snapping: shortcuts, drag to edges, cycling across displays (`lodestone window`)
- Activity log, 7-day retention (`lodestone logs`)
- CLI over IPC (`lodestone --help`, `lodestone methods`)
- Converter: images, video and audio with HandBrake-style presets; drop on the menu bar icon, Finder
  service, menu; defaults in Settings (`lodestone convert`, `lodestone presets`)
- Image quick fixes: resize, compress, strip metadata and location (converter presets), remove
  background (`lodestone image`)
- PDF tools: merge, compress, images to PDF, extract/split, rotate, PDF to images, OCR (`lodestone pdf`)
- Automatic conversion: folder rules, e.g. new screen recordings become MP4s (`lodestone rules`)
- Clipboard history: searchable, pinned items, skips passwords (`lodestone clipboard`)
- Paste as plain text
- Copy text and QR codes from any region of the screen (`lodestone ocr`)
- Clipboard transforms: JSON, Base64, URL, JWT, timestamps, UUIDs, case, hashes (`lodestone text`)
- Screen color picker: hex, rgb(), hsl(), SwiftUI, NSColor, UIColor (`lodestone color`)

## Later

- Saved window layouts per display setup, restored when displays reconnect
- Window switcher (per window, with previews)
- External display brightness and volume keys (DDC)
- Move the cursor to the next display / find the cursor
- Keep awake with a timer
- Global microphone mute with an indicator
- Menu bar calendar
- Quick capture into a notes inbox (Obsidian, Apple Notes)
- Hide menu bar icons behind the notch (fragile on macOS 15)

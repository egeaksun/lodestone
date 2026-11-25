# Changelog

All notable changes to Lodestone. Versions follow [semantic versioning](https://semver.org); each release on
GitHub is built from a `v*` tag by the release workflow, and its notes come from this file.

## [0.3.0] - 2026-11-25

The first public release: Lodestone grows from a window snapper into a set of everyday utilities.

### Added

- **Converter**: images, video and audio with HandBrake-style presets (Instant, High quality, Balanced, Small
  file, Share), custom presets, a Convert panel, quick actions and a Finder service. WebP, AVIF, HEVC, ProRes,
  WebM, FLAC up to 24-bit/96 kHz. Resize, compress and strip metadata and location from photos.
  `lodestone convert`, `lodestone presets`.
- **Folder rules**: convert new files in a folder automatically, e.g. screen recordings to MP4.
  `lodestone rules`.
- **PDF tools**: merge, compress, images to PDF, extract and split, rotate, export pages as images, OCR.
  `lodestone pdf`.
- **Background removal** for photos, with Vision. `lodestone image`.
- **Clipboard history**: searchable, pinned items, skips passwords; **Paste as Plain Text**.
  `lodestone clipboard`.
- **Copy text from the screen**, including QR codes and barcodes. `lodestone ocr`.
- **Color picker** with hex, rgb(), hsl(), SwiftUI, NSColor and UIColor output. `lodestone color`.
- **Clipboard transforms**: JSON, Base64, URL, HTML, JWT, timestamps, UUIDs, case, lines, hashes.
  `lodestone text`.
- **Drop shelf**: shake files while dragging them to get Lodestone's actions without the menu bar.
- Universal build (Apple silicon and Intel).

### Changed

- Snapping shows the Accessibility dialog once per launch instead of on every shortcut press.

## [0.2.0]

- Window snapping with shortcuts and drag-to-edge, cycling across displays.
- 7-day activity log, `lodestone` CLI over IPC, settings registry and the feature framework.

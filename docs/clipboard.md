# Clipboard

Lodestone keeps a history of what you copy and can paste anything as plain text. macOS has neither.

## Clipboard history

Press **⌃⌥V** (or choose **Clipboard History** in the menu bar menu) to open the history panel next to
the pointer. The app you were in stays in front, so whatever you pick is pasted there.

| Key | Action |
| --- | --- |
| Type | Filter the list (case-insensitive; every word must match the text, a file name or the source app) |
| ↑ / ↓ | Move the selection |
| Return, or double-click | Paste the item |
| ⌥Return, or ⌥double-click | Paste as plain text |
| ⌘1 … ⌘9 | Paste the first nine items (add ⌥ for plain text) |
| ⌘P | Pin or unpin |
| ⌘⌫, or ⌫ while the search field is empty | Delete the item |
| Esc | Clear the search, then close |

Each row shows a preview (the first two lines of text, an image thumbnail, or the file icon and names),
the app it was copied from, how long ago, and a pin badge.

Recorded: plain text, formatted text (RTF and HTML are kept, so pasting keeps the formatting), images
(stored as PNG, up to 15 MB) and files (Finder copies; the paths are kept, not the files).

Not recorded:

- Anything an app marks as concealed, transient or auto-generated (the
  [nspasteboard.org](http://nspasteboard.org) markers). Password managers mark passwords this way.
- Copies made while an ignored app is in front. By default: 1Password, Bitwarden, Keychain Access and
  Passwords. Edit the list in Settings → Clipboard.
- Single copies over 20 MB.
- Anything copied while history is paused.

Copying something that's already in history moves it to the top. Pasting from history does too.

### Pausing

Menu bar → **Pause Clipboard History** → for 15 minutes, for an hour, or until resumed. The menu shows
**Resume Clipboard History** while paused. A pause ends when Lodestone quits.

### Limits and storage

- **Items to keep** (default 200) and **Storage limit** (default 256 MB) apply to unpinned items; the
  oldest go first. Pinned items are never removed by the limits.
- History is stored in `~/Library/Application Support/Lodestone/Clipboard/`: `index.json` plus one file
  per stored representation, all readable only by you (0600).
- **Keep history across restarts** (default on). Turned off, history is kept in memory only, and the
  files on disk are deleted.
- **Clear Clipboard History…** (menu bar or Settings) removes everything except pinned items; tick the
  checkbox in the dialog to remove those too.

Turning history off stops recording; the existing history stays until you clear it.

## Paste as plain text

Press **⌃⌥⇧V** (or choose **Paste as Plain Text**) to paste the clipboard without formatting. Lodestone
replaces the clipboard with its plain text, pastes, and after a moment puts the original formatted
contents back, so a later ⌘V still pastes with formatting. Turn off **Restore the clipboard after Paste
as Plain Text** to leave the plain text on the clipboard instead. Copying files and pasting them as
plain text pastes their paths.

Pasting needs Accessibility access (Settings → General). Without it, picking an item from history
copies it and shows a notification asking you to press ⌘V.

## Command line

Every command takes `--json`. `get` and `set` work on the clipboard directly and don't need the app;
the rest use the app's history (the CLI starts the app if needed).

```sh
lodestone clipboard get                     # the clipboard as plain text
lodestone clipboard set "some text"         # or: echo hi | lodestone clipboard set; --file notes.txt
lodestone clipboard history --limit 10      # newest first; --search "invoice march"
lodestone clipboard paste 3                 # paste into the frontmost app; --plain for plain text
lodestone clipboard copy 3                  # put it on the clipboard without pasting
lodestone clipboard pin 3                   # also: unpin, delete
lodestone clipboard clear                   # keeps pinned items; --include-pinned removes them too
lodestone clipboard pause --minutes 15      # omit --minutes to pause until resumed
lodestone clipboard resume
lodestone clipboard status
```

Items are named by id (`3f9a1c0b7e21`), a unique id prefix (`3f9a`), or position (`1` is the newest;
numbers up to four digits are positions).

Settings: `clipboard.enabled`, `clipboard.maxItems`, `clipboard.maxStorageMB`, `clipboard.persist`,
`clipboard.ignoredApps` (comma-separated bundle ids) and `clipboard.restoreAfterPlainPaste`, through
`lodestone settings`. Commands for shortcuts and `lodestone run`: `clipboard.history`,
`clipboard.pastePlain`, `clipboard.togglePause`.

IPC methods: `clipboard.status`, `clipboard.history`, `clipboard.paste`, `clipboard.copy`,
`clipboard.pin`, `clipboard.delete`, `clipboard.clear`, `clipboard.pause`, `clipboard.resume`
(`lodestone methods` lists their parameters).

## Logging

Pastes, pins, deletes, clears, pauses and ignored-app skips are logged with the item's kind and size
only. Individual captures are logged at debug level (`LODESTONE_DEBUG=1`). Clipboard contents are never
logged.

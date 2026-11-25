# Folder rules

A folder rule converts new files automatically. For example, new screen recordings on the Desktop
become MP4s, or screenshots get compressed. Rules use the [converter](converter.md)'s formats and
presets, and write next to the original unless you choose another folder. Lodestone never replaces
an existing file.

## How it works

- Lodestone watches each enabled rule's folder with FSEvents. The system tells it when files change,
  so nothing runs while the folders are quiet. With no enabled rules, nothing is watched at all.
- A new file is converted once it has finished being written: its size has to stay the same for
  about 1.5 seconds. Screen recordings, downloads and copies grow for a while first.
- Only new files count. Files that were already in the folder are left alone; use **Run Now** (or
  `lodestone rules run`) to convert those.
- Rules convert one file at a time, in the background. Progress shows in the menu bar with Cancel.
  A notification says what was converted (Settings can turn that off); failures always notify.

A file is skipped when:

| Reason | Why |
|--------|-----|
| hidden | Its name, or a folder on its path, starts with a dot. macOS writes screenshots as hidden files first. |
| partial download | It ends in `.crdownload`, `.download`, `.part`, `.partial`, `.tmp`, `.icloud` or `.opdownload`. |
| in subfolder | It's in a folder inside the watched folder, and the rule doesn't include subfolders. |
| name does not match | The rule has a name pattern and the file doesn't match it. |
| not a matching kind | It isn't an image, video or audio file of a kind the rule converts. |
| already in target format | It's already in the rule's format, for example an MP4 for a rule that makes MP4s. This also keeps a rule from converting its own output. |

## A rule

| Field | Meaning |
|-------|---------|
| Folder | The folder to watch. |
| Include subfolders | Also watch the folders inside it. |
| File names | A pattern with `*` (anything) and `?` (one character), not case-sensitive, for example `Screen Recording*`. Empty matches any name. |
| Convert | Images, video, audio: which kinds of file the rule takes. |
| To | The target format, or "Same format" (useful for images with Compress or Resize). |
| Preset | A converter preset, or the default for the kind and format. |
| Save to | Next to the original, or a folder you choose. |
| Originals | Keep them, or move them to the Trash after a successful conversion. |

## Settings

Settings → Folder Rules lists the rules. Click a rule's checkbox to turn it on or off, and
double-click it to edit. **Add Rule…** offers a blank rule and templates:

- **Screen Recordings → MP4**: files named `Screen Recording*` in your screenshot folder (Screenshot
  app → Options → Save to, else the Desktop) become MP4 with the Balanced preset.
- **Screenshots → compressed**: files named `Screenshot*` are re-encoded with the Compress preset,
  keeping their format.

"Convert new files in watched folders automatically" pauses or resumes every rule at once. The menu
bar menu has a Folder Rules submenu with the same switch and a checkmark per rule. The command
`rules.toggle` (no default shortcut) pauses and resumes from a shortcut or `lodestone run rules.toggle`.

| Setting | Default |
|---------|---------|
| `rules.enabled` | true |
| `rules.notify` | true |

Rules themselves are stored in `~/Library/Application Support/Lodestone/rules.json`, readable only
by you.

## CLI

The app owns the watcher, so these commands go through it (and start it if needed). Every command
takes `--json`. Rules are named by id or a unique id prefix.

```sh
# Screen recordings on the Desktop become MP4s.
lodestone rules add ~/Desktop --kinds video --to mp4 --preset balanced --match 'Screen Recording*'

# Compress screenshots into a separate folder and trash the originals.
lodestone rules add ~/Desktop --kinds image --to same --preset compress --match 'Screenshot*' \
  --output-dir ~/Pictures/Screenshots --trash-originals

lodestone rules list
lodestone rules edit 3f2a --preset small-file --no-trash-originals
lodestone rules disable 3f2a
lodestone rules enable 3f2a
lodestone rules run 3f2a --dry-run     # what's already in the folder, and why files are skipped
lodestone rules run 3f2a               # convert those files now
lodestone rules status                 # watched folders, files settling or queued
lodestone rules remove 3f2a
```

`add` and `edit` take `--kinds`, `--to`, `--preset`, `--match`, `--output-dir`, `--name`,
`--[no-]subfolders` and `--[no-]trash-originals`. In `edit`, `--match ''`, `--output-dir ''` and
`--preset default` clear those fields.

IPC methods: `rules.list`, `rules.status`, `rules.add`, `rules.update`, `rules.remove` and
`rules.run`. See `lodestone methods` for their parameters.

## Log

Category `rules`:

- `watch.start`, `watch.stop`, `watch.missing_folder`
- `rule.added`, `rule.updated`, `rule.removed`
- `match`
- `convert.done`, `convert.failed`, `convert.cancelled`, with the rule, the input and output paths,
  the sizes and the duration
- `run`, `run.dry`

The converter also logs each conversion under `converter`.

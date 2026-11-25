# Converter

Lodestone converts images, video and audio from the menu bar or the `lodestone` CLI. It works like a
small HandBrake: pick a format and a preset, open Customize if you want to change anything, and
convert. Converted files go next to the originals. Lodestone never replaces an existing file.

## Ways in

- **Convert Files…** in the menu bar menu (command `converter.open`, no default shortcut) opens the
  Convert panel.
- **Drop files on the menu bar icon.** You get these actions, depending on what you dropped:
  - "Convert…" opens the panel with the files added.
  - "Convert to MP4" (videos only) converts right away.
  - "Convert to WebP" (images only) converts right away.
  - "Compress Images" (images only) re-encodes at quality 65 and keeps each image's format.
- **Finder.** Right-click files, then Services, then "Convert with Lodestone". This opens the panel.
- **The CLI.** `lodestone convert` runs inside the CLI process, so the app doesn't need to be running.

Quick actions use the defaults from Settings and show progress in the menu bar, with Cancel.

## The Convert panel

Drop files or folders on the list, or use + and −. With nothing selected, − clears the finished rows.
Each kind of media in the list gets its own row with a format and a preset. Customize shows every
option for each row. Changing an option marks the row "(customized)". Save as Preset… keeps those
settings for next time.

Video converts one file at a time. Images and audio convert in parallel next to it. Each row shows
its progress. Cancel stops the batch and removes partial files. Show in Finder selects the results.

## Formats

| From  | To |
|-------|----|
| Image | PNG, JPEG, HEIC, WebP, AVIF, TIFF, GIF |
| Video | MP4, MOV, WebM, animated GIF, and audio only: M4A, MP3, WAV, AIFF, FLAC, Opus |
| Audio | M4A (AAC or ALAC), MP3, WAV, AIFF, FLAC, Opus |

Images keep their format by default ("Same as original"), so Compress and Resize do what you'd
expect. Video defaults to MP4 and audio to M4A. You can change these defaults in Settings.

What does the work:

- macOS ImageIO writes PNG, JPEG, HEIC, TIFF and GIF.
- `cwebp` writes WebP and `avifenc` writes AVIF. Without them, ffmpeg writes AVIF. The Homebrew ffmpeg
  can't write WebP, so WebP needs `cwebp` (`brew install webp`).
- ffmpeg handles video and audio. The default encoders are the hardware ones (VideoToolbox H.264 and
  HEVC). x264 and x265 are slower and make smaller files.
- Without ffmpeg, MP4, MOV and M4A still work through AVFoundation, with Apple's fixed presets. Quality,
  frame rate and audio options don't apply then.

`lodestone convert formats` lists what's available on this Mac.

## Presets

Video:

| Preset | What it does |
|---|---|
| `instant` | Instant (same quality). Copies the streams into the new container without re-encoding, for example MOV to MP4 with H.264 and AAC. It takes seconds. Audio the container can't hold becomes AAC 256 kbps. It fails if the video codec doesn't fit, such as VP9 into MP4. |
| `high-quality` | HEVC on the hardware encoder at quality 80. Original size and audio. |
| `balanced` | Default. H.264 on the hardware encoder at quality 65, AAC 192 kbps. Plays everywhere. |
| `small-file` | x265 at quality 50, up to 1080p, AAC 128 kbps. Slow, smallest. |
| `share` | MP4, H.264 up to 1080p at quality 50, AAC 128 kbps, no metadata. |

Images:

| Preset | What it does |
|---|---|
| `standard` | Default. Quality 85. |
| `compress` | Quality 65. |
| `resize-50` | Half the width and height. |
| `resize-2048` | Longest edge at most 2048 px. |
| `strip-metadata` | Removes EXIF, GPS and XMP. If the format stays the same and nothing is resized, the pixels are copied untouched. |

Audio:

| Preset | What it does |
|---|---|
| `audio-high` | AAC 256, MP3 V0, Opus 192. |
| `audio-standard` | Default for lossy formats. AAC 192, MP3 V2, Opus 128. |
| `audio-small` | AAC 128, MP3 V5, Opus 96. |
| `lossless` | Default for WAV, AIFF and FLAC. Keeps the source's sample rate and bit depth. |
| `cd-quality` | 16-bit, 44.1 kHz. |
| `studio-24-48` | 24-bit, 48 kHz. |
| `hires-24-96` | 24-bit, 96 kHz. |

Your own presets live in `~/Library/Application Support/Lodestone/presets.json`. The app and the CLI
both read that file, so a preset saved in one shows up in the other. A saved preset gets an id made
from its name ("Web Clips" becomes `web-clips`). Built-in presets can't be replaced or deleted.

## Options

Every option overrides the preset.

- **Quality** runs from 0 (smallest) to 100 (best). Each encoder gets its own scale. H.264 and HEVC on
  hardware use `-q:v` with the same number. x264 uses CRF 44 down to 11 (65 gives CRF 23, x264's
  default). x265 sits about 4 CRF higher. VP9 and AV1 use their CRF ranges. ProRes picks Proxy, LT,
  422 or HQ. JPEG, HEIC, WebP and AVIF use the number as is.
- **Max size.** `1080` means 1080p for video, measured on the shorter edge, so portrait phone videos
  work too. For images it's the longest edge. `1920x1080` fits inside a box and `50%` scales. Nothing
  is ever enlarged.
- **Frame rate** is a cap. A 30 fps clip stays at 30 when you pick 60.
- **Audio** for video can be Keep original, AAC 128/192/256, or Remove. Keep falls back to AAC
  256 kbps when the container can't hold the source audio. WebM gets Opus.
- **Remove metadata** drops EXIF, GPS and tags. Images keep their color profile, Display P3 included.
- **Sample rate** can be original, 44.1, 48, 88.2 or 96 kHz. MP3 stops at 48 kHz, and Opus always plays
  at 48 kHz.
- **Bit depth** applies to WAV, AIFF, FLAC and ALAC. You can pick 16, 24 or 32-bit float (WAV and AIFF
  only). Lodestone keeps the source's depth unless you pick one. Lossy sources become 16-bit. Going
  down to 16-bit adds triangular dither. FLAC and ALAC can't store float, so a float source becomes
  24-bit and you get a note.
- **Channels** can be original, mono or stereo.

Photos stored sideways (EXIF orientation) come out upright after a resize. For WebP and AVIF from such
a photo, ImageIO renders an upright copy first, and only the color profile survives that step.

## Output names

`clip.mov` to MP4 becomes `clip.mp4`. If that name is taken, Lodestone writes `clip (converted).mp4`,
then `clip (converted 2).mp4`, and so on. The same goes for files in one batch that would collide. A
file never replaces its own source. The CLI's `--overwrite` replaces other existing files.

Settings → Converter chooses the location: next to the original, Downloads, or a folder you pick.

## Settings

| Key | Values | Default |
|---|---|---|
| `converter.imageFormat` | `same`, png, jpeg, heic, webp, avif, tiff, gif | `same` |
| `converter.imagePreset` | an image preset id | `standard` |
| `converter.videoFormat` | mp4, mov, webm, gif, m4a, mp3, wav, aiff, flac, opus | `mp4` |
| `converter.videoPreset` | a video preset id | `balanced` |
| `converter.audioFormat` | m4a, mp3, wav, aiff, flac, opus | `m4a` |
| `converter.audioPreset` | an audio preset id | `audio-standard` |
| `converter.outputLocation` | `source`, `downloads`, `folder` | `source` |
| `converter.outputFolder` | a path | empty |
| `converter.afterConvert` | `reveal`, `notify`, `nothing` | `notify` |
| `converter.originals` | `keep`, `trash` | `keep` |

If a preset doesn't suit the chosen format (a video preset when video is set to MP3), the format's
default preset is used. Failures always post a notification, whatever `afterConvert` says.

## CLI

```sh
lodestone convert clip.mov                        # MP4, Balanced
lodestone convert clip.mov --preset instant       # remux, no re-encode
lodestone convert *.heic --to webp --quality 80
lodestone convert photo.jpg --preset strip-metadata
lodestone convert mix.wav --to flac --bit-depth 24 --sample-rate 96000
lodestone convert talk.mp4 --to mp3               # just the audio
lodestone convert clip.mov --to webm --codec av1 --max-size 720 --dry-run
lodestone convert formats
```

Options: `--to`, `--preset`, `--quality`, `--max-size 1080|WxH|50%|original`,
`--codec h264|hevc|x264|x265|prores|vp9|av1|aac|alac`, `--fps`,
`--audio copy|aac128|aac192|aac256|remove`, `--bitrate`, `--sample-rate`, `--bit-depth 16|24|32f`,
`--channels`, `--strip-metadata`, `--output-dir`, `--overwrite`, `--trash-originals`, `--dry-run`,
`--json`.

Progress goes to stderr and results to stdout. `--json` prints one object per input with `output`,
`engine`, `remux`, `bytesIn`, `bytesOut`, `seconds` and `warnings`, or an `error` with a `code` and a
`message`. `--dry-run` prints the plan and the exact ffmpeg, cwebp or avifenc command without running
it. The exit status is 1 if any file failed. Ctrl-C stops the batch and removes partial files.

Presets:

```sh
lodestone presets list [--kind video]
lodestone presets show balanced
lodestone presets save "Web Clips" --from share --max-size 720 --quality 45
lodestone presets save "Masters" --kind audio --to flac --bit-depth 24
lodestone presets delete web-clips
```

The app also takes `converter.open {"paths": [...]}` over IPC, which opens the panel with those files:
`lodestone call converter.open '{"paths": ["~/Movies/clip.mov"]}'`.

## Log

Entries use the `converter` category: `convert.start`, `convert.done` (with seconds and sizes),
`convert.failed` (with ffmpeg's exit code and its last stderr lines) and `convert.cancelled`. Each one
records the input, output, format, preset and engine. See them with
`lodestone logs --category converter`.

## For later: folder rules

The engine has no UI. A rule is a `ConvertRequest` built from a folder's new files, with a
`ConvertTarget` (format, preset, overrides) per kind, run through `Converter.shared.convert(_:events:)`.

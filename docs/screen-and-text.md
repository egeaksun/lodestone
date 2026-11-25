# Screen text, color picker and text transforms

Three tools for working with what's on screen and on the clipboard. Their settings and shortcuts
are in **Settings → Screen & Text**.

## Copy text from the screen

Press **⌃⌥⇧T** (or choose **Copy Text from Screen** in the menu bar menu), then drag over the part of
the screen you want. Press Space to pick a whole window, or Esc to cancel. Lodestone reads the text
with Apple's Vision framework, keeps the line breaks, and copies it. A confirmation such as
"Copied 42 words" appears next to the pointer.

QR codes and barcodes are decoded too. When a region contains both text and a code, the
**Text and a code** setting decides what gets copied: the code (the default), the text, or both.

The first capture asks for **Screen Recording** permission. If you turned it down, Lodestone shows a
button that opens System Settings → Privacy & Security → Screen & System Audio Recording. After
switching Lodestone on there, quit and reopen it.

Settings:

| Key | Values | Default |
| --- | --- | --- |
| `screen.ocrAccuracy` | `accurate`, `fast` (Latin scripts only) | `accurate` |
| `screen.ocrLanguages` | comma-separated codes such as `en, de, zh-Hant`; empty means detect automatically | empty |
| `screen.whenBoth` | `code`, `text`, `both` | `code` |
| `screen.showToasts` | show the confirmation near the pointer (failures beep when it's off) | `true` |

Vision reads English, French, Italian, German, Spanish, Portuguese, Chinese (Simplified,
Traditional, Cantonese), Korean, Japanese, Russian, Ukrainian, Thai, Vietnamese and Arabic.
`lodestone ocr --list-languages` prints the exact codes. Codes it doesn't know are ignored, and the
log records them.

From the command line:

```sh
lodestone ocr receipt.jpg                 # text and codes from image files (no app needed)
lodestone ocr a.png b.png --languages en,de --json
lodestone ocr --screen                    # select a region, print its text
lodestone ocr --screen --region 0,0,800,600 --copy --json
```

`--json` gives each line's text, confidence (0–1) and bounding box in pixels with the origin at the
top-left, plus every code's payload, symbology and box. For files the output is an array with one
entry per file; for `--screen` it is a single object. `--region` is in points, from the top-left of
the main display, the same coordinates `lodestone window list` uses.

## Color picker

Press **⌃⌥⇧C** (or choose **Pick Color**) and click anywhere to sample a pixel; Esc cancels. The color
is copied in the format set under **Copy colors as**:

| Format | Example |
| --- | --- |
| `hex` | `#ff8800` (`#ff880080` with transparency) |
| `rgb` | `rgb(255, 136, 0)` |
| `hsl` | `hsl(32, 100%, 50%)` |
| `swiftui` | `Color(red: 1, green: 0.533, blue: 0)` |
| `nscolor` | `NSColor(srgbRed: 1, green: 0.533, blue: 0, alpha: 1)` |
| `uicolor` | `UIColor(red: 1, green: 0.533, blue: 0, alpha: 1)` |

Colors are converted to sRGB. The last ten appear under **Recent Colors** in the menu. Each one has
a submenu listing every format, so you can copy it again in a different format.

```sh
lodestone color pick                       # waits for your click, prints every format
lodestone color pick --format swiftui --copy
lodestone color convert '#ff8800' --to hsl
lodestone color convert 'rgb(255 136 0 / 50%)' --json
lodestone color history
```

`color convert` runs without the app. It reads hex, `rgb()`/`rgba()`, `hsl()`/`hsla()` and the Swift
forms above.

## Transform the clipboard

**Transform Clipboard** in the menu bar menu replaces the clipboard's text with the result. When the
input doesn't fit the transform, a short message appears instead ("Not valid JSON") and the
clipboard is left alone.

| Name | What it does |
| --- | --- |
| `json-pretty`, `json-pretty-sorted` | Indent JSON with two spaces. Key order, numbers and escapes stay as written, unless you sort the keys. |
| `json-minify` | Remove all whitespace from JSON. |
| `json-escape`, `json-unescape` | Convert text to and from the inside of a JSON string literal. |
| `base64-encode`, `base64-decode` | Base64 of the UTF-8 text. Decoding accepts both alphabets, with or without padding. |
| `base64-url-encode`, `base64-url-decode` | URL-safe Base64 without padding. |
| `url-encode`, `url-decode` | Percent-encoding. Everything except letters, digits and `- . _ ~` is encoded. |
| `html-encode`, `html-decode` | HTML entities (`&amp;`, `&#39;`, `&#x1F389;`, common named ones). |
| `jwt-decode` | The header and payload of a JWT, pretty-printed, with `iat`/`nbf`/`exp` as dates. The signature is **not** verified. |
| `timestamp` | Unix time to ISO 8601 in UTC, or the other way. Seconds, milliseconds, microseconds and nanoseconds are detected from the number's size. |
| `uuid` | A new random UUID (v4). Ignores the input. |
| `camel-case`, `pascal-case`, `snake-case`, `kebab-case`, `constant-case`, `title-case` | Identifier case, line by line. `HTTPServer` splits into HTTP + Server. |
| `upper-case`, `lower-case` | Upper or lower case. |
| `trim` | Remove leading and trailing whitespace. |
| `collapse-whitespace` | Turn every run of whitespace, line breaks included, into one space. |
| `sort-lines`, `dedupe-lines`, `reverse-lines` | Line operations. Sorting ignores case and orders numbers naturally (file2 before file10). |
| `count` | Characters, words and lines. Shown, not copied. |
| `md5`, `sha1`, `sha256` | Hex digest of the UTF-8 text. |

None of them has a shortcut by default. Assign one in **Settings → Screen & Text → Text Transform
Shortcuts**, or run `lodestone shortcuts set text.jsonPretty ctrl+opt+j`. Command ids are
`text.` followed by the camelCase name: `text.jsonPretty`, `text.base64UrlDecode`, `text.sha256`.

From the command line, transforms run without the app:

```sh
lodestone text list
echo '{"b":1,"a":2}' | lodestone text json-pretty-sorted
lodestone text timestamp 1700000000          # 2023-11-14T22:13:20Z
lodestone text jwt-decode --clipboard        # read the clipboard, write the result back
lodestone text count --json < notes.txt
```

## Privacy

The activity log (`lodestone logs`) records what ran and how it went: transform names, character
counts, recognition time, the color format. It never records clipboard text, recognized text or
colors. Screen captures are written to `~/Library/Caches/app.lodestone.Lodestone` and deleted once
they have been read. The confirmation is kept out of screenshots and screen recordings.

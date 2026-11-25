"""Builds docs/Lodestone-Guide.pdf's HTML: every feature and every default shortcut, on six A4 pages.

    lodestone shortcuts list --json > /tmp/shortcuts.json      # needs the app running
    python3 scripts/build-guide.py /tmp/shortcuts.json /tmp/guide.html
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --no-pdf-header-footer \
        --print-to-pdf=docs/Lodestone-Guide.pdf file:///tmp/guide.html

Or just `make guide`. Shortcuts come from each command's default, so the guide never shows one Mac's
customizations.
"""
import base64, json, plistlib, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
shortcuts = {s["id"]: {**s, "shortcut": s.get("default")} for s in json.load(open(sys.argv[1]))}
OUT = Path(sys.argv[2])
VERSION = plistlib.load(open(ROOT / "Resources/Info.plist", "rb"))["CFBundleShortVersionString"]
with tempfile.TemporaryDirectory() as tmp:
    png = Path(tmp) / "icon.png"
    subprocess.run(["sips", "-s", "format", "png", "-Z", "256", str(ROOT / "Resources/AppIcon.icns"), "--out", str(png)],
                   capture_output=True, check=True)
    icon = base64.b64encode(png.read_bytes()).decode()

SYM = {"ctrl": "⌃", "opt": "⌥", "shift": "⇧", "cmd": "⌘", "left": "←", "right": "→", "up": "↑", "down": "↓",
       "return": "↩", "delete": "⌫", "esc": "esc", "space": "space", "tab": "⇥"}


def keys(combo):
    """'ctrl+opt+shift+v' -> keycaps."""
    if not combo:
        return '<span class="none">not set</span>'
    parts = combo.split("+")
    return "".join(f'<kbd>{SYM.get(p, p.upper())}</kbd>' for p in parts)


def caps(*labels):
    return "".join(f"<kbd>{l}</kbd>" for l in labels)


def sc(cid):
    return keys(shortcuts[cid].get("shortcut"))


def isc(cid):
    """Inline: the keys, or a note that there's no default."""
    combo = shortcuts[cid].get("shortcut")
    return keys(combo) if combo else '<span class="none">(no default shortcut)</span>'


def rows(items):
    return "".join(f"<tr><td>{a}</td><td class='k'>{b}</td></tr>" for a, b in items)


def table(items, head=("Action", "Keys"), cls=""):
    return f"<table class='{cls}'><thead><tr><th>{head[0]}</th><th>{head[1]}</th></tr></thead><tbody>{rows(items)}</tbody></table>"


def plain(items, cls=""):
    return f"<table class='plain {cls}'><tbody>" + "".join(f"<tr><td>{a}</td><td>{b}</td></tr>" for a, b in items) + "</tbody></table>"


snap = lambda ids: [(shortcuts[i]["title"], sc(i)) for i in ids]

transforms = [
    ("JSON", "Pretty-print, pretty-print with sorted keys, minify, escape as JSON string, unescape"),
    ("Encode &amp; decode", "Base64, Base64 URL-safe, URL, HTML entities, JWT (header + payload, dates readable), Unix timestamp ↔ ISO 8601"),
    ("Case", "camelCase, PascalCase, snake_case, kebab-case, CONSTANT_CASE, Title Case, UPPERCASE, lowercase"),
    ("Whitespace &amp; lines", "Trim, collapse whitespace, sort lines, remove duplicate lines, reverse lines"),
    ("Hash", "MD5, SHA-1, SHA-256"),
    ("Other", "New UUID, count characters / words / lines"),
]

html = f"""<!doctype html><html><head><meta charset="utf-8"><title>Lodestone Guide</title>
<style>
@page {{ size: A4; margin: 16mm 15mm 16mm 15mm; }}
:root {{ --ink:#1d1d1f; --muted:#6e6e73; --line:#e3e3e8; --accent:#b4572a; --soft:#f6f5f3; --key:#fbfbfd; }}
* {{ box-sizing: border-box; }}
body {{ font: 10.2pt/1.45 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; color: var(--ink); margin: 0; }}
h1 {{ font: 700 30pt/1.1 -apple-system, "SF Pro Display", sans-serif; margin: 0; letter-spacing: -0.02em; }}
h2 {{ font: 700 15pt/1.2 -apple-system, "SF Pro Display", sans-serif; margin: 0 0 8px; letter-spacing: -0.01em;
      padding-bottom: 6px; border-bottom: 2px solid var(--accent); }}
h3 {{ font: 650 11pt/1.3 -apple-system, sans-serif; margin: 12px 0 5px; break-after: avoid; }}
p {{ margin: 4px 0 8px; }}
.muted {{ color: var(--muted); }}
section {{ break-before: page; }}
.cover {{ display: flex; align-items: center; gap: 18px; margin: 4px 0 14px; }}
.cover img {{ width: 78px; height: 78px; }}
.cover .sub {{ color: var(--muted); font-size: 11.5pt; margin-top: 4px; }}
kbd {{ display: inline-block; min-width: 19px; padding: 1px 5px; margin: 0 1.5px; text-align: center;
       font: 600 9pt/1.5 -apple-system, "SF Pro Text", sans-serif; color: var(--ink);
       background: var(--key); border: 1px solid #c9c9cf; border-bottom-width: 2px; border-radius: 5px; }}
.none {{ color: #aeaeb2; font-size: 8.5pt; font-style: italic; }}
table {{ width: 100%; border-collapse: collapse; margin: 4px 0 10px; break-inside: avoid; }}
th {{ text-align: left; font-size: 8pt; text-transform: uppercase; letter-spacing: .06em; color: var(--muted);
      font-weight: 600; padding: 3px 6px; border-bottom: 1px solid var(--line); }}
td {{ padding: 3px 6px; border-bottom: 1px solid var(--line); vertical-align: top; }}
td.k {{ white-space: nowrap; width: 1%; text-align: right; }}
table.plain td:first-child {{ width: 30%; font-weight: 600; }}
.grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 0 18px; }}
.hero {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; margin: 8px 0 14px; }}
.card {{ background: var(--soft); border-radius: 10px; padding: 9px 11px; break-inside: avoid; }}
.card b {{ display: block; font-size: 10.5pt; margin-bottom: 3px; }}
.card .keys {{ margin: 2px 0 3px; }}
.card .keys kbd {{ font-size: 10.5pt; min-width: 23px; padding: 2px 6px; }}
.card span.d {{ color: var(--muted); font-size: 9pt; }}
.note {{ background: #fff6ef; border-left: 3px solid var(--accent); padding: 7px 10px; border-radius: 4px; margin: 8px 0; font-size: 9.4pt; }}
code {{ font: 8.8pt/1.4 "SF Mono", Menlo, monospace; background: var(--soft); padding: 0 3px; border-radius: 3px; }}
pre {{ font: 8.3pt/1.5 "SF Mono", Menlo, monospace; background: var(--soft); padding: 8px 10px; border-radius: 8px;
       white-space: pre-wrap; margin: 4px 0 10px; break-inside: avoid; }}
pre .c {{ color: var(--muted); }}
ul {{ margin: 3px 0 8px; padding-left: 17px; }} li {{ margin: 2px 0; }}
.zone {{ display: grid; grid-template-columns: 150px 1fr 150px; grid-template-rows: 24px 38px 24px; gap: 3px;
         width: 100%; font-size: 7.6pt; text-align: center; margin: 6px 0 10px; }}
.zone div {{ background: var(--soft); border: 1px solid var(--line); border-radius: 5px; display: flex;
             align-items: center; justify-content: center; padding: 2px; line-height: 1.15; }}
.zone .mid {{ background: #fff; color: var(--muted); }}
.footer {{ color: var(--muted); font-size: 8.5pt; margin-top: 14px; }}
</style></head><body>

<div class="cover">
  <img src="data:image/png;base64,{icon}">
  <div><h1>Lodestone</h1>
  <div class="sub">Everything it does, and every shortcut you can use</div>
  <div class="muted" style="font-size:8.5pt;margin-top:3px">Lodestone {VERSION} · default shortcuts · github.com/egeaksun/lodestone</div></div>
</div>

<p>Lodestone lives in the menu bar (no Dock icon). Its menu lists every action with its current shortcut, and
<b>Settings…</b> <kbd>⌘</kbd><kbd>,</kbd> has a tab per feature. Every feature is also a <code>lodestone</code> command in Terminal.</p>

<h3>The shortcuts you'll use most</h3>
<div class="hero">
  <div class="card"><b>Clipboard history</b><div class="keys">{sc('clipboard.history')}</div><span class="d">Searchable list of everything you copied; pinned items stay.</span></div>
  <div class="card"><b>Paste as plain text</b><div class="keys">{sc('clipboard.pastePlain')}</div><span class="d">Pastes without formatting, then puts the formatted copy back.</span></div>
  <div class="card"><b>Copy text from screen</b><div class="keys">{sc('screen.copyText')}</div><span class="d">Drag over any region: its text or QR code goes to the clipboard.</span></div>
  <div class="card"><b>Pick a color</b><div class="keys">{sc('color.pick')}</div><span class="d">Click any pixel: hex, rgb(), hsl() or Swift code on the clipboard.</span></div>
  <div class="card"><b>Snap left / right half</b><div class="keys">{sc('leftHalf')} &nbsp; {sc('rightHalf')}</div><span class="d">Press again to move the window to the next display.</span></div>
  <div class="card"><b>Maximize · Center · Restore</b><div class="keys">{sc('maximize')} {sc('center')} {sc('restore')}</div><span class="d">Restore returns the window to where it was before snapping.</span></div>
  <div class="card"><b>Drop shelf</b><div class="keys"><span class="d" style="font-size:10pt;color:var(--ink)">Drag files + shake</span></div><span class="d">A drop target appears at the pointer with every action for those files.</span></div>
  <div class="card"><b>Next / previous display</b><div class="keys">{sc('nextDisplay')} &nbsp; {sc('previousDisplay')}</div><span class="d">Keeps the window's relative position.</span></div>
</div>

<h3>Permissions</h3>
<table class="plain"><tbody>
<tr><td>Accessibility</td><td>Window snapping, and pasting (clipboard history, paste as plain text). System Settings → Privacy &amp; Security → Accessibility.</td></tr>
<tr><td>Screen Recording</td><td>Copy Text from Screen. Privacy &amp; Security → Screen &amp; System Audio Recording, then quit and reopen Lodestone.</td></tr>
<tr><td>Notifications</td><td>Optional: “done” messages for conversions, PDFs and folder rules.</td></tr>
</tbody></table>
<div class="note">Lodestone is signed ad hoc, so macOS treats every update or rebuild as a new app and forgets both grants: turn Lodestone on again in both lists afterwards.</div>

<h3>Changing shortcuts</h3>
<p>Settings → any tab with shortcuts: click a shortcut and press the new combination (it needs ⌃, ⌥ or ⌘, or an F-key).
<kbd>⌫</kbd> removes it, <kbd>esc</kbd> cancels. A shortcut shown in red is taken by another app. <b>Every</b> command below can get a shortcut,
including each PDF action and each clipboard transform; the ones marked <span class="none">not set</span> have none by default.
From Terminal: <code>lodestone shortcuts set pdf.merge ctrl+opt+m</code>.</p>

<section>
<h2>Window snapping</h2>
<div class="grid">
<div>
<h3>Halves &amp; quarters</h3>
{table(snap(['leftHalf','rightHalf','topHalf','bottomHalf','topLeft','topRight','bottomLeft','bottomRight']))}
<h3>Thirds</h3>
{table(snap(['firstThird','centerThird','lastThird','firstTwoThirds','centerTwoThirds','lastTwoThirds']))}
</div>
<div>
<h3>Sixths (six columns, left to right)</h3>
{table(snap(['sixth1','sixth2','sixth3','sixth4','sixth5','sixth6']))}
<h3>Window</h3>
{table(snap(['maximize','center','restore','nextDisplay','previousDisplay']))}
</div>
</div>

<h3>Moving across displays</h3>
<ul>
<li>Press a shortcut again on a window that's already in that position, and it moves to the same position on the next display.
Example: {sc('lastTwoThirds')} puts a window on the right two thirds; press it again and it moves to the right two thirds of the next monitor.</li>
<li>Left-side positions move left, right-side positions move right, centered ones move right. It wraps around at the last display.</li>
<li>Displays are ordered by where they physically sit, left to right.</li>
</ul>

<h3>Drag to snap</h3>
<p>Drag a window by its title bar to a screen edge. A preview shows where it will land.</p>
<div class="zone">
  <div>Top-left quarter</div><div>Maximize</div><div>Top-right quarter</div>
  <div>Left edge: top half · left half · bottom half</div><div class="mid">screen</div><div>Right edge: top half · right half · bottom half</div>
  <div>Bottom-left quarter</div><div>Bottom edge: ⅓ · ⅔ · center ⅓ · ⅔ · ⅓</div><div>Bottom-right quarter</div>
</div>
<p class="muted">Dragging a snapped window away gives it back its previous size. Turn off macOS's own tiling so the two don't compete
(System Settings → Desktop &amp; Dock → “Drag windows to screen edges to tile”). Drag snapping and display cycling can be switched off in Settings → General.</p>
</section>

<section>
<h2>Files: convert, compress, PDFs</h2>
<h3>Three ways to hand files to Lodestone</h3>
<table class="plain"><tbody>
<tr><td>Drop shelf</td><td>Start dragging files anywhere, then <b>shake</b> the pointer left and right a few times. A “Drop for Lodestone” target appears next to the pointer; drop on it and pick an action. Works with the menu bar hidden. <span class="muted">The Show Drop Shelf command opens it without a drag {isc('shelf.show')}.</span></td></tr>
<tr><td>Menu bar icon</td><td>Drop files on the Lodestone icon; a menu lists the actions for them.</td></tr>
<tr><td>Finder</td><td>Right-click files → Quick Actions or Services → <b>Lodestone Actions…</b> (all actions), or a direct one such as Compress PDF or Convert with Lodestone.</td></tr>
</tbody></table>

<h3>What's offered for which files</h3>
<table><thead><tr><th>Files</th><th style="text-align:left">Actions</th></tr></thead><tbody>
<tr><td>Videos</td><td>Convert… (panel), Convert to MP4</td></tr>
<tr><td>Images</td><td>Convert… (panel), Convert to WebP, Compress Images, Remove Background, Images to PDF</td></tr>
<tr><td>Audio</td><td>Convert… (panel)</td></tr>
<tr><td>One PDF</td><td>Compress, Extract or Split Pages, Rotate Pages, Export Pages as Images, Make Searchable (OCR)</td></tr>
<tr><td>Two or more PDFs</td><td>Merge PDFs, plus the actions above</td></tr>
</tbody></table>

<h3>Converter <span class="muted" style="font-weight:400">· menu → Convert Files…</span></h3>
<p>Like a compact HandBrake: a file list, a format and preset per kind of media, a <b>Customize</b> section with every option, then Convert.
Results go next to the originals; an existing file is never replaced (“clip (converted).mp4”).</p>
<table><thead><tr><th>From</th><th style="text-align:left">To</th></tr></thead><tbody>
<tr><td>Images</td><td>PNG, JPEG, HEIC, WebP, AVIF, TIFF, GIF</td></tr>
<tr><td>Video</td><td>MP4 (H.264/HEVC), MOV (also ProRes), WebM (VP9/AV1), animated GIF, or audio only</td></tr>
<tr><td>Audio</td><td>M4A (AAC/ALAC), MP3, WAV, AIFF, FLAC, Opus — sample rate and 16/24/32-bit float for lossless</td></tr>
</tbody></table>
<div class="grid">
<div>{plain([('Video presets','Instant (no re-encode), High quality, Balanced, Small file, Share (≤1080p)'),
             ('Image presets','Standard, Compress, Resize 50%, Resize to 2048 px, Strip metadata (EXIF + location)')])}</div>
<div>{plain([('Audio presets','Lossless (original), High 256k, Standard 192k, Small 128k, CD 16/44.1, Studio 24/48, Hi-res 24/96'),
             ('Your own','Customize, then Save as Preset… (also <code>lodestone presets save</code>)')])}</div>
</div>

</section>

<section>
<h2>PDF tools, images and folder rules</h2>
<h3>PDF tools <span class="muted" style="font-weight:400">· menu → PDF Tools ▸, the drop shelf, or Finder</span></h3>
<p>None of these has a default shortcut; give the ones you use a shortcut in Settings → PDF → Shortcuts.
Options (compression level, page size) are asked in a small dialog with “Don't ask again”; defaults live in Settings.</p>
{table([('Merge PDFs', sc('pdf.merge')), ('Compress PDF (light / balanced / strong; keeps text selectable)', sc('pdf.compress')),
        ('Images to PDF (fit, A4 or Letter, with margin)', sc('pdf.fromImages')), ('Extract or split pages (“1-3,5,8-”)', sc('pdf.extract')),
        ('Rotate pages', sc('pdf.rotate')), ('Export pages as PNG/JPEG', sc('pdf.toImages')), ('Make searchable (adds a text layer)', sc('pdf.ocr')),
        ('Remove background from an image (transparent PNG)', sc('image.removeBackground'))])}

<h3>Folder rules <span class="muted" style="font-weight:400">· Settings → Folder Rules</span></h3>
<p>Convert new files automatically, e.g. new screen recordings on the Desktop become MP4s.</p>
{plain([('Set one up', 'Settings → Folder Rules → <b>Add Rule…</b>, then a blank rule or a template: <i>Screen Recordings → MP4</i> or <i>Screenshots → compressed</i>.'),
        ('A rule has', 'A folder (optionally with subfolders), a name pattern like <code>Screen Recording*</code>, the kinds of file (images, video, audio), a format and preset, where to save (next to the original or a folder), and whether to move originals to the Trash.'),
        ('When it runs', 'A new file is converted once it has finished being written (its size stops changing). Hidden files, partial downloads and files already in the target format are skipped, so a rule never converts its own output.'),
        ('Existing files', 'Left alone. Select the rule and press <b>Run Now</b> to convert what’s already in the folder (it lists the files first).'),
        ('On / off', 'Each rule has a checkbox; the menu’s Folder Rules ▸ pauses them all. ' + isc('rules.toggle'))])}
<h3>Background removal</h3>
<p>Drop an image and choose <b>Remove Background</b> (or Image Tools ▸ in the menu). The subject is cut out into
“name (no background).png” with transparency; optionally cropped to the subject (Settings → Image).</p>
</section>

<section>
<h2>Clipboard and screen</h2>
<div class="grid">
<div>
<h3>Clipboard history {sc('clipboard.history')}</h3>
<p>Opens next to the pointer; the app you were in stays in front. Type to search.</p>
{table([('Move', caps('↑') + caps('↓')), ('Paste the selected item', caps('↩')), ('Paste it as plain text', caps('⌥', '↩')),
        ('Quick-paste item 1–9', caps('⌘', '1') + '–' + caps('9')), ('Pin / unpin', caps('⌘', 'P')),
        ('Delete', caps('⌘', '⌫')), ('Delete (search field empty)', caps('⌫')), ('Close', caps('esc')), ('Paste with the mouse', 'double-click')])}
<ul>
<li>Keeps text, rich text, images and files, with the app it came from.</li>
<li>Skips passwords: items marked concealed by password managers, and anything copied while 1Password, Bitwarden, Keychain Access or Passwords is in front (editable list).</li>
<li>Pinned items are never removed by the item or size limits.</li>
<li>Menu: Pause Clipboard History (15 minutes, 1 hour, until resumed) and Clear Clipboard History….</li>
</ul>
<h3>Paste as plain text {sc('clipboard.pastePlain')}</h3>
<p>Pastes the clipboard without fonts, colors or links, then restores the formatted version so <kbd>⌘</kbd><kbd>V</kbd> still pastes it with formatting.</p>
</div>
<div>
<h3>Copy text from screen {sc('screen.copyText')}</h3>
<p>Drag over a region (or press <kbd>space</kbd> and click a window). Its text goes to the clipboard with line breaks kept;
a QR code or barcode gives its contents instead (Settings → Screen &amp; Text decides which wins when there are both).
<kbd>esc</kbd> cancels. A small confirmation appears near the pointer.</p>
<h3>Color picker {sc('color.pick')}</h3>
<p>A magnifier follows the pointer; click a pixel. The color is copied in your chosen format; <kbd>esc</kbd> cancels.</p>
{plain([('Formats','<code>#ff8800</code> · <code>rgb(255, 136, 0)</code> · <code>hsl(32, 100%, 50%)</code> · SwiftUI <code>Color(red:green:blue:)</code> · <code>NSColor(…)</code> · <code>UIColor(…)</code>'),
        ('Recent Colors ▸','The last 10 colors in the menu; each can be copied again in any format.')])}
<h3>Clipboard transforms</h3>
<p>Menu → <b>Transform Clipboard ▸</b> replaces the clipboard's text with the result. Each is a command you can give a shortcut
(Settings → Screen &amp; Text).</p>
{plain(transforms)}
</div>
</div>
</section>

<section>
<h2>Command line</h2>
<p><code>lodestone</code> is in <code>~/.local/bin</code>. Every command takes <code>--json</code>. Conversions, PDFs, OCR of files and text
transforms run in Terminal without the app; windows, clipboard history, screen capture, colors and folder rules go through the app
(it's started if needed). <code>lodestone help &lt;command&gt;</code> shows every option.</p>
<pre><span class="c"># Discover</span>
lodestone --help                                lodestone commands
lodestone status                                lodestone methods
lodestone shortcuts list                        lodestone settings list

<span class="c"># Windows</span>
lodestone window list                           lodestone window snap leftHalf --app Safari

<span class="c"># Convert</span>
lodestone convert clip.mov --to mp4 --preset share
lodestone convert *.png --to webp --quality 80
lodestone convert song.wav --to flac --sample-rate 96000 --bit-depth 24
lodestone convert clip.mov --dry-run            <span class="c"># show the exact ffmpeg command</span>
lodestone convert formats                       lodestone presets list

<span class="c"># Folder rules</span>
lodestone rules add ~/Desktop --kinds video --to mp4 --match 'Screen Recording*'
lodestone rules list                            lodestone rules run &lt;id&gt; --dry-run
lodestone rules disable &lt;id&gt;                    lodestone rules status

<span class="c"># PDF and images</span>
lodestone pdf merge a.pdf b.pdf -o both.pdf     lodestone pdf compress big.pdf --level strong
lodestone pdf from-images *.jpg --page-size a4  lodestone pdf extract doc.pdf --pages 1-3,5
lodestone pdf ocr scan.pdf                      lodestone pdf info doc.pdf
lodestone image remove-background photo.jpg --crop

<span class="c"># Clipboard</span>
lodestone clipboard history --search invoice    lodestone clipboard paste 2 --plain
lodestone clipboard get                         echo hi | lodestone clipboard set

<span class="c"># Text, OCR, color</span>
lodestone text json-pretty &lt; response.json      lodestone text list
lodestone text base64-decode --clipboard        <span class="c"># reads and writes the clipboard</span>
lodestone ocr screenshot.png                    lodestone ocr --screen
lodestone color pick --format swiftui           lodestone color convert '#ff8800' --to hsl

<span class="c"># Shortcuts, settings, log</span>
lodestone shortcuts set pdf.merge ctrl+opt+m    lodestone run color.pick
lodestone settings set clipboard.maxItems 500   lodestone logs --since 2h --category converter</pre>

<h3>Good to know</h3>
<ul>
<li><b>Nothing is overwritten.</b> Results get a new name next to the original; the CLI replaces files only with <code>‑‑overwrite</code>.</li>
<li><b>Optional tools</b> add formats: <code>brew install ffmpeg webp libavif ghostscript</code> (video/audio, WebP, AVIF, stronger PDF compression). Without them Lodestone says what to install.</li>
<li><b>Activity log</b>, kept 7 days: <code>lodestone logs</code> or Settings → General → Open Logs Folder. It records what happened (files, sizes, errors) — never clipboard, OCR or file contents.</li>
<li><b>Zero idle cost.</b> Features use no CPU while you're not using them; clipboard history checks one number twice a second.</li>
</ul>
</section>
</body></html>
"""
OUT.write_text(html)
print("ok")

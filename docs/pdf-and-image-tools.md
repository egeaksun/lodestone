# PDF and image tools

Lodestone can merge, compress, split, rotate and OCR PDFs, turn images into a PDF, export pages as
images, and remove the background behind a photo's subject. Everything runs on your Mac. Nothing is
uploaded.

## Where to find them

- **Drop files on the menu bar icon.** Lodestone offers the actions that fit the files: two or more
  PDFs can be merged; any PDFs can be compressed, rotated, exported as images or made searchable; a
  single PDF can have pages extracted; images can become a PDF or lose their background.
- **Finder**: select files, then right-click › Services (or Quick Actions): *Merge PDFs*, *Compress
  PDF*, *Images to PDF*, *Extract or Split PDF Pages…*, *Rotate PDF Pages…*, *Export PDF Pages as
  Images*, *Make PDF Searchable (OCR)*, *Remove Background*.
- **Menu bar menu**: *PDF Tools ▸* and *Image Tools ▸*. Each item asks you to pick files first.
- **Shortcuts**: Settings › PDF › Shortcuts, and Settings › Image. None are set by default.

Progress shows next to the menu bar icon, and the menu has a Cancel item while a job runs.

## Results

Results are saved next to the original and never replace an existing file:

| Tool | Result |
| --- | --- |
| Merge | `Report (merged).pdf`, named after the first file |
| Compress | `Report (compressed).pdf` |
| Images to PDF | `Photo (images).pdf`, named after the first image (`Photo.pdf` for a single image) |
| Extract | `Report (pages 1-3).pdf`, `Report (page 5).pdf` |
| Rotate | `Report (rotated).pdf` |
| Export pages | a folder `Report (pages)` with `Report page 01.png`, … |
| OCR | `Report (searchable).pdf` |
| Remove background | `Photo (no background).png` |

If the name is taken, a number is added: `Report (compressed 2).pdf`. When a job is done, Lodestone
reveals the result in Finder, shows a notification, or does nothing, as set in Settings ("When done").

When you drop or select several files, the app merges them, and builds Images to PDF, in name order
(the order Finder lists them). The CLI uses the order you give.

## Options

Compress, Images to PDF, Export Pages and Remove Background ask for their options each time, with
your defaults preselected. Tick **Don't ask again** to use the chosen options from then on; change
them, or turn asking back on, in Settings. Extract and Rotate always ask, since the pages differ per
file.

### Compression

| Level | For | Images resampled to |
| --- | --- | --- |
| Light | printing | 225 dpi |
| Balanced (default) | screen and email | 150 dpi |
| Strong | smallest file | 96 dpi |

Only images are re-compressed: text and vector drawings stay as they are, so text stays sharp and
selectable. With [Ghostscript](https://ghostscript.com) installed (`brew install ghostscript`),
Lodestone uses it. Without Ghostscript it uses macOS's built-in PDF compression, which works but
gives you less control (Balanced and Strong come out the same). If the compressed file isn't
smaller, Lodestone keeps the original, writes nothing, and tells you.

Password-protected PDFs can't be processed. Open them in Preview, enter the password and export an
unlocked copy first.

### Images to PDF

- **Page size**: *Fit to Image* (each page is the size of its image, using the image's own
  resolution, or 72 dpi when it has none), *A4* or *US Letter*. A4 and Letter pages turn sideways
  for landscape images. Images larger than the page are scaled down to fit, smaller ones keep their
  size, and each image is centered.
- **Margin**: none, ¼, ½ or 1 inch (any value from 0 to 144 points in Settings).

JPEG images are embedded as they are, without re-compression.

### Pages

Page selections look like `1-3,5,8-`: single pages, ranges, `8-` (from 8 to the end), `-3` (from
the start to 3) and `last`. A reversed range such as `5-3` gives the pages in reverse order.
Extract can save the selection as one PDF, one PDF per range, or one PDF per page.

### Remove background

This uses Vision's subject detection (macOS 14 or later) and works best on photos with a clear
foreground subject: people, pets, objects. All detected subjects are kept. *Crop to the subject*
trims the transparent area around it. If no subject is found, nothing is written and you get a
message saying so.

## Command line

The CLI runs these tools itself, so the app doesn't need to be running. Every command takes `--json`.

```sh
lodestone pdf merge a.pdf b.pdf c.pdf -o combined.pdf
lodestone pdf compress report.pdf --level strong          # light | balanced | strong
lodestone pdf compress *.pdf -o smaller/                   # several files into a folder
lodestone pdf compress report.pdf --engine pdfkit          # auto (default) | gs | pdfkit
lodestone pdf from-images scan1.jpg scan2.jpg --page-size a4 --margin 36 -o scans.pdf
lodestone pdf extract report.pdf --pages 1-3,5 -o summary.pdf
lodestone pdf split report.pdf                             # one file per page
lodestone pdf split report.pdf --pages 1-4,5-9,10- -o parts/   # one file per range
lodestone pdf rotate report.pdf --angle 90 --pages 2,4     # clockwise; -90 for counterclockwise
lodestone pdf to-images report.pdf --format jpeg --dpi 300 --pages 1
lodestone pdf info report.pdf                              # pages, size, encryption, text layer
lodestone pdf ocr scan.pdf                                 # add a selectable text layer
lodestone image remove-background photo.jpg --crop -o cutout.png
```

Without `-o`, results go next to the input as described above. An `-o` path that already exists is
refused, except for a folder, which receives the result under its usual name. Errors exit with
status 1 and a message saying what to do. With `--json`, failures still print `Error: …` on stderr.

`pdf compress --json` reports `originalBytes`, `compressedBytes`, `saved` (a fraction), `engine`
(`gs` or `pdfkit`) and `keptOriginal`. When `keptOriginal` is true, `output` is null.

### Through the app (IPC)

The same operations are available as IPC methods for `lodestone call`. When an option is left out,
they use your defaults from Settings: `pdf.merge`, `pdf.compress`, `pdf.fromImages`, `pdf.extract`,
`pdf.rotate`, `pdf.toImages`, `pdf.info`, `pdf.ocr`, `image.removeBackground`. Run
`lodestone methods` for their parameters.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `pdf.compressionLevel` | `balanced` | `light`, `balanced` or `strong` |
| `pdf.askCompressionLevel` | `true` | Ask for the level each time |
| `pdf.pageSize` | `fit` | Images to PDF: `fit`, `a4` or `letter` |
| `pdf.margin` | `0` | Images to PDF margin in points (0–144) |
| `pdf.askPageSize` | `true` | Ask for page size and margin each time |
| `pdf.imageFormat` | `png` | Export Pages: `png` or `jpeg` |
| `pdf.imageDPI` | `150` | Export Pages resolution (36–600) |
| `pdf.askImageExport` | `true` | Ask for format and resolution each time |
| `pdf.afterward` | `reveal` | When done: `reveal`, `notify` or `nothing` |
| `image.cropToSubject` | `false` | Remove Background: crop to the subject |
| `image.askBackgroundOptions` | `true` | Ask each time |
| `image.afterward` | `reveal` | When done: `reveal`, `notify` or `nothing` |

Change them in Settings, or with `lodestone settings set pdf.compressionLevel strong`.

## Troubleshooting

Every run is logged with its inputs, outputs, sizes, duration and engine (never file contents):
`lodestone logs --category pdf` or `--category image`. Messages are `<operation>.start`,
`.done`, `.failed` and `.cancelled`, for example `compress.done`.

# FC Dock

**Convert any file without opening an app.** Select a file in Finder, hold **⇧ Shift**, and a ring of formats appears around your cursor. Click one, and the converted copy lands right next to the original.

- Works from Finder, with one file or many
- About 100 input formats: documents, images, audio, spreadsheets, presentations, data, subtitles and archives
- 300 conversions work out of the box using what ships with macOS. Free Homebrew tools unlock more.
- Lives in the menu bar: no Dock icon, no windows in the way
- A dashboard to tune the wheel's size, glass, gaps and timing

## Requirements

- macOS 13 Ventura or later
- An Apple Silicon or Intel Mac (when built from source, it builds for whichever Mac you're on)

## Install

### Option A: Build from source (recommended)

An app you build yourself isn't blocked by macOS, so this is the smoothest route.

1. Install Apple's command-line tools, if you don't have them (about 1 GB, one time):
   ```bash
   xcode-select --install
   ```
2. Download this repository, either with **Code → Download ZIP** on GitHub (then unzip it) or with git:
   ```bash
   git clone https://github.com/YOUR-USERNAME/Mac_FC_dock.git
   ```
3. Build it from inside the folder:
   ```bash
   cd Mac_FC_dock
   ./scripts/build-app.sh
   ```
4. Move **`build/FC Dock.app`** into your **Applications** folder and open it. A small icon appears in the menu bar.

### Option B: Download the ready-made app

If the repository has a **Releases** page, download `FC Dock.zip` from it, unzip it, and move **FC Dock.app** into Applications.

The app isn't notarised by Apple, so the first launch is blocked:

1. Double-click FC Dock. macOS will say it can't verify the developer. Click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the FC Dock message. Confirm with your password.

If macOS says the app **"is damaged and can't be opened"**, that's the same block. Run this once in Terminal, then open it again:

```bash
xattr -dr com.apple.quarantine "/Applications/FC Dock.app"
```

> The prebuilt app targets the Mac type it was built on. If it won't launch on your Mac, use Option A.

## First launch: permissions

FC Dock asks for these the first time it needs them:

| Permission | Why |
|---|---|
| **Accessibility** | To notice Shift being held while you're in Finder. Turn FC Dock on in **System Settings → Privacy & Security → Accessibility**. |
| **Automation → Finder** | To see which files are selected |
| **Automation → Pages / Numbers / Keynote** | Only when a conversion uses them, e.g. Word → PDF |
| **Files & Folders** | To save the converted file next to the original |

If holding Shift does nothing, Accessibility is almost always the reason. Check that FC Dock is listed and switched on.

## How to use

1. Select one or more files in Finder.
2. **Hold ⇧ Shift on its own** for a moment. The wheel of formats opens around your cursor. You can let go of Shift.
3. **Click a format.** The new file appears next to the original as `Report_pdf.pdf` (or `Report_pdf_2.pdf` if that name is taken).

To close the wheel without converting, click its centre, click anywhere outside it, right-click, or press any key.

Quick taps, Shift-clicks and typing capitals don't open the wheel. With several files selected, the wheel shows only the formats every file can become.

## Unlock more formats (optional)

These free tools from [Homebrew](https://brew.sh) add the remaining conversions. Install only the ones you want. FC Dock finds them automatically, so there's no need to restart the app.

| Tool | Install | Adds |
|---|---|---|
| FFmpeg | `brew install ffmpeg` | MP3, OGG, OPUS and WMA export; APE, DTS and DSD input; GIF/APNG → MP4/WebM |
| pandoc | `brew install pandoc` | Markdown in and out, LaTeX input, better EPUB |
| ImageMagick | `brew install imagemagick` | WebP, JPEG XL and HDR export |
| Poppler | `brew install poppler` | PDF → SVG |
| DuckDB | `brew install duckdb` | Parquet |
| Tectonic | `brew install tectonic` | LaTeX → PDF with real typesetting |
| LibreOffice | `brew install --cask libreoffice` | ODT/ODS/ODP, WPS, WPD, DOCM, XLSB, DBF; DOC/XLS/PPT as outputs |

To install all the small ones at once:

```bash
brew install ffmpeg pandoc imagemagick poppler duckdb tectonic
```

The dashboard's **Formats** tab shows what's installed and has a copy button for each install command.

## Dashboard

Click the menu-bar icon and choose **Dashboard…** (⌘,).

- **Size:** wheel size (50–200%) and the size of the file preview in the middle
- **Glass:** frost, tint behind the labels, and hover highlight strength
- **Arcs:** gap width and how far the hovered arc pops out
- **Gesture:** how long Shift must be held before the wheel opens

The preview updates as you drag the sliders, but the real wheel only changes when you click **Save Changes** (⌘S). **Revert** goes back to what's saved. **Show on Screen** opens the wheel over your desktop for a few seconds, so you can judge the glass against your real windows.

## Supported formats

| Family | Examples |
|---|---|
| Documents | DOCX, DOC, PDF, RTF, TXT, HTML, Markdown, EPUB, Pages, LaTeX |
| Images | JPG, PNG, HEIC, WebP, AVIF, GIF, TIFF, BMP, SVG, ICO, ICNS, PSD, RAW, JPEG XL |
| Audio | MP3, WAV, FLAC, AAC, M4A, ALAC, AIFF, OGG, OPUS, WMA, MIDI |
| Spreadsheets | XLSX, XLS, CSV, TSV, Numbers, ODS |
| Presentations | PPTX, PPT, Keynote, ODP → PDF or one image per slide |
| Data | JSON, YAML, TOML, XML, INI, NDJSON, BSON, MessagePack, SQLite, Parquet |
| Subtitles | SRT, WebVTT, ASS/SSA, TTML |
| Archives | ZIP, 7z, TAR, TAR.GZ, RAR (read), ISO and DMG (read) |

The full menu for each input format is in [`Catalog.swift`](Sources/FCDock/Formats/Catalog.swift).

## Troubleshooting

- **Holding Shift does nothing.** Turn FC Dock on in Accessibility (see above). If you rebuilt the app, remove it from the list and add it again: macOS treats each new build as a different app.
- **A format I expected isn't on the wheel.** It probably needs one of the optional tools. The dashboard's Formats tab shows which.
- **A conversion failed.** FC Dock shows the reason in a small message. If one method fails, it tries the next best one first.

## For developers

### How conversions are chosen

Each **engine** says which conversions it can do and how well. The planner picks the best one, or chains two engines (e.g. XLSX → CSV in Numbers, then CSV → JSON built in). If a route fails, the next best is tried.

- **Documents:** Pages for Word → PDF/EPUB (keeps layout), LibreOffice for Office formats when installed, and the macOS text system otherwise. PDF → document extracts the text only.
- **Images:** ImageIO, which on current macOS also writes AVIF, ICO, ICNS, PSD, TGA, EXR and JPEG 2000. Animated GIF ⇄ APNG keeps every frame.
- **Audio:** `afconvert` for AAC, ALAC, FLAC, WAV and AIFF; FFmpeg for the rest. MIDI is rendered with macOS's built-in synth.
- **Data:** converted in Swift, keeping key order. Nested data is flattened to dotted columns for CSV.
- **Subtitles:** keep timing and line breaks; styling is dropped.
- **Archives:** unpacked and repacked with macOS's `tar`, `ditto` and `hdiutil`.

### Building with a signing identity

With the default ad-hoc signature, every rebuild resets the Accessibility permission. To avoid that, sign with your own certificate:

```bash
SIGN_IDENTITY="Apple Development: you@example.com" ./scripts/build-app.sh
```

### Testing without the gesture

```bash
APP="build/FC Dock.app/Contents/MacOS/FCDock"
"$APP" --convert path/to/file.docx pdf     # convert one file (add --builtin to skip Pages/Numbers/Keynote)
"$APP" --routes path/to/file.xlsx          # what the wheel offers, and which engines it would use
"$APP" --coverage                          # how much of the catalog this Mac can do
"$APP" --render-wheel path/to/file /tmp/w  # save the wheel's key frames as PNGs
"$APP" --demo-wheel path/to/file 8         # show the real wheel for 8 seconds
```

### Project layout

| Path | What's there |
|---|---|
| `Sources/FCDock/Formats/` | Every known format (`FileFormat`) and the wheel menu per input (`Catalog`) |
| `Sources/FCDock/Conversion/` | Route planner, tool discovery and process running |
| `Sources/FCDock/Engines/` | One engine per backend; `Engines/Data/` holds the JSON, YAML, TOML, XML, CSV, BSON and MessagePack codecs |
| `Sources/FCDock/Wheel.swift` | The radial menu panel, cursor tracking and click handling |
| `Sources/FCDock/ShiftHoldMonitor.swift` | Detects a clean Shift hold |
| `Sources/FCDock/FinderSelection.swift` | Reads Finder's selection |
| `Sources/FCDock/Dashboard.swift` | Settings window, live preview and Formats tab |
| `Sources/FCDock/Settings.swift` | Saved wheel settings and their ranges |
| `Sources/FCDock/AppDelegate.swift` | Menu-bar item and wiring |
| `scripts/build-app.sh` | Builds `build/FC Dock.app` |

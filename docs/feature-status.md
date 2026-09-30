# Feature status

What Clip ships today and what is still open, as of September 2026. Screen recording and cloud features are out of scope for now.

✅ shipped · 🟡 partial · ⬜ not yet

## Capture

| Feature | Status | Notes |
| --- | --- | --- |
| Capture Area | ✅ | Freeze screen, crosshair, magnifier, size label; ⇧ square, ⌥ from center |
| Capture Window | ✅ | Transparent background; shadow optional |
| Capture Fullscreen | ✅ | Display under the pointer |
| Multi-monitor | ✅ | Overlay on every display; All Screens stitches them |
| Capture Previous Area | ✅ | |
| Self-timer | ✅ | 3, 5, or 10 s (fullscreen) |
| Capture Text (OCR) | ✅ | Vision `RecognizeTextRequest` |
| Space to move the selection while dragging | ⬜ | Today, Space switches between area and window mode |
| Scrolling capture | ⬜ | |
| Hide desktop icons during capture | ⬜ | |
| Include cursor | ⬜ | `SCStreamConfiguration.showsCursor` |
| All-in-one mode / exact size entry | ⬜ | |
| URL scheme API | ⬜ | |

## Quick Access overlay

| Feature | Status | Notes |
| --- | --- | --- |
| Floating thumbnail after capture | ✅ | Stacks in the bottom-left corner |
| Copy / Save / Annotate / Pin / Close | ✅ | ⌘C ⌘S ⌘E ⌘P Esc, plus Return to save and Space to pin |
| Drag and drop into apps | ✅ | |
| Auto-close | ✅ | Off, 5, 10, or 30 s |
| Restore closed overlays | 🟡 | Available through History |
| Position and size settings | ⬜ | |

## Annotate editor

| Tool | Key | Status | Notes |
| --- | --- | --- | --- |
| Select / move | V | ✅ | Duplicate ⌘D, layer order ⇧⌘[ and ⇧⌘], nudge with arrow keys |
| Crop | K | ✅ | Aspect presets and rule-of-thirds guides |
| Draw (pen) | D | ✅ | Smoothed |
| Highlighter | M | ✅ | Multiply blend; no word-snapping yet |
| Line | L | ✅ | ⇧ snaps to 45° |
| Text | T | ✅ | Plain, outlined, background, and pill styles |
| Arrow | A | 🟡 | Tapered, classic, filled head, and double; no curved arrow |
| Counter | C | 🟡 | Numbers auto-increment; one visual style; no custom start number |
| Ellipse | E | ✅ | Outline or filled |
| Pixelate / blur / black out | P | ✅ | |
| Spotlight | H | ✅ | |
| Rectangle / filled rectangle | R / F | ✅ | |
| Background | B | 🟡 | Fill, padding, inset, radius, shadow, aspect, alignment. Missing: wallpapers, auto-balance, saved presets |
| Custom colors | | ✅ | System color picker |
| Undo / redo | | ✅ | |
| Resize | | ✅ | Export size with aspect lock and presets |
| Rotate / flip | | ✅ | |
| Combine images | | ⬜ | |
| Editable project file | | 🟡 | Stored with the history item; no standalone file format |
| Export PNG / JPEG / HEIC + quality | | ✅ | WebP not yet |
| 1× / 2× scaling | | ✅ | |

## History, pins, settings

| Feature | Status | Notes |
| --- | --- | --- |
| Capture history | ✅ | Last 50 captures, with filter, reopen, and edits restored |
| Pins | ✅ | Opacity (scroll), zoom, arrow-key nudge, lock (click-through) |
| After-capture actions | ✅ | Multiple can be on at once |
| Custom save folder, file name prefix, format | ✅ | |
| Rebindable global shortcuts | ✅ | |
| Shutter sound toggle | ✅ | |
| Launch at login | ✅ | `SMAppService` |

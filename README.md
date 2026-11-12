# Skica

A fast, keyboard-first design tool for macOS, in the spirit of Sketch: shapes, text, images, layers,
groups, symbols, auto layout and exports to SVG, PNG, JPG, WebP and PDF. Opens Sketch, SVG and Figma
files. See [docs/PLAN.md](docs/PLAN.md) for how it was built.

Requires macOS 14+ on Apple silicon.

**User guide:** [docs/manual/index.html](docs/manual/index.html) (also as [PDF](docs/manual/Skica-Guide.pdf)), with
screenshots, every feature and the full shortcut list.

## Install

```sh
brew tap aleksandargosevski/tap
brew trust aleksandargosevski/tap
brew install skica
ln -sfn "$(brew --prefix)/opt/skica/Skica.app" /Applications/Skica.app
```

The link makes Skica visible to Spotlight, Raycast and the Dock. Open Skica once so Finder shows
thumbnails and space-bar previews of `.skica` files. The formula also installs the `skica` command.
The app can also be downloaded from [Releases](https://github.com/aleksandargosevski/skica/releases).
Browsers mark downloads as quarantined and the app is not notarized, so macOS blocks the first
launch of each version: allow it under **System Settings → Privacy & Security → Open Anyway**, or run
`xattr -d com.apple.quarantine Skica.app`.

To build and install from source instead (needs the Xcode Command Line Tools):

```sh
./scripts/create-cert.sh   # once: self-signed "Skica Dev" signing certificate
./scripts/install.sh       # builds and installs into ~/Applications, then starts the app
```

Without the certificate, builds are signed ad hoc and still run.

## Development

```sh
./scripts/build.sh --run   # build into ./build and restart the app
./scripts/test.sh          # run tests
swift scripts/make-icon.swift   # regenerate Resources/AppIcon.icns from Resources/AppIconSource.png
```

`Help → New Sample Document` opens a small demo file, and `Help → New Stress Test Document` one with
5,000 layers.

To check the canvas without screen recording access, write the sample document's window to a PNG,
optionally after running commands (by `CommandID` name, plus `undo`, `redo` and `nudge`):

```sh
SKICA_DEBUG_SNAPSHOT=/tmp/skica.png SKICA_DEBUG_COMMANDS=toolStar,enterSelection \
  build/Skica.app/Contents/MacOS/Skica
```

`scripts/snapshot.sh <name> [commands]` does the same and also saves the canvas as drawn on screen and
the inspector to `.build/shots/`. With `SKICA_DEBUG_OPEN=file.sketch` it opens that file instead.

`scripts/make-manual.sh` rebuilds the user guide: it takes the screenshots from the app, fills in the shortcut
table from the keymap (`skica shortcuts --html`) and prints the PDF with WebKit (`scripts/render-pdf.swift`).
Set `SKETCH_SAMPLE=file.sketch` to refresh the Sketch import screenshot too.

Quick Look support is two app extensions (`Contents/PlugIns/SkicaThumbnail.appex` and
`SkicaPreview.appex`) built from the `SkicaQuickLook` target; `build.sh` packs and signs them.
`pluginkit -m -v | grep skica` shows whether macOS found them.

### Releases

Pushing a tag like `v1.2.3` runs `.github/workflows/release.yml`, which tests and builds the app,
publishes `Skica-1.2.3.zip` as a GitHub release and updates `skica.rb` in
[aleksandargosevski/homebrew-tap](https://github.com/aleksandargosevski/homebrew-tap).

Required repository secrets:

| Secret | Value |
|---|---|
| `SKICA_CERT_P12_BASE64` | `base64 -i skica-dev.p12` of the "Skica Dev" certificate exported from Keychain Access |
| `SKICA_CERT_PASSWORD` | password chosen when exporting the `.p12` |
| `HOMEBREW_TAP_TOKEN` | fine-grained token with Contents: read and write on the tap repository |

Releases must always be signed with the same certificate, so macOS keeps treating every version as
the same app.

Rendering tests can save what they draw with `SKICA_RENDER_OUTPUT=/tmp/render.png ./scripts/test.sh`.

## Layout

- `Sources/SkicaCore`: everything that is not UI and is unit tested. It must not import AppKit.
  - `Model/`: the document (pages, a flat table of layers, styles) and tree helpers
  - `Edit/`: `Transaction` and `Patch` (every edit, undo and redraw goes through them), editing
    operations, the clipboard format and tools
  - `Editor/`: `DocumentEditor`, the live state of an open document: selection, tool, undo
    (bridged to `NSUndoManager`), live edits for drags
  - `Selection/`: hit testing, the rules for clicks, marquees and keyboard navigation, snapping,
    hint labels
  - `Geometry/`: the viewport, shape outlines and layer transforms
  - `Input/`: arithmetic in fields, the size-and-position prompt, the `:` command line, fuzzy matching
  - `Text/`: text runs, Core Text layout and measuring, font lookup
  - `IO/`: the `.skica` file, a zip with `document.json`, and format migrations
  - `Keys/`: commands, keymaps and key sequences
  - `Export/`: export bounds and names, and the SVG writer
- `Sources/SkicaRender`: draws pages with Core Graphics; shared by the canvas and exports. `Exporter`
  writes PNG, JPG, HEIC and AVIF with Image I/O, WebP with libwebp, and PDF. Shadows and
  blur are drawn offscreen and blurred with Core Image rather than with `CGContext.setShadow`, whose
  offsets differ between bitmap and on-screen layer contexts.
- `Sources/SkicaCLI`: the `skica` command (built as `skica-cli`, since file names ignore case and it would
  collide with the app binary `Skica`; the app bundles it as `Contents/Helpers/skica`).
- `Sources/Skica`: the AppKit app. `KeyboardRouter` sends key presses to commands before AppKit
  sees them; the canvas draws the document and the selection overlay in separate layers.

## Symbols, styles and colors

- **Symbols**: `⌥⌘K` turns the selection into a symbol. Its master moves to the **Symbols** page and an
  instance takes its place (an artboard on its own becomes a symbol in place). Edit the master and every
  instance follows. In an instance, the inspector changes the texts, colors, nested symbols and visibility
  of the symbol's layers for that instance only. Instances copied into another document bring their master.
  Deleting a master turns its instances into groups.
- **Shared styles**: the style menu at the top of the inspector creates a style from a layer, applies one,
  and shows "modified" when a layer differs; **Update Style from Layer** changes every layer using it.
  Text layers get text styles (font, size, color, spacing, alignment).
- **Colors**: with nothing selected the inspector shows the palette and the shared styles. `c` applies a
  palette color, and the command line takes `$name` wherever a color goes.

## Constraints and stacks

- **Resizing** (inspector, for layers in an artboard or symbol): how a layer follows when its artboard,
  symbol master or a symbol instance changes size: stick to left/right/top/bottom, stretch (both), center
  or scale. Instances of a symbol lay out its layers by these, so a wider button keeps its label size.
  Command line: `pin left right`, `pin bottom`, `pin hcenter vscale`.
- **Stacks** (`⇧A`): lines the layers up in a row or column (picked from how they are arranged) with a
  gap, padding and alignment; the stack hugs its contents or keeps a fixed size. Reordering layers
  reorders the stack, and text that grows pushes its neighbours. Command line: `stack h 8 12 center`,
  `stack v 16 fixed`, `stack off`, `gap 12`, `pad 8 16`.

## Import

- **SVG**: paste SVG (copied as an image or as markup from a code editor, Figma or a website), drop
  `.svg` files on the canvas or add them with `i`. They arrive as editable groups of shapes, paths
  and text. Open a `.svg` file to get it on an artboard of its size. Gradients, strokes, CSS classes,
  transforms and `<use>` come along; clip paths, masks, filters and patterns are skipped.
- **Sketch**: open `.sketch` files (File → Open, or drop them on the Dock icon). Pages, artboards and
  Sketch 2025 frames, groups, shapes, boolean shape groups, text, images, symbols with overrides,
  shared styles, colors, constraints and export presets are kept. The file opens as a new, unsaved
  document; Sketch's own file is never changed.
- **Figma**: File → Import from Figma… (`⌃⌘O`) takes a file link and a personal access token (Figma →
  Settings → Security). The token can be kept in `~/.config/skica/figma-token`; `FIGMA_TOKEN` also
  works. Frames, groups, vectors, text, image fills, components and instances (with their text, color,
  visibility and swap overrides), auto layout, constraints, effects and export settings come along.

## Export

Give a layer export sizes in the inspector (`1x`, `2x`, `512w`, `300h`, each with a suffix and a
format: PNG, JPG, WebP, HEIC, AVIF, PDF or SVG), then:

- `⌘⇧E` exports the selection (layers without sizes as a 1x PNG), `⌘⌥⇧E` every marked layer.
- **Export → Export Page as PDF…** writes the page's artboards as pages of one PDF; shapes and text stay vectors.
- `⌘⇧C` copies the selection as a 2x PNG, `⌘⌥⇧C` as SVG.

Layer names with `/` become folders (`Icons/Home` → `Icons/Home@2x.png`). SVG uses real `rect`, `ellipse`
and `path` elements, gradients, clip paths and masks for inside and outside borders, filters for shadows and
blur, and `text` elements broken into the same lines as on the canvas.

### Command line

**Skica → Install Command Line Tool…** links `skica` into `/opt/homebrew/bin` (or `/usr/local/bin`).

```sh
skica list Design.skica
skica export Design.skica -o out -f png -s 2x            # every artboard
skica export Design.skica -a "Home" -a "Settings" -f svg  # some artboards
skica export Design.skica --exportables                   # marked layers, with their own sizes
skica export Design.skica --single-pdf Design.pdf         # all artboards in one PDF
skica sample Sample.skica                                 # a document to try things on
skica import Design.sketch Design.skica                   # convert Sketch or SVG files
skica import https://www.figma.com/design/KEY/Name Design.skica   # needs FIGMA_TOKEN
skica export Design.sketch -o out                         # export straight from Sketch files too
```

## Shortcuts

Press `?` in the app for the full list, or `⌘P` to search commands, layers and pages.

| | |
|---|---|
| `v` `r` `o` `l` `y` `*` `p` `t` `a` | select, rectangle, oval, line, polygon, star, pen, text, artboard |
| pen: click, drag, click the first point | corner, curve, close the path (`↩`/`esc` finish open, `⌫` remove the last point, `⇧` 45°) |
| pen: click the last point again, `⌥`-drag | next segment straight after a curve; sharp turn between two curves |
| `e`, `↩` or double-click on a path | edit points: `⇥` next point, arrows move, `1`–`4` straight / mirrored / asymmetric / disconnected, `⌫` delete, click a segment to add a point, `esc` done |
| `⌘⇧O`, `⌘⌥O` | convert to paths (text to outlines), outline stroke |
| `⌘⌥U` `⌘⌥S` `⌘⌥I` `⌘⌥X` | union, subtract, intersect, difference |
| `⇧A`, `⌥⇧A` | add a stack (auto layout) to the selection or the selected container; remove it |
| `⌃⌘M` | mask: the bottom selected layer clips the others (one layer: toggle) |
| `⌥⌘K`, `s`, `g s`, `⌥⌘B` | create symbol, insert symbol, go to master (or double-click an instance), detach |
| `⇧⌘Y`, `c` | apply a shared style, apply a palette color (also `fill $brand` and `style Card` after `:`) |
| `e`, double-click an image | crop: drag edges to crop, drag inside or arrows to move the image, `esc`/`↩` done (inspector: Reset Crop) |
| `⌥A` `⌥H` `⌥D`, `⌥W` `⌥V` `⌥S` | align left, horizontal centers, right; top, vertical centers, bottom (one layer: to its artboard) |
| `⌃⌥H`, `⌃⌥V` | distribute horizontally, vertically; the inspector's ↔ ↕ fields (or `:distribute h 16`) set an exact gap |
| `i` | add images and SVG files (also drag and drop, or paste; SVG becomes editable layers) |
| `⌘O`, `⌃⌘O` | open `.skica`, `.sketch` or `.svg` files; import from Figma |
| drag, or `↩` after a tool | add a shape (`⇧` square / 45°, `⌥` from center, `⌃` no snapping); `↩` opens the size prompt |
| `=` or `↩` on a shape | size and position: `200x120`, `@ 40,80`, `150`, `+20x`, `*2x`, or a preset name (`iphone`, `a4`) |
| `↩` / double-click on text | edit text; `esc` ends; `⌘B` `⌘I` `⌘U` bold, italic, underline; `⌘T` font |
| `:` | command line: `w 200; fill #f60; border 2 #000 inside; shadow 0 4 12 #0003; font Inter 16 600; align center` |
| `.` | repeat the last command line on the selection |
| `f` / `⇧F` | label visible layers; type a label to select (or add) it |
| arrows (`⇧` ×10) | move the selection; pan when nothing is selected |
| `⌘` / `⌘⌥` + arrows | resize from the right/bottom / from the left/top |
| `⇥` / `⇧⇥`, `↩`, `esc` | next / previous layer, into a container, back to the parent |
| `⌘G`, `⌘⇧G` | group, ungroup (double-click goes into a group) |
| `⌘D`, `⌫`, `⌘C` `⌘X` `⌘V` | duplicate, delete, copy, cut, paste |
| `⌘]` `⌘[`, `⌘⌥]` `⌘⌥[` | forward, backward, to front, to back |
| `⌘⇧H`, `⌘⇧L`, `⌘R` | hide, lock, rename |
| `fn↓` / `fn↑`, `g p`, `g m`, `⌘⌥N` | next / previous page, go to page, move selection to page, new page |
| `⌘=` `⌘-` `⌘0` `⌘1` `⌘2` | zoom in, out, 100%, fit, selection |
| `⌘⌥1`, `⌘⌥2`, `⌘.` | layers, inspector, canvas only (drag the dividers to resize them) |
| drag rows in the layers list | reorder, or move into and out of groups and artboards |
| `g l`, `g i` | go to layers, go to inspector (fields take `100/3`, `+20`; ↑/↓ step) |
| `⌘⇧E`, `⌘⌥⇧E`, `⌘⇧C`, `⌘⌥⇧C` | export selection, export marked layers, copy as PNG, copy as SVG |
| `⌘P`, `⌘K`, `?` | command palette, actions for the selection, shortcut list |
| `space` + drag/arrows, two-finger scroll | pan |
| `⌘` + scroll, pinch, two-finger double tap | zoom |

Shortcuts can be changed in `~/.config/skica/keybindings.json`:

```json
{ "preset": "figma", "bindings": { "zoomToFit": ["cmd+1", "shift+1"] } }
```

## File format

A `.skica` file is a zip archive with `document.json` (a `version`, the `pages` in order, and all
`layers` keyed by ID) and `images/<sha256>.<ext>` for bitmaps. Containers list their `children` bottom
to top, and child frames are relative to their parent. Colors are `#RRGGBB` or `#RRGGBBAA`. Fields added
after format 1 have defaults, so older files keep opening.

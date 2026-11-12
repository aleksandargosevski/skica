# Skica: plan

## Odluke

| Tema | Odluka |
|---|---|
| Platforma | Swift 6, macOS 14+, Apple silicon, SPM bez Xcode projekta |
| Renderer | Core Graphics + CoreText, tile cache, `Renderer` protokol za eventualni Metal |
| Format | `.skica` = zip (`document.json` sa `version` + `images/<sha256>.ext`), `NSDocument` |
| Stanje | Ravan model (value types), transakcije sa before/after patch-evima |
| Tastatura | Sketch preset + hint mod `f`, komandna linija `:`, `⇥` kroz stablo, `⌘K`/`⌘P`/`?` |
| UI | Lejeri levo, inspector desno, status/komandna linija dole, `⌘.` zen mod |
| Tekst | Rich text po opsezima, CoreText, `NSTextView` overlay za editovanje |
| Distribucija | Kao poscar + CLI `skica` + UTI + Quick Look |

## Faze

Posle svake faze aplikacija se pokreće za ručno testiranje i feedback.

| Faza | Sadržaj | Status |
|---|---|---|
| 0. Kostur | SPM, skripte, `NSDocument`, zip IO, platno sa pan/zoom, KeyboardRouter, status linija | ✅ |
| 1. Jezgro | Rect/oval/line/polygon/star, selekcija, transformacije, transakcije + undo, lejeri panel, osnovni inspector, alati, prompt, `⇥` navigacija, `⌘P` | ✅ (R-tree i tile cache odloženi: 5.000 lejera = ~15 ms full redraw, hit-test linearno je dovoljno brz) |
| 2. Stil i sadržaj | Fill (solid, gradijenti), stroke, shadow, blur, blend, grupe, stranice, artboard preset-i, smart guides/snapping, tekst (rich runs), slike, komandna linija `:`, hint mod | ✅ |
| 3. Export | SVGWriter, PNG/JPG/PDF (više stranica)/WebP/HEIC (+AVIF), export preset-i, copy as SVG/PNG, `skica export` CLI | ✅ |
| 4. Vektori | Pen tool, pathEdit, boolean, maske, outline stroke, flatten | ✅ |
| 5. Sistem dizajna | Simboli (master/instance/override/detach), deljeni stilovi, swatch-evi | ✅ |
| 6. Layout | Constraints, stack auto-layout | ✅ |
| 7. Interop i polish | SVG import/paste, `.sketch` import, Figma REST import, Quick Look, Homebrew release | ✅ |

## Tastatura (cilj)

- Alati: `v` select, `r` rect, `o` oval, `l` line, `p` pen, `t` text, `a` artboard, `i` image.
  `↩` posle alata pravi oblik i otvara prompt `200x120 @ 40,80`.
- Strelice / `⇧` pomeraju 1/10px; `⌘`+strelice menjaju veličinu, `⌘⌥` suprotnu ivicu.
- `⇥`/`⇧⇥` sibling, `↩` u grupu, `esc` na roditelja.
- `f` / `⇧F` hint mod (Vimium).
- `:` komandna linija: `w 200`, `h +20`, `fill #ff6600`, `r 8`, `op 50`, `stroke 2 #000 inside`,
  `font Inter 16 600`, `align left`, `stack h 8 16`, `bool union`, `export png 2x`…; matematika u poljima.
- `.` ponavlja poslednju komandu; brojevi kao count (`5→`).
- `⌘K` akcije selekcije, `⌘P` sve, `?` prečice.
- Preset-i `sketch`/`figma`, `~/.config/skica/keybindings.json`, prečice po poziciji tastera na ćirilici.

## Performanse (budžeti)

Pokretanje < 300 ms; otvaranje 5.000 lejera < 300 ms; pan/zoom 120 fps; hit-test < 0,5 ms;
strelica → prikaz < 8 ms.

## Rizici

- Quick Look `.appex` bez Xcode-a: rezervno, `preview.png` u zip-u.
- Rich text editovanje na rotiranim lejerima.
- Simboli + auto-layout + constraints zajedno: layout resolver u Core-u sa mnogo testova.
- Figma API: best-effort.
- WebP enkodiranje: ImageIO ga ne podržava, koristi se `libwebp` (SDWebImage/libwebp-Xcode).

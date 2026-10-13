# Bundled fallback fonts

Three faces ship inside the app because the terminal is **wrong without them, silently.**

The stack in `crates/render/src/font.rs` loads faces BY FILE PATH and gives each fallback a
scale that makes its advance fit one cell. When the bundled Hebrew face is absent, Hebrew falls
through to Arial Hebrew, which is proportional: measured at a 19px cell, aleph advances 9.0
against Latin's 10.0. Nothing errors. Hebrew simply drifts off the grid, and the only way to
notice is to look at Hebrew on screen and know what correct looks like. Arabic without Kawkab
Mono has the same shape one script over.

These were `$HOME/Library/Fonts` lookups, described in the code as "optional and user-installed".
That made a correct grid depend on a manual step nobody performs on a fresh machine - and a
machine format on 2026-08-11 proved it by silently degrading Hebrew on the first launch.

JetBrains Mono NF joined on 2026-08-25 for the same reason one script further out. Measured
across the whole stack, NOTHING carried a single powerline separator or Nerd Font icon: Menlo is
0/20 and 0/184, and so are SF Mono, the Hebrew face and Kawkab. The one face that ever answered was an
Iosevka read out of `$HOME/Library/Fonts`, absent on this machine and on any fresh one, so a
starship prompt drew tofu with nothing anywhere reporting it.

| file | face | licence |
|---|---|---|
| `Cousine-Regular.ttf` | Hebrew, monospaced | SIL OFL 1.1 |
| `KawkabMono-Regular.ttf` | Arabic and Persian, monospaced | SIL OFL 1.1 |
| `JetBrainsMonoNerdFontMono-Regular.ttf` | the lead: Latin, box drawing, powerline, Nerd Font icons | SIL OFL 1.1 |
| `Cousine-{Bold,Italic,BoldItalic}.ttf` | the Hebrew face's styled siblings | SIL OFL 1.1 |
| `KawkabMono-Bold.ttf` | the Arabic face's bold; Kawkab Mono has no italic | SIL OFL 1.1 |
| `JetBrainsMonoNerdFontMono-{Bold,Italic,BoldItalic}.ttf` | the lead's styled siblings | SIL OFL 1.1 |

## Provenance, and why all three may ship here

- **Cousine** comes from `google/fonts`, `ofl/cousine`, unmodified. OFL 1.1. It replaced Miriam
  Mono CLM on 2026-08-25, and the reason was WEIGHT, not correctness: Miriam met every
  requirement and still does. See the weight section below.
- **Kawkab Mono** comes from the `v0.501` release of `github.com/aiaf/kawkab-mono`, unmodified.
  OFL 1.1 permits bundling outright; it requires the licence to ride along, which
  `LICENSE-KawkabMono-OFL.txt` does, and it reserves the name - so a modified copy must be
  renamed rather than shipped as Kawkab Mono.
- **JetBrains Mono NF** is the Nerd Fonts patched build of JetBrains Mono, unmodified, from the
  `v3.5.1` release. Same OFL 1.1 terms as Kawkab, and `LICENSE-JetBrainsMono-OFL.txt` is the
  upstream `OFL.txt`. The PATCHED build is the one that ships on purpose: plain JetBrains Mono
  carries 8/20 powerline codepoints and 0/184 icons, so it would close half of what this face is
  here to close.

  **And it must be the `NerdFontMono` build, not `NerdFont`.** The two are one word apart in a
  filename and the wrong one produces no error anywhere: the advance is honest, the ink stays
  inside the cell because the blit clips it, and the icons simply arrive cut in half -- a `</>`
  as `</`, a folder without its tab, `git` as `gi`. Measured at a 10px cell, the non-Mono masks
  were 12 to 20px wide against the Mono build's 10. This repo shipped the wrong one for a day.
  `crates/render/tests/nerd_icons.rs` is the gate, and it reads the RASTERISED MASK because that
  is the only place the truth survives the clip.

All three licences are in this directory rather than referenced, because a licence that lives
only in a URL is one dead link away from a compliance problem.

## Bold and italic siblings (2026-10-02)

SGR 1 and SGR 3 were parsed and then drawn as Regular, because only Regular faces shipped. The
styled siblings fix that with real faces, not synthesis: swash's embolden skips composite
glyphs, so a synthetic bold left `i`, `u`, `c` and `l` at regular weight.

Every sibling comes from the same release as its Regular, unmodified, verified before it landed:

| file | source | check |
|---|---|---|
| `JetBrainsMonoNerdFontMono-{Bold,Italic,BoldItalic}.ttf` | nerd-fonts `v3.5.1`, `JetBrainsMono.tar.xz` | the archive's Regular is byte identical to the bundled one |
| `Cousine-Bold.ttf` | `google/fonts`, `ofl/cousine` | git blob `966b5bdb` |
| `Cousine-Italic.ttf` | same | git blob `e40f4003` |
| `Cousine-BoldItalic.ttf` | same | git blob `2c8731f8` |
| `KawkabMono-Bold.ttf` | `aiaf/kawkab-mono` `v0.501` zip | the zip's Regular is byte identical to the bundled one |

Measured at 16px, every sibling advances exactly as its Regular (9.600), so the grid cannot
move. Bold carries 1.33x (Latin), 1.42x (Hebrew) and 1.39x (Arabic) the ink of Regular; italic
overhangs its cell by 1.4px right and 1.0px left, which the renderer already allows.

**How a sibling is found.** `FontStack::load` looks beside every `...-Regular.ttf` for
`...-Bold`, `...-Italic` and `...-BoldItalic` with the same extension, appends each one after all
the Regulars with its Regular's scale, and never searches them on their own. A styled run asks
the Regular that answers the character, then swaps in its sibling if that covers the glyph. So
bold Hebrew falls back across faces exactly the way regular Hebrew does, and a family without
the sibling draws Regular rather than nothing. Kawkab's bold italic uses its Bold.

**The trap this created.** `find_family` matches file stems by substring in sorted order, and
`-Bold` sorts before `-Regular`, so `font-family = "JetBrains Mono"` turned every cell bold the
moment the siblings landed. A Regular now wins within a directory; a styled file answers only
when the name asks for it, or when it is all there is. `crates/render/tests/bold_italic.rs` is
the gate on all of this.

## Where they end up

`scripts/build-app.sh` copies every `.ttf` and `LICENSE-*.txt` in this directory into
`Termisu.app/Contents/Resources/fonts/`. The stack resolves that path from the running
executable, so the app carries its own fallbacks and no install step is required. A
user-installed copy in `~/Library/Fonts` is honoured FIRST, so an operator's own build of a
bundled family still wins.

Under `cargo test` and `cargo run` the executable lives in `target/debug/deps`, where none of
those directories exist, so `FontStack::bundled_dirs` ends with this directory resolved from
`CARGO_MANIFEST_DIR`. Without it the grid assertions would be measuring a machine that does not
have the fonts this repo ships, which is exactly what they exist to prevent.

## Position in the stack

**JetBrains Mono NF LEADS**, the maintainer's call 2026-08-25. Menlo led until then and is now one step
down, kept rather than dropped because it is 96/96 on geometric shapes where JetBrains is 43/96.

The cell box IS the lead's advance, so this moved the shipped cell from 10x19 to 10x22 and every
window shows fewer rows at the same pixel height. That cost was accepted knowingly. Measured end
to end: the bundle's headless smoke went from 970 ink pixels in 800x456 to 1049 in 800x528.

Cousine and Kawkab stay FALLBACKS and must, because the lead carries no Hebrew and no Arabic.

## Why the Hebrew face changed the same day

The lead swap left Hebrew reading washed out beside the new Latin, and that was a number, not an
impression. Measured with `crates/render/tests/hebrew_weight.rs`, ink pixels per character
against the lead's 49.67:

| candidate | px/char | ratio to Latin | advance vs 10px cell | verdict |
|---|---|---|---|---|
| Miriam Mono CLM Book | 23.11 | 0.47 | 9.60 | too light, this is what shipped before |
| Miriam Mono CLM Bold | 38.05 | 0.77 | 9.60 | in range, but a BOLD face doing a regular's job |
| **Cousine Regular** | **41.11** | **0.83** | **9.60** | shipped |
| Cousine Bold | 50.21 | 1.01 | 9.60 | heavier than the Latin it sits beside |
| Arial Hebrew | 37.79 | 0.76 | 11.10 | proportional, off the grid |
| SF Hebrew | 39.79 | 0.80 | 11.92 | proportional, off the grid |

Cousine advances 9.60, the same number Miriam gave, so the grid did not move at all. Miriam Bold
was rejected on the picture rather than the number: it reads bold and it crowds the niqqud.

Correctness was the gate all three had to pass first, not an afterthought. Every mark in
U+05B0..U+05C7 resolves, GPOS attaches them to the right base, a pointed cluster stays ONE cell,
and the cluster's ink stays centred. `crates/render/tests/shaping.rs` asserts all of that of
Cousine directly.

One thing was LOST and is worth writing down. Miriam Mono CLM is kept in
`crates/render/tests/fixtures/` (not shipped) because it is the only face measured here whose
UNSHAPED path visibly misplaces a mark, which is what makes the GPOS control able to go red.
Cousine's mark glyphs land near the right place with no GPOS at all, so with Cousine that
control asserts nothing.

Any face here can be reached as the lead through `font-family` in `~/.termisu/config.toml`;
`find_family` searches this directory last, so the name resolves without an absolute path.
`crates/render/tests/bundled_lead.rs` is the gate on all of it.

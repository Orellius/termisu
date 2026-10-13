# Test fixtures

Fonts here are NOT shipped. `scripts/build-app.sh` copies `assets/fonts/*.ttf` into the bundle
and never looks in this directory, which is the whole reason the directory exists.

| file | why it is here |
|---|---|
| `MiriamMonoCLM-Book.ttf` | the GPOS control for `tests/shaping.rs` |

## Miriam Mono CLM

It was the shipped Hebrew face until 2026-08-25, when Cousine replaced it for weight. It stays
here because it is the only face measured on this machine whose UNSHAPED path visibly misplaces
a niqqud mark: with shaping off, Miriam dumps the mark at the cell's left edge, because its mark
glyphs have a near-zero left side bearing.

That is what makes `a_mark_is_placed_by_the_font_and_not_dumped_at_the_pen` a real test rather
than a description. Cousine's mark glyphs carry a large left side bearing that lands them near
the right place by accident, so with Cousine the control CANNOT go red -- a renderer with GPOS
switched off entirely would still very nearly pass. Measured, not assumed: with Cousine the
unshaped cluster's edge ink equalled the bare base's exactly, so the control asserted nothing.

Binding the test to a face rather than to "the shipped stack" is deliberate. The shipped face
having good default metrics is luck, and a control that depends on luck is not a control.

GPL-2.0, unmodified, from `culmus-0.140`. `LICENSE-Culmus-GPL2.txt` travels with it. Not
distributed with the program: `NOTICE` records it under build-and-test material for that reason.

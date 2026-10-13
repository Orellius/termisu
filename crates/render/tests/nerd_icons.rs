//! Nerd Font icons must FIT the cell they are drawn in.
//!
//! This exists because of how the failure looks, which is not "the icon is wrong". The maintainer
//! reported the icons as cut off, and what he saw was a `</>` drawn as `</`, a folder without
//! its tab, a `git` reading `gi`, and the GitHub mark as a bare `C`. Every one of them was a
//! COMPLETE glyph rasterised wider than the cell and then clipped at the cell's right edge.
//!
//! It is invisible to every other measurement in this suite. The advance is honest -- 9.60
//! against a 10px cell, exactly Latin's -- so nothing that reads advances can see it. The ink
//! stays inside the cell, because the clip put it there, so nothing that counts per-cell ink
//! can see it either. The only place the truth survives is the rasterised MASK, before the blit
//! clips it, which is what this reads.
//!
//! The cause was the wrong build of the right font. Nerd Fonts ships two: `...NerdFont-...`
//! draws icons at their designed width, up to two cells, and `...NerdFontMono-...` scales every
//! icon down to a single cell. A terminal needs the Mono build and this project shipped the
//! other one for a day. The reference implementation makes the same distinction, and its own
//! font directory carries a separate `SymbolsNerdFontMono-Regular.ttf` for the same reason.
//!
//! MEASURED MASK WIDTHS, both builds, 16px, a 10px cell, 2026-08-25. This is the control, and
//! it was run against the real non-Mono file rather than reasoned about:
//!
//!   NerdFontMono  [11, 11, 10, 10, 10, 10, 10, 10]
//!   NerdFont      [11, 11, 12, 20, 16, 19, 16, 16]
//!
//! The threshold is `cell + 1` because of the two 11s, which are the SAME in both builds. A
//! powerline separator is drawn to fill the cell edge to edge, so at a fractional scale it
//! rounds up by one pixel in any build; that is rasterisation rounding, not overflow, and it is
//! why the separators were the only icons that never looked cut. Everything the bug actually
//! damaged is 12 or more against a limit of 11, so the threshold separates cleanly and is not
//! sitting on the boundary of either build.

use termisu_vt_render::{Atlas, FontStack, GlyphKey};

/// One icon from each block a prompt actually uses, chosen so a partial regression cannot hide:
/// powerline separators, the devicon range, and the Font Awesome range that carries `git`.
const ICONS: [char; 8] = [
    '\u{E0B0}', // powerline right separator
    '\u{E0B2}', // powerline left separator
    '\u{E795}', // a terminal glyph, devicons
    '\u{F121}', // </>, and the first one seen cut
    '\u{F07B}', // folder
    '\u{F015}', // home
    '\u{F09B}', // the GitHub mark
    '\u{F1D3}', // the git wordmark, the widest of them
];

#[test]
fn every_icon_rasterizes_inside_its_cell() {
    let mut stack = FontStack::system(16.0).expect("the system stack");
    let cell = stack.metrics();
    let mut atlas = Atlas::new();

    for icon in ICONS {
        let resolved = stack
            .resolve(icon)
            .unwrap_or_else(|| panic!("U+{:04X} resolves to nothing", icon as u32));
        let key = GlyphKey {
            font: resolved.font,
            glyph: resolved.glyph,
        };
        let glyph = atlas
            .glyph(&stack, key)
            .unwrap_or_else(|| panic!("U+{:04X} did not rasterize", icon as u32));

        assert!(
            glyph.width <= cell.width + 1,
            "U+{:04X} rasterized {}px wide into a {}px cell, so it draws clipped",
            icon as u32,
            glyph.width,
            cell.width
        );
    }
}

#[test]
fn an_icon_is_not_wider_than_a_letter_by_more_than_the_cell() {
    // The control on the assertion above, and it is doing real work. `glyph.width <= cell.width`
    // is also satisfied by a face that carries no icons at all and rasterizes tofu, or by one
    // that draws them at four pixels. This pins that the icons are drawn at a comparable size to
    // the text they sit in, so "it fits" cannot be achieved by shrinking them into nothing.
    let mut stack = FontStack::system(16.0).expect("the system stack");
    let mut atlas = Atlas::new();

    let letter = stack.resolve('M').expect("M resolves");
    let letter_width = atlas
        .glyph(
            &stack,
            GlyphKey {
                font: letter.font,
                glyph: letter.glyph,
            },
        )
        .expect("M rasterizes")
        .width;

    for icon in ICONS {
        let resolved = stack.resolve(icon).expect("resolves");
        let width = atlas
            .glyph(
                &stack,
                GlyphKey {
                    font: resolved.font,
                    glyph: resolved.glyph,
                },
            )
            .expect("rasterizes")
            .width;
        assert!(
            width * 2 >= letter_width,
            "U+{:04X} rasterized {width}px against an M's {letter_width}px -- it fits the cell \
             by being too small to read",
            icon as u32
        );
    }
}

#[test]
fn the_lead_face_is_the_mono_build() {
    // Named, because the two builds are one word apart in a filename and the wrong one produces
    // no error anywhere -- it produces clipped icons that look like a renderer defect. If this
    // ever has to change, the assertion above is what must stay green.
    let stack = FontStack::system(16.0).expect("the system stack");
    let lead = stack.name(0).unwrap_or_default();
    assert!(
        lead.contains("NF") || lead.contains("Nerd Font"),
        "the lead face is {lead:?}, which is not a Nerd Font build"
    );
    assert!(
        lead.contains("Mono"),
        "the lead face is {lead:?} -- the non-Mono Nerd Font build draws icons up to two cells \
         wide and they are clipped at the cell edge"
    );
}

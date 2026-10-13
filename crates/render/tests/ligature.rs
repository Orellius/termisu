//! Ligatures: with a ligating lead font, "->"-class sequences must draw DIFFERENT ink than
//! per-cell rendering; with a NON-ligating lead the output must be byte-identical whether the
//! feature is on or off -- that identity is what makes this a safe revision of the
//! one-cell-shaping policy rather than a regression risk.
//!
//! Both halves changed hands on 2026-08-25, when JetBrains Mono NF became the lead. The
//! ligating font used to be an Iosevka read from `$HOME/Library/Fonts`, which is not installed
//! here, so that half SKIPPED -- it had never once run on this machine. It is now the shipped
//! default and always runs. The non-ligating control moved the other way: it used to be the
//! default stack implicitly, and now names Menlo, which is still in the stack one step down.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{FontStack, Renderer};

const COLS: u16 = 12;
const SIZE: f32 = 24.0;

fn pixels(family: Option<&str>, ligatures: bool, text: &str) -> Vec<u8> {
    let mut terminal = Terminal::new(COLS, 1);
    terminal.write(b"\x1b[?25l");
    terminal.write(text.as_bytes());
    let (writer, reader) = channel(COLS, 1);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("fits");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);

    let fonts = FontStack::with_primary(family, SIZE).expect("fonts");
    let mut renderer = Renderer::new(fonts, COLS, 1);
    renderer.set_ligatures(ligatures);
    renderer.draw_all(&frame);
    renderer.pixels()
}

#[test]
fn a_ligating_font_draws_arrows_differently() {
    // The DEFAULT stack, which ships with the app, so this can no longer skip.
    let ligated = pixels(None, true, "a -> b");
    let plain = pixels(None, false, "a -> b");
    assert_ne!(
        ligated, plain,
        "calt/liga formed nothing -- either the font lost its ligatures or the run \
         path never fired"
    );
}

#[test]
fn a_non_ligating_lead_is_byte_identical_either_way() {
    assert!(
        FontStack::family_resolves("Menlo"),
        "Menlo is a system face on every macOS; without it this control proves nothing"
    );
    let on = pixels(Some("Menlo"), true, "a -> b != c");
    let off = pixels(Some("Menlo"), false, "a -> b != c");
    assert_eq!(
        on, off,
        "Menlo has no ligatures, so the feature flag must change NOTHING -- if it did, \
         the fallback guard (glyphs < chars) is broken"
    );
}

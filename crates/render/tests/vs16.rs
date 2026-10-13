//! VS16 emoji presentation: U+2764 U+FE0F asks for the EMOJI face of a character the
//! text fonts also cover. The width stays 1 (oracle-measured, corpus-pinned as
//! vs16-cluster-stays-narrow); what changes is the face choice, and the cluster must be
//! scaled to fit the cell's width so it cannot bleed over a neighbor.
//!
//! **The observable changed on 2026-08-26 and this file is the honest record of why.**
//! Until then both halves rode on CHROMATIC ink, because the emoji face was the only
//! thing on screen that could produce it. Emoji are painted in the cell's foreground now
//! (the maintainer's call, see `emoji_probe.rs`), so chromatic ink is gone and it cannot prove
//! anything any more.
//!
//! It does not come back as a weaker proxy. Measured that day at 24px, cell 14x32: the
//! VS16 heart leaves 118 ink pixels over 13 rows and the bare text heart leaves 101 over
//! 11. Those are the same picture to a gate, so ink shape CANNOT tell the two faces
//! apart and pretending otherwise is a vacuous pass waiting to happen.
//!
//! The two claims are split onto the observables that can actually carry them:
//!   - the FACE is a resolve fact, asserted directly against the text stack's answer;
//!   - the CONTAINMENT is a pixel fact, and it got stronger. The neighbors' pixels must
//!     be byte-identical to a control render that puts a plain letter in the middle.
//!     Byte equality catches a bleed of any color, including the monochrome one the old
//!     chromatic assertion would now miss entirely.
//!
//! The braille lesson still holds and is why both run: a resolve proves a font answered,
//! never that ink landed.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{FontStack, Renderer};

const COLS: u16 = 6;
const SIZE: f32 = 24.0;

fn pixels_of(text: &str) -> (Vec<u8>, u32, u32) {
    let mut terminal = Terminal::new(COLS, 1);
    terminal.write(b"\x1b[?25l");
    terminal.write(text.as_bytes());
    let (writer, reader) = channel(COLS, 1);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("fits");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);

    let fonts = FontStack::system(SIZE).expect("fonts");
    let metrics = fonts.metrics();
    let mut renderer = Renderer::new(fonts, COLS, 1);
    renderer.draw_all(&frame);
    (renderer.pixels(), metrics.width, metrics.height)
}

fn cell(pixels: &[u8], cell_width: u32, height: u32, index: u32) -> Vec<u8> {
    let row_stride = (cell_width * u32::from(COLS) * 4) as usize;
    let mut out = Vec::new();
    for y in 0..height as usize {
        let start = y * row_stride + ((index * cell_width) * 4) as usize;
        out.extend_from_slice(&pixels[start..start + (cell_width * 4) as usize]);
    }
    out
}

#[test]
fn a_vs16_cluster_reaches_the_emoji_face() {
    let mut fonts = FontStack::system(SIZE).expect("fonts");
    let text = fonts.resolve('\u{2764}').expect("a text font covers U+2764");
    let emoji = fonts
        .resolve_emoji('\u{2764}')
        .expect("the emoji face covers U+2764");
    assert_ne!(
        text.font, emoji.font,
        "VS16 resolved to the same face as plain text -- the selector did nothing"
    );
}

#[test]
fn a_vs16_cluster_leaves_ink_inside_its_cell() {
    // The braille lesson: the resolve above proves a font answered, not that anything was
    // drawn. Apple Color Emoji is an sbix face and a blank strike would still resolve.
    let (pixels, width, height) = pixels_of("a\u{2764}\u{FE0F}b");
    let heart = cell(&pixels, width, height, 1);
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    let lit = heart.chunks(4).filter(|p| p[0] > floor + 40).count();
    assert!(lit > 0, "the VS16 heart drew nothing in its own cell");
}

#[test]
fn a_vs16_cluster_does_not_touch_either_neighbor() {
    let (heart, width, height) = pixels_of("a\u{2764}\u{FE0F}b");
    let (control, cw, ch) = pixels_of("axb");
    assert_eq!((width, height), (cw, ch));
    for index in [0u32, 2] {
        assert_eq!(
            cell(&heart, width, height, index),
            cell(&control, width, height, index),
            "cell {index} differs from the control -- the heart bled out of cell 1"
        );
    }
}

//! Gate for SGR 1 and SGR 3 drawn with real faces (fonts track F1, 2026-10-02).
//!
//! Until this slice the core parsed bold and italic and the renderer drew both as Regular,
//! because only Regular faces shipped. The pixel tests here render the same text plain and
//! styled through the whole pipeline (terminal, frame, renderer) and read the ink, so they
//! fail on any break between the cell's style and the face that draws it.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{FaceStyle, FontStack, Renderer};

const COLS: u16 = 12;
const SIZE: f32 = 16.0;

/// Renders `bytes` on one row with the default stack and returns (width, height, rgba).
fn render(bytes: &[u8]) -> (u32, u32, Vec<u8>) {
    let mut terminal = Terminal::new(COLS, 1);
    terminal.write(b"\x1b[?25l");
    terminal.write(bytes);
    let (writer, reader) = channel(COLS, 1);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("fits");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);
    let fonts = FontStack::system(SIZE).expect("default stack");
    let mut renderer = Renderer::new(fonts, COLS, 1);
    renderer.draw_all(&frame);
    let (width, height) = (renderer.canvas().width(), renderer.canvas().height());
    (width, height, renderer.pixels())
}

/// Coverage per pixel, 0..=255, from the brightest channel.
fn coverage(pixels: &[u8]) -> Vec<u32> {
    pixels.chunks_exact(4).map(|p| u32::from(p[0].max(p[1]).max(p[2]))).collect()
}

fn ink(bytes: &[u8]) -> u64 {
    let (_, _, pixels) = render(bytes);
    coverage(&pixels).iter().map(|&c| u64::from(c.saturating_sub(24))).sum()
}

/// How far right the ink in the top half sits relative to the bottom half, in pixels. Not zero
/// for upright text (JetBrains Mono's `l` has a tail to the right at the foot, -1.76px), so
/// the tests compare a style against the same text upright.
fn lean(bytes: &[u8]) -> f64 {
    let (width, height, pixels) = render(bytes);
    let cov = coverage(&pixels);
    let centroid = |rows: std::ops::Range<u32>| {
        let (mut sum, mut weight) = (0f64, 0f64);
        for y in rows {
            for x in 0..width {
                let c = f64::from(cov[(y * width + x) as usize].saturating_sub(24));
                sum += c * f64::from(x);
                weight += c;
            }
        }
        sum / weight.max(1.0)
    };
    centroid(0..height / 2) - centroid(height / 2..height)
}

#[test]
fn bold_draws_heavier_ink_in_every_script() {
    for text in ["Hello, mill", "שלום עולם", "مرحبا بكم"] {
        let plain = ink(text.as_bytes());
        let bold = ink(format!("\x1b[1m{text}").as_bytes());
        let ratio = bold as f64 / plain as f64;
        // Measured in F0: real bold faces carry 1.33x (Latin) to 1.42x (Hebrew) the ink.
        assert!(ratio > 1.2, "{text:?}: bold has {ratio:.2}x the ink of regular");
    }
}

#[test]
fn italic_leans_right_of_the_same_text_upright() {
    for text in ["llll", "שלום"] {
        let upright = lean(text.as_bytes());
        let italic = lean(format!("\x1b[3m{text}").as_bytes());
        assert!(italic - upright > 1.0, "{text:?}: italic {italic:.2}px against upright {upright:.2}px");
    }
}

#[test]
fn bold_italic_is_both() {
    let plain = ink(b"llll");
    let both = ink(b"\x1b[1;3mllll");
    assert!(both as f64 / plain as f64 > 1.2, "bold italic is not heavier");
    assert!(lean(b"\x1b[1;3mllll") - lean(b"llll") > 1.0, "bold italic does not lean");
}

#[test]
fn each_style_comes_from_its_own_face_and_keeps_the_cell() {
    let mut stack = FontStack::system(SIZE).expect("default stack");
    let cell = stack.metrics();
    for (c, family) in [('a', "JetBrains"), ('\u{5d0}', "Cousine"), ('\u{628}', "Kawkab")] {
        stack.set_style(FaceStyle::Regular);
        let regular = stack.resolve(c).expect("covered");
        let regular_name = stack.name(regular.font).expect("named");
        assert!(regular_name.contains(family), "{c:?} came from {regular_name}");
        for (style, word) in [(FaceStyle::Bold, "Bold"), (FaceStyle::Italic, "Italic"), (FaceStyle::BoldItalic, "Italic")] {
            stack.set_style(style);
            let styled = stack.resolve(c).expect("covered");
            let name = stack.name(styled.font).expect("named");
            // Kawkab Mono ships no italic: its italic stays the Regular, and its bold italic
            // keeps the weight it can have, from the Bold, rather than dropping to Regular.
            if family == "Kawkab" && style == FaceStyle::Italic {
                assert_eq!(styled, regular, "{c:?} {style:?} came from {name}");
                continue;
            }
            let word = if family == "Kawkab" { "Bold" } else { word };
            assert!(name.contains(family) && name.contains(word), "{c:?} {style:?} came from {name}");
            assert_eq!(
                stack.advance(styled),
                stack.advance(regular),
                "{c:?} {style:?} advances differently from its regular"
            );
        }
    }
    stack.set_style(FaceStyle::Regular);
    assert_eq!(stack.metrics(), cell, "a styled face moved the cell box");
}

#[test]
fn naming_a_family_picks_its_regular_not_a_styled_sibling() {
    // The bundled directory now holds Bold, Italic and BoldItalic beside each Regular, and
    // `find_family` matches file stems by substring in sorted order, where "Bold" sorts
    // before "Regular". Without a preference the operator's `font-family = "JetBrains Mono"`
    // would quietly make every cell bold.
    let named = FontStack::with_primary(Some("JetBrains Mono"), SIZE).expect("named lead");
    let name = named.name(0).expect("named");
    assert!(!name.contains("Bold") && !name.contains("Italic"), "the lead is {name}");
}

#[test]
fn the_caret_keeps_the_weight_of_the_letter_under_it() {
    // The caret repaints its cell after the row, so it chooses a face of its own. Measured as
    // the glyph knocked out of the caret block: a bold letter cuts a wider hole.
    let hole = |bytes: &[u8]| {
        let mut terminal = Terminal::new(COLS, 1);
        terminal.write(bytes);
        terminal.write(b"\x1b[1;2H");
        let (writer, reader) = channel(COLS, 1);
        let mut publisher = Publisher::new(writer);
        publisher.publish(&mut terminal).expect("fits");
        let mut frame = Frame::new();
        reader.read_into(&mut frame);
        let fonts = FontStack::system(SIZE).expect("default stack");
        let cell = fonts.metrics().width;
        let mut renderer = Renderer::new(fonts, COLS, 1);
        renderer.draw_all(&frame);
        let width = renderer.canvas().width();
        let cov = coverage(&renderer.pixels());
        let mut dark = 0u64;
        for (index, &c) in cov.iter().enumerate() {
            let x = index as u32 % width;
            if (cell..2 * cell).contains(&x) {
                dark += u64::from(255u32.saturating_sub(c));
            }
        }
        dark
    };
    let plain = hole(b"llll");
    let bold = hole(b"\x1b[1mllll");
    assert!(bold as f64 / plain as f64 > 1.15, "bold hole {bold} against plain {plain}");
}

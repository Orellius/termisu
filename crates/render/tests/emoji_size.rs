//! Every emoji is the SAME size, whatever its cell width, and it sits on the baseline.
//!
//! The maintainer, 2026-08-26, looking at the first monochrome build: "the sizes of the emoji as a
//! glyph are not symmetric, they have to be the same size regardless, as long as it does
//! not break the symmetry and the readability of the text".
//!
//! They were not, and the gap was a factor of two. A two-cell emoji was fit to the CELL
//! HEIGHT and a VS16 one-cell emoji was then refit DOWN by width so it could not bleed
//! into its neighbour, which is a much smaller box. The grid could not absorb the
//! difference: `vs16-cluster-stays-narrow` is a corpus MATCH pin, the oracle keeps that
//! cluster at width 1, and widening it in the core would be exactly the encoding change
//! that was ruled out.
//!
//! So the box shrank instead of the grid growing. Every emoji is a square of ONE cell
//! advance now, sitting on the text baseline. That is uniform by construction, it can
//! never bleed at any width, and it lands an emoji where a symbol glyph belongs.
//!
//! Measured at the shipped 16px, cell 10x22, baseline 17: `M` inks an 8x12 box, `x` inks
//! 8x9, and an emoji is 10x10. So it sits between the x-height and the cap height, and
//! all three share a bottom edge on the baseline. Cap height, 12, was the other candidate
//! and it was rejected: a 12px square centred in a 10px advance overflows 1px each side,
//! which lands on the neighbour's side bearing and would probably look fine, but it
//! trades a provable "never bleeds" for 20 percent of size.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{CellMetrics, FontStack, Renderer};

const COLS: u16 = 12;
const SIZE: f32 = 16.0;

fn render(text: &str) -> (Vec<u8>, CellMetrics) {
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
    (renderer.pixels(), metrics)
}

/// Ink bounding box over a column range, as (left, top, width, height) in pixels, with
/// left and top relative to the range's own origin.
fn ink_box(
    pixels: &[u8],
    metrics: &CellMetrics,
    columns: std::ops::Range<u32>,
) -> (u32, u32, u32, u32) {
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    let stride = metrics.width * u32::from(COLS);
    let (x0, x1) = (columns.start * metrics.width, columns.end * metrics.width);
    let (mut lx, mut ly, mut hx, mut hy) = (u32::MAX, u32::MAX, 0u32, 0u32);
    for y in 0..metrics.height {
        for x in x0..x1 {
            if pixels[((y * stride + x) * 4) as usize] > floor + 24 {
                lx = lx.min(x);
                hx = hx.max(x);
                ly = ly.min(y);
                hy = hy.max(y);
            }
        }
    }
    assert!(lx != u32::MAX, "no ink at all in columns {x0}..{x1}");
    (lx - x0, ly, hx - lx + 1, hy - ly + 1)
}

/// A two-cell emoji, two blank cells, then a VS16 one-cell emoji.
const LINE: &str = "\u{1F9E0}  \u{2764}\u{FE0F}";

#[test]
fn a_one_cell_emoji_is_the_same_size_as_a_two_cell_one() {
    let (pixels, metrics) = render(LINE);
    let (_, _, wide_w, wide_h) = ink_box(&pixels, &metrics, 0..2);
    let (_, _, narrow_w, narrow_h) = ink_box(&pixels, &metrics, 4..5);
    // Ink is the artwork's own silhouette, not the box, so two different emoji never fill
    // their squares identically. One pixel of slack absorbs that without absorbing the
    // factor of two this gate exists to catch.
    assert!(
        wide_h.abs_diff(narrow_h) <= 1,
        "U+1F9E0 is {wide_h}px tall and the VS16 heart is {narrow_h}px -- emoji are not one size"
    );
    assert!(
        wide_w.abs_diff(narrow_w) <= 1,
        "U+1F9E0 is {wide_w}px wide and the VS16 heart is {narrow_w}px -- emoji are not one size"
    );
}

#[test]
fn an_emoji_is_about_the_size_of_a_cell_advance() {
    // The size has to be NAMED, or "the same size" is satisfied by both being zero and by
    // both filling the screen. One cell advance is the only square that fits a width-1
    // cluster, which is what forces it.
    let (pixels, metrics) = render(LINE);
    let (_, _, _, height) = ink_box(&pixels, &metrics, 0..2);
    assert!(
        height <= metrics.width,
        "the emoji is {height}px in a {}px advance -- it does not fit a single cell",
        metrics.width
    );
    assert!(
        height * 2 > metrics.width,
        "the emoji shrank to {height}px against a {}px advance",
        metrics.width
    );
}

#[test]
fn an_emoji_sits_on_the_baseline_like_a_letter() {
    // Centering it in the cell floats it above the line it stands in.
    //
    // The assertion is EXACT and it has to be. At 16px, cell 10x22 with the baseline at
    // 17, a 10px square sits at rows 7..17 on the baseline and at rows 6..16 centred: the
    // two rules are ONE PIXEL apart, and a tolerance of 2 let the centring mutant through
    // on the first run. There is no more separation to be had at these proportions, so the
    // gate compares against a real letter's own bottom edge instead of against a constant.
    let (pixels, metrics) = render(&format!("M{LINE}"));
    let (_, m_top, _, m_height) = ink_box(&pixels, &metrics, 0..1);
    let (_, top, _, height) = ink_box(&pixels, &metrics, 1..3);
    assert_eq!(
        top + height,
        m_top + m_height,
        "the emoji's ink ends at y={} and M's ends at y={} -- they are not on one baseline",
        top + height,
        m_top + m_height
    );
}

#[test]
fn neither_emoji_touches_a_neighbouring_cell() {
    let (pixels, metrics) = render(LINE);
    let stride = metrics.width * u32::from(COLS);
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    // Columns 2 and 3 are spaces between the two emoji, and 5 onwards is empty.
    for column in [2u32, 3, 5, 6] {
        for y in 0..metrics.height {
            for x in (column * metrics.width)..((column + 1) * metrics.width) {
                let ink = pixels[((y * stride + x) * 4) as usize];
                assert!(
                    ink <= floor + 24,
                    "column {column} holds ink at ({x},{y}) -- an emoji bled out of its cells"
                );
            }
        }
    }
}

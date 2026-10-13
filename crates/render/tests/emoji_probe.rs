//! The PIXEL pin for emoji, and it INVERTED on 2026-08-26.
//!
//! Until that day the contract was the opposite of what it is now: an emoji had to leave
//! CHROMATIC ink, because the bug being pinned was a color glyph pushed down the mask path
//! and coming out as a gray silhouette. The maintainer's call that day was that a colored sticker is
//! not a terminal glyph. So the artwork's own colors are dropped deliberately and the
//! emoji is painted in the cell's foreground, exactly like a letter.
//!
//! This is a SPEC CHANGE, not a test edited to go green. The old assertion was true about
//! the old contract and is kept below, inverted, so the pin still fires if the color path
//! ever comes back by accident.
//!
//! Dropping the face entirely was the other option and it was rejected: the codepoint
//! still occupies two cells, so a removed face draws a two-cell hole and the line still
//! reflows around something invisible. `[🧠 BRAIN]` in Claude Code inside Termisu was the
//! live gap that opened this backlog item in the first place (2026-07-29).

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{FontStack, Renderer};

fn render(text: &str) -> Vec<u8> {
    let mut terminal = Terminal::new(4, 1);
    terminal.write(format!("\u{1b}[?25l{text}").as_bytes());
    let (writer, reader) = channel(4, 1);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("publish");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);
    let fonts = FontStack::system(16.0).expect("fonts");
    let mut renderer = Renderer::new(fonts, 4, 1);
    renderer.draw_all(&frame);
    renderer.pixels()
}

/// Chromatic = the channels disagree. Text ink, the background and "nothing drawn" are all
/// achromatic, so only the artwork's own colors can score here.
fn chromatic(pixels: &[u8]) -> usize {
    pixels
        .chunks(4)
        .filter(|p| p[0] != p[1] || p[1] != p[2])
        .count()
}

/// How far each pixel sits from the darkest pixel on the canvas. The background is the
/// floor, so this counts ink without needing to know the scheme's actual colors.
fn ink_levels(pixels: &[u8]) -> Vec<u8> {
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    pixels.chunks(4).map(|p| p[0].saturating_sub(floor)).collect()
}

#[test]
fn a_brain_emoji_leaves_no_chromatic_ink() {
    let pixels = render("\u{1F9E0}");
    let colored = chromatic(&pixels);
    assert_eq!(
        colored, 0,
        "U+1F9E0 drew {colored} chromatic pixels -- the sticker path is live again"
    );
}

#[test]
fn a_brain_emoji_still_leaves_ink() {
    // The control that makes the assertion above mean something. Deleting the emoji face
    // would also score zero chromatic pixels, and that is the outcome that was rejected.
    let lit = ink_levels(&render("\u{1F9E0}")).iter().filter(|v| **v > 0).count();
    assert!(lit > 0, "U+1F9E0 drew nothing at all -- the face is gone, not monochrome");
}

#[test]
fn a_brain_emoji_keeps_its_internal_detail() {
    // A silhouette is the OTHER way to be achromatic and lit: blit the alpha channel alone
    // and every emoji becomes the same filled blob.
    //
    // Counting distinct levels does NOT catch that, and this assertion was written that way
    // first: the silhouette mutant scored 123 distinct levels against the real path's 178,
    // because an emoji bitmap's anti-aliased EDGE supplies a whole ramp by itself. What
    // separates them is where the pixels pile up. A silhouette has a flat interior, so one
    // level owns a quarter of the ink; an engraving spreads it. Measured 2026-08-26 on
    // U+1F9E0: real 0.023, silhouette 0.251. The threshold below has a 4x margin either way.
    let levels: Vec<u8> = ink_levels(&render("\u{1F9E0}"))
        .into_iter()
        .filter(|v| *v > 0)
        .collect();
    let mut counts = std::collections::HashMap::new();
    for v in &levels {
        *counts.entry(*v).or_insert(0usize) += 1;
    }
    let modal = counts.values().copied().max().unwrap_or(levels.len());
    let share = modal as f64 / levels.len() as f64;
    assert!(
        share < 0.10,
        "one ink level holds {:.1}% of U+1F9E0's {} lit pixels -- that is a silhouette, not an engraving",
        share * 100.0,
        levels.len()
    );
}

#[test]
fn plain_text_stays_achromatic() {
    // The probe's own control: white-on-near-black 'W' must score zero, or the chromatic
    // counter is measuring something other than color glyphs and the test above proves
    // nothing.
    let pixels = render("W");
    assert_eq!(
        chromatic(&pixels),
        0,
        "the default scheme draws gray-on-gray text; chromatic ink here means the probe is broken"
    );
}

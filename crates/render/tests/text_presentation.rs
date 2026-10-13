//! A narrow cell is TEXT presentation. Claude Code marks every message with U+23FA, a
//! character with no Emoji_Presentation, and Termisu drew it from Apple Color Emoji: the
//! emoji's rounded button, silhouetted in the foreground (the maintainer, 2026-10-02: "why are there
//! still emojis in Claude's prints?"). Ghostty and Terminal draw a plain dot from a text face.
//!
//! The emoji artwork is a filled rounded SQUARE and the text glyph is a DISC, so the
//! discriminator is the inked bounding box's corners: the square fills them, a disc cannot.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{FontStack, Renderer};

fn render(text: &str) -> (Vec<u8>, u32) {
    let mut terminal = Terminal::new(4, 1);
    terminal.write(format!("\u{1b}[?25l{text}").as_bytes());
    let (writer, reader) = channel(4, 1);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("publish");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);
    let fonts = FontStack::system(32.0).expect("fonts");
    let mut renderer = Renderer::new(fonts, 4, 1);
    renderer.draw_all(&frame);
    let width = renderer.cell_metrics().width * 4;
    (renderer.pixels(), width)
}

/// Share of the inked bounding box's four corner regions that carry ink.
fn corner_fill(pixels: &[u8], width: u32) -> f32 {
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    let height = pixels.len() as u32 / 4 / width;
    let inked = |x: u32, y: u32| pixels[((y * width + x) * 4) as usize].saturating_sub(floor) > 96;
    let (mut x0, mut y0, mut x1, mut y1) = (width, height, 0, 0);
    for y in 0..height {
        for x in 0..width {
            if inked(x, y) {
                x0 = x0.min(x);
                y0 = y0.min(y);
                x1 = x1.max(x);
                y1 = y1.max(y);
            }
        }
    }
    assert!(x1 > x0 && y1 > y0, "nothing was drawn");
    let side = ((x1 - x0).min(y1 - y0) / 6).max(1);
    let mut hit = 0;
    let mut total = 0;
    for (cx, cy) in [(x0, y0), (x1 + 1 - side, y0), (x0, y1 + 1 - side), (x1 + 1 - side, y1 + 1 - side)] {
        for y in cy..cy + side {
            for x in cx..cx + side {
                total += 1;
                if inked(x, y) {
                    hit += 1;
                }
            }
        }
    }
    hit as f32 / total as f32
}

#[test]
fn claude_s_message_mark_draws_as_a_text_dot_not_an_emoji_button() {
    let (pixels, width) = render("\u{23FA}");
    let fill = corner_fill(&pixels, width);
    eprintln!("U+23FA corner fill {fill}");
    assert!(fill < 0.25, "U+23FA filled {fill} of its corners: the emoji button is drawn");
}

#[test]
fn a_square_glyph_fills_its_corners_so_the_probe_can_see_a_square() {
    // The control: a full block is all corners. Without it a probe that never sees ink in a
    // corner would pass the test above for any glyph.
    let (pixels, width) = render("\u{25A0}");
    let fill = corner_fill(&pixels, width);
    assert!(fill > 0.75, "U+25A0 filled only {fill} of its corners; the probe is blind");
}

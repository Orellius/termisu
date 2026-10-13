//! Not a gate. A way to LOOK at the blend, because a colour-space change is judged by eye and
//! `CLAUDE.md` says aesthetic claims are not settled by a test.
//!
//! Ignored by default and driven by `TERMISU_SHOT`, so it costs the suite nothing:
//!
//! ```sh
//! TERMISU_SHOT=/tmp/shot TERMISU_BLENDING=corrected \
//!     cargo test -p termisu-vt-render --test look -- --ignored
//! ```
//!
//! `TERMISU_FONT` is a font file path or family name, threaded through `FontStack::with_primary`
//! exactly as the host threads the config's `font-family`. The lead answers first and defines
//! the cell box; the system stack stays behind it, so Hebrew keeps Cousine and Arabic
//! keeps Kawkab. Without it, face 0 is Menlo, which is what `FontStack::system` hardcodes.
//!
//! `TERMISU_BLENDING` is `native`, `linear` or `corrected` (the default). Shooting all three from
//! ONE build is the point: the earlier way to get a "before" was to stash the source and rebuild,
//! and two renders that silently came from the same code is a trap this project has already paid
//! for once (`docs/RENDERING.md`, the unquoted-pathspec `git checkout`).
//!
//! Related but not the same tool: `cargo run -p termisu-vt-render --example screenshot` drives a
//! REAL pty and is the right thing for README images. This writes a fixed synthetic frame, so an
//! A/B of the blend is not also an A/B of whatever the shell happened to print.
//!
//! Writes `<path>.bmp` at 1:1 and `<path>-zoom.bmp` magnified with NEAREST-NEIGHBOUR, which is
//! the point: any smooth resampler invents its own intermediate shades and would hide exactly
//! the antialiasing this is meant to show.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, ReadOutcome, channel};
use termisu_vt_render::{Canvas, FontStack, Renderer, gamma::Blending};

const COLS: u16 = 44;
const ROWS: u16 = 9;
const ZOOM: u32 = 6;

/// Ordinary terminal traffic rather than a test pattern: a powerline prompt, prose, source,
/// Hebrew, and dim grey on dark, which is where under-lit antialiasing shows up worst.
const SCRIPT: &[&[u8]] = &[
    // A REAL powerline prompt, separators and all. The old first line faked one with plain
    // colours, which meant this frame could not show whether the stack answers for U+E0B0 --
    // and for months it did not, on any face, with nothing reporting it.
    "\x1b[30;42m \u{e0a0} main \x1b[32;44m\u{e0b0}\x1b[30m ~/termisu \x1b[0;34m\u{e0b0}\x1b[0m"
        .as_bytes(),
    b"\r\n$ cargo test --workspace",
    b"\r\n\x1b[1mrunning 767 tests\x1b[0m",
    b"\r\nfn blend(&mut self, alpha: u8) -> Rgba {",
    b"\r\n\x1b[90m    // the quick brown fox jumps\x1b[0m",
    "\r\nשלום עולם, בדיקת עברית".as_bytes(),
    // Mixed RTL and LTR on one row, plus niqqud, because the two ways Hebrew goes wrong here
    // are invisible in a pure-Hebrew line: reordering at a script boundary, and a GPOS mark
    // that lands on the wrong glyph or off the cell entirely.
    "\r\nהרץ \x1b[36mcargo test\x1b[0m בְּמִינְד 2t".as_bytes(),
    b"\r\n\x1b[31merror\x1b[0m: expected 188, got 128",
];

fn magnify(pixels: &[u8], width: u32, height: u32) -> Canvas {
    let mut out = Canvas::new(width * ZOOM, height * ZOOM);
    for y in 0..height {
        for x in 0..width {
            let base = ((y * width + x) * 4) as usize;
            let colour = [
                pixels[base],
                pixels[base + 1],
                pixels[base + 2],
                pixels[base + 3],
            ];
            out.fill((x * ZOOM) as i32, (y * ZOOM) as i32, ZOOM, ZOOM, colour);
        }
    }
    out
}

#[test]
#[ignore = "writes files for a human to look at; driven by TERMISU_SHOT"]
fn shoot_a_sample_frame() {
    let Ok(path) = std::env::var("TERMISU_SHOT") else {
        panic!("set TERMISU_SHOT to the output path stem");
    };

    let mut terminal = Terminal::new(COLS, ROWS);
    let (writer, reader) = channel(COLS, ROWS);
    let mut publisher = Publisher::new(writer);
    let mut frame = Frame::new();
    // `with_primary`, NOT a hand-built stack. A replaced stack drops Cousine and Kawkab,
    // so Hebrew and Arabic fall through to proportional faces and drift off the grid -- which
    // looks like a defect in the lead font and is not. This is the exact path the config's
    // `font-family` takes, so what comes out is what the operator would actually see.
    let fonts = FontStack::with_primary(std::env::var("TERMISU_FONT").ok().as_deref(), 16.0)
        .expect("the font stack");

    let mode = match std::env::var("TERMISU_BLENDING").as_deref() {
        Ok("native") => Blending::Native,
        Ok("linear") => Blending::Linear,
        Ok("corrected") | Err(_) => Blending::LinearCorrected,
        Ok(other) => panic!("TERMISU_BLENDING must be native, linear or corrected, got {other:?}"),
    };

    let mut renderer = Renderer::new(fonts, COLS, ROWS);
    renderer.surface_mut().set_blending(mode);

    for step in SCRIPT {
        terminal.write(step);
        publisher.publish(&mut terminal).expect("fits");
        assert!(matches!(
            reader.read_into(&mut frame),
            ReadOutcome::Fresh(_)
        ));
        renderer.draw(&frame);
    }

    let (width, height) = (renderer.canvas().width(), renderer.canvas().height());
    let pixels = renderer.pixels();

    std::fs::write(format!("{path}.bmp"), renderer.canvas().to_bmp()).expect("wrote the frame");
    std::fs::write(
        format!("{path}-zoom.bmp"),
        magnify(&pixels, width, height).to_bmp(),
    )
    .expect("wrote the magnified frame");
    eprintln!("wrote {path}.bmp and {path}-zoom.bmp at {width}x{height} in {mode:?}");
}

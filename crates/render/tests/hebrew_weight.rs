//! Not a gate. Weighs a candidate Hebrew face against the Latin lead, because "the Hebrew looks
//! thin" is an impression and a stroke ratio is a number.
//!
//! ```sh
//! TERMISU_HEBREW=/path/a.ttf,/path/b.ttf cargo test -p termisu-vt-render --test hebrew_weight -- --ignored --nocapture
//! ```
//!
//! Each candidate is loaded as face 1 BEHIND the shipped lead, which is exactly where the real
//! stack puts it -- so the cell box is the lead's and the candidate is measured inside it,
//! scaled the way `normalise_to_cell` would scale it. Measuring a face on its own would report
//! its designer's intent rather than what lands on this grid.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{Canvas, FontStack, Renderer};

const COLS: u16 = 44;
const SIZE: f32 = 16.0;
const LATIN: &str = "$ cargo test --workspace";
const HEBREW: &str = "שלום עולם, בדיקת עברית";
/// Niqqud is the decisive check: a face can carry every Hebrew LETTER and still have no GPOS
/// mark attachment, which drops the points into the middle of the cell or onto the wrong glyph.
const NIQQUD: &str = "בְּמִינְד שָׁלוֹם אֱמֶת";

/// Magnifies with NEAREST NEIGHBOUR. Any smooth resampler invents intermediate shades, which
/// is exactly the antialiasing a weight judgement is trying to read.
fn magnify(pixels: &[u8], width: u32, height: u32, zoom: u32) -> Canvas {
    let mut out = Canvas::new(width * zoom, height * zoom);
    for y in 0..height {
        for x in 0..width {
            let base = ((y * width + x) * 4) as usize;
            let colour = [
                pixels[base],
                pixels[base + 1],
                pixels[base + 2],
                pixels[base + 3],
            ];
            out.fill((x * zoom) as i32, (y * zoom) as i32, zoom, zoom, colour);
        }
    }
    out
}

/// Ink pixel count and mean coverage over the whole frame, plus per character.
fn weigh(lead: &str, second: &str, text: &str) -> (usize, f64, f64) {
    let mut terminal = Terminal::new(COLS, 1);
    terminal.write(b"\x1b[?25l");
    terminal.write(text.as_bytes());
    let (writer, reader) = channel(COLS, 1);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("fits");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);

    let fonts = FontStack::load(&[(lead, 0), (second, 0)], SIZE).expect("the pair");
    let mut renderer = Renderer::new(fonts, COLS, 1);
    renderer.draw_all(&frame);

    let pixels = renderer.pixels();
    // A number settles which face is heavier; only a picture settles whether it is RIGHT.
    if let Ok(stem) = std::env::var("TERMISU_SHOT") {
        let name = second.rsplit('/').next().unwrap_or(second);
        let name = if text == NIQQUD { format!("{name}-niqqud") } else { name.to_string() };
        let (width, height) = (renderer.canvas().width(), renderer.canvas().height());
        let zoomed = magnify(&pixels, width, height, 6);
        let _ = std::fs::write(format!("{stem}-{name}.bmp"), zoomed.to_bmp());
    }
    let mut count = 0usize;
    let mut total = 0u64;
    for pixel in pixels.chunks_exact(4) {
        let value = pixel[0].max(pixel[1]).max(pixel[2]);
        if value > 24 {
            count += 1;
            total += u64::from(value);
        }
    }
    let chars = text.chars().filter(|c| !c.is_whitespace()).count() as f64;
    (
        count,
        if count == 0 { 0.0 } else { total as f64 / count as f64 },
        count as f64 / chars,
    )
}

#[test]
#[ignore = "a measurement; driven by TERMISU_HEBREW"]
fn weigh_the_candidates() {
    let Ok(list) = std::env::var("TERMISU_HEBREW") else {
        panic!("set TERMISU_HEBREW to a comma-separated list of font files");
    };
    // The checkout's copy rather than the bundle's, so this runs under plain `cargo test`.
    let lead = format!(
        "{}/../../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf",
        env!("CARGO_MANIFEST_DIR")
    );
    assert!(std::path::Path::new(&lead).is_file(), "{lead} is not a file");

    // The Latin baseline comes from the lead paired with itself, so the number below is the
    // weight of the face the Hebrew has to sit beside.
    let (_, latin_mean, latin_per_char) = weigh(&lead, &lead, LATIN);
    eprintln!("LATIN  JetBrainsMonoNerdFontMono-Regular  {latin_per_char:6.2} px/char  mean {latin_mean:6.1}");

    for path in list.split(',').filter(|entry| !entry.is_empty()) {
        let name = path.rsplit('/').next().unwrap_or(path);
        if !std::path::Path::new(path).is_file() {
            eprintln!("MISS   {name:<34} not a file");
            continue;
        }
        let mut probe = FontStack::load(&[(&lead, 0), (path, 0)], SIZE).expect("the pair");
        let Some(resolved) = probe.resolve('ש') else {
            eprintln!("MISS   {name:<34} carries no Hebrew");
            continue;
        };
        if resolved.font == 0 {
            eprintln!("MISS   {name:<34} the lead answered, so this face was never reached");
            continue;
        }
        let advance = probe.advance(resolved);
        let cell = f64::from(probe.metrics().width);
        let missing: Vec<char> = ('\u{05B0}'..='\u{05C7}')
            .filter(|c| probe.resolve(*c).map_or(true, |r| r.font == 0))
            .collect();
        let (_, mean, per_char) = weigh(&lead, path, HEBREW);
        let _ = weigh(&lead, path, NIQQUD);
        if !missing.is_empty() {
            eprintln!("       {name:<34} MISSING {} niqqud marks: {missing:?}", missing.len());
        }
        eprintln!(
            "HEBREW {name:<34} {per_char:6.2} px/char  mean {mean:6.1}  \
             ratio {:.2}  advance {advance:.2} vs cell {cell:.0}",
            per_char / latin_per_char
        );
    }
}

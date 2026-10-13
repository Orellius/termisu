//! Dumps a PPM of one line so the emoji change can be LOOKED at, not only measured.
//! Not a gate. `cargo run -p termisu-vt-render --example emoji_shot -- out.ppm`

use termisu_vt_core::Terminal;
use termisu_vt_frame::{Frame, Publisher, channel};
use termisu_vt_render::{FontStack, Renderer};

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "emoji.ppm".into());
    let text = "  \u{1F9E0} brain  \u{2764}\u{FE0F} heart  \u{1F680} ship  \u{2705} ok  \u{26A0}\u{FE0F} warn  \u{1F4C1} dir";
    let cols: u16 = 60;
    let rows: u16 = 3;

    let mut terminal = Terminal::new(cols, rows);
    terminal.write(b"\x1b[?25l\r\n");
    terminal.write(text.as_bytes());
    let (writer, reader) = channel(cols, rows);
    let mut publisher = Publisher::new(writer);
    publisher.publish(&mut terminal).expect("publish");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);

    let fonts = FontStack::system(32.0).expect("fonts");
    let metrics = fonts.metrics();
    let mut renderer = Renderer::new(fonts, cols, rows);
    renderer.draw_all(&frame);
    let pixels = renderer.pixels();

    let (w, h) = (metrics.width * u32::from(cols), metrics.height * u32::from(rows));
    let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
    for p in pixels.chunks(4) {
        out.extend_from_slice(&[p[0], p[1], p[2]]);
    }
    std::fs::write(&path, out).expect("write");
    println!("{path}: {w}x{h}");
}

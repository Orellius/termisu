//! Measures whether subpixel positioning has anything to move, BEFORE anything is built for it.
//!
//! The claim on record is that "glyph origins land on integer pixels, so spacing jitters at some
//! sizes". Half of that is checkable in one run: a pen position only loses a fraction if a
//! fraction ever reaches it.
//!
//! ```sh
//! cargo test -p termisu-vt-render --test subpixel_probe -- --ignored --nocapture
//! ```

use termisu_vt_render::{FontStack, Shaper};

const SAMPLES: &[(&str, &[&str])] = &[
    ("latin", &["a", "W", "i", "m", "/", "-", "1"]),
    ("hebrew bare", &["ש", "ל", "ו", "ם"]),
    ("hebrew pointed", &["שָׁ", "בְּ", "אֱ", "יִ"]),
    ("arabic", &["ب", "س", "م"]),
    ("wide", &["漢", "字"]),
];

#[test]
#[ignore = "a measurement, not a gate"]
fn how_much_fraction_ever_reaches_a_pen() {
    // 26 and 32 are the sizes that actually SHIP: the Swift host spawns with
    // `baseFontSize * backingScaleFactor`, so on a 2x display a 13pt or 16pt setting
    // rasterizes at 26 or 32. Measuring only the logical sizes would measure a path
    // nothing renders.
    for size in [13.0f32, 14.0, 16.0, 18.0, 24.0, 26.0, 32.0] {
        let Ok(mut fonts) = FontStack::system(size) else {
            eprintln!("no system fonts at {size}");
            continue;
        };
        let cell = fonts.metrics();
        let mut shaper = Shaper::new();

        let mut fractional = 0usize;
        let mut total = 0usize;
        let mut worst = 0.0f32;
        let mut worst_cluster = String::new();

        for (label, clusters) in SAMPLES {
            for cluster in *clusters {
                let placed: Vec<(f32, f32)> = shaper
                    .shape(&mut fonts, cluster)
                    .iter()
                    .map(|p| (p.x, p.y))
                    .collect();
                for (x, _) in &placed {
                    total += 1;
                    let fraction = (x - x.round()).abs();
                    if fraction > 0.001 {
                        fractional += 1;
                        if fraction > worst {
                            worst = fraction;
                            worst_cluster = format!("{label} {cluster:?} x={x}");
                        }
                    }
                }
            }
        }

        println!(
            "size {size:>5}  cell {}x{}  baseline {}  |  {fractional} of {total} placements carry \
             a fraction, worst {worst:.4}px  {worst_cluster}",
            cell.width, cell.height, cell.baseline
        );
    }
}

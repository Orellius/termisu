//! What a candidate lead face actually covers, before it is allowed to lead.
//!
//! `font.rs` gives the reason Menlo leads and it is a measurement, not a preference: it is the
//! only face in the stack carrying box drawing, blocks and powerline, and the Hebrew face
//! covers **0 of 128** box-drawing codepoints. A lead that cannot draw a TUI turns every
//! `htop`, `lazygit` and `fzf` border into tofu, and no test in this repo would see it.
//!
//! ```sh
//! TERMISU_FACES=/path/one.ttf,/path/two.ttf \
//!     cargo test -p termisu-vt-render --test coverage_compare -- --ignored --nocapture
//! ```

use termisu_vt_render::FontStack;

/// The ranges a lead face has to answer for, and why each one is on the list.
const RANGES: &[(&str, u32, u32)] = &[
    // The TUI border set. This is the one that disqualifies a face outright.
    ("box drawing", 0x2500, 0x257F),
    ("block elements", 0x2580, 0x259F),
    // Shaded and half blocks are what a progress bar and a sixel-less image fall back to.
    ("geometric shapes", 0x25A0, 0x25FF),
    // starship, powerlevel10k and every powerline prompt live here. Private use, so only a
    // patched (Nerd Font) build carries them.
    ("powerline", 0xE0A0, 0xE0B3),
    // The wider Nerd Font icon block, for a prompt that shows a git branch or a language mark.
    ("nerd font icons", 0xE5FA, 0xE6B1),
    // `crates/render/tests/braille_probe.rs` already cares about these.
    ("braille", 0x2800, 0x28FF),
    ("latin", 0x0020, 0x007E),
];

#[test]
#[ignore = "a measurement, not a gate"]
fn what_each_candidate_face_covers() {
    let faces: Vec<String> = std::env::var("TERMISU_FACES")
        .map(|list| list.split(',').map(str::to_string).collect())
        .unwrap_or_else(|_| vec!["/System/Library/Fonts/Menlo.ttc".to_string()]);

    for path in &faces {
        // One face ALONE, deliberately: `with_primary` would let the stack behind it answer and
        // every candidate would score the same. The question here is what this file carries.
        let Ok(mut stack) = FontStack::load(&[(path.as_str(), 0)], 16.0) else {
            println!("{path}: FAILED TO LOAD");
            continue;
        };
        let name = path.rsplit('/').next().unwrap_or(path);
        print!("{name:38}");
        for (label, first, last) in RANGES {
            let total = last - first + 1;
            let covered = (*first..=*last)
                .filter_map(char::from_u32)
                .filter(|c| stack.resolve(*c).is_some())
                .count();
            print!("  {label} {covered}/{total}");
        }
        println!(
            "  cell {}x{}",
            stack.metrics().width,
            stack.metrics().height
        );
    }
}

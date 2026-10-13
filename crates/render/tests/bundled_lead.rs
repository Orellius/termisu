//! The vendored Nerd Font: it LEADS the default stack, and it is reachable by name.
//!
//! The maintainer's call, 2026-08-25. Menlo led until then, and against the reference terminal side by
//! side it was the whole reason this renderer looked dated -- not the blend and not subpixel
//! positioning, both of which were measured and cleared before the typeface was suspected.
//!
//! Two separate failures are covered, and the second is the one that nearly shipped. A face can
//! be vendored, copied into the bundle and loaded happily by the default stack while still being
//! unreachable from the config's `font-family` -- because that path went through `find_family`,
//! which only ever scanned the four system font directories. The font would sit in the app doing
//! nothing unless an operator typed an absolute path into the bundle.

use termisu_vt_render::FontStack;

/// U+E0B0, the solid right-pointing separator. Every powerline prompt draws it, and it is a
/// clean discriminator: it is in the Private Use Area, so no system face answers for it by
/// accident.
const POWERLINE_SEPARATOR: char = '\u{E0B0}';
/// A Nerd Font icon well outside the powerline block, so the assertion is not resting on one
/// codepoint that some other face might happen to carry.
const NERD_ICON: char = '\u{E5FA}';

/// The shipped cell at 16px. It moved from 10x19 the day the lead changed; every window shows
/// fewer rows at the same pixel height, and that cost was accepted knowingly.
const CELL: (u32, u32) = (10, 22);
/// What Menlo measures at the same size. It is still in the stack, one step down, which is what
/// makes it the discriminator for "a configured family actually took".
const MENLO_CELL: (u32, u32) = (10, 19);

#[test]
fn the_default_stack_answers_for_powerline() {
    // The capability this vendoring exists for. Before it, the only face in the stack carrying
    // these was an Iosevka read out of `$HOME/Library/Fonts`, which is absent on a fresh
    // machine -- so a starship prompt drew tofu and nothing reported it.
    let mut stack = FontStack::system(16.0).expect("the system stack");
    assert!(
        stack.resolve(POWERLINE_SEPARATOR).is_some(),
        "nothing in the default stack answers for the powerline separator"
    );
    assert!(
        stack.resolve(NERD_ICON).is_some(),
        "nothing in the default stack answers for a Nerd Font icon"
    );
}

#[test]
fn the_lead_face_defines_the_shipped_cell_box() {
    // RESTATED on 2026-08-25, not widened: this assertion used to demand 10x19 and say the
    // vendored face must never lead. The decision it encoded was reversed, so the number moved
    // with it. What it still does is the only thing it was ever for -- a face swap cannot move
    // the grid silently, in either direction.
    let stack = FontStack::system(16.0).expect("the system stack");
    let cell = stack.metrics();
    assert_eq!(
        (cell.width, cell.height),
        CELL,
        "the shipped cell box moved, so the lead face is not the one this stack declares"
    );
}

#[test]
fn the_lead_carries_the_glyphs_it_was_promoted_for() {
    // Face 0 must answer for Latin AND for the icon block. If a later reshuffle demoted it,
    // powerline would still resolve -- from wherever it landed -- and the cell test above would
    // still pass if the replacement happened to measure 22. This is what tells the two apart.
    let mut stack = FontStack::system(16.0).expect("the system stack");
    for c in ['A', POWERLINE_SEPARATOR, NERD_ICON, '\u{2500}'] {
        let resolved = stack.resolve(c).unwrap_or_else(|| panic!("{c:?} resolves"));
        assert_eq!(resolved.font, 0, "{c:?} did not come from the lead face");
    }
}

#[test]
fn hebrew_comes_from_the_bundled_hebrew_face() {
    // A new LEAD can steal codepoints from every face below it, and this is the expensive one:
    // JetBrains Mono NF carries no Hebrew of its own, but a face that answered with tofu rather
    // than with nothing would shadow the Hebrew face and put Hebrew off the grid.
    let mut stack = FontStack::system(16.0).expect("the system stack");
    let hebrew = stack.resolve('ש').expect("Hebrew resolves");
    assert_ne!(hebrew.font, 0, "Hebrew is being answered by the lead face");

    // And it is Cousine, not Arial Hebrew below it, which is proportional and would drift --
    // the defect `assets/fonts/README.md` records. Named rather than indexed, because the
    // stack drops absent files and every index below the lead can shift.
    //
    // Cousine replaced Miriam Mono CLM on 2026-08-25. Miriam met every correctness
    // requirement and still does; it was swapped for WEIGHT, because the Latin lead got
    // heavier and Miriam is a light face.
    let name = stack.name(hebrew.font).unwrap_or_default();
    assert!(
        name.contains("Cousine"),
        "Hebrew resolved to {name:?} instead of Cousine"
    );

    // Every niqqud mark, not just the letters. A face can carry all 27 Hebrew letters and no
    // mark attachment at all, which drops the points into the middle of the cell -- and the
    // letters would still look perfect, so nothing else here would catch it.
    for mark in '\u{05B0}'..='\u{05C7}' {
        let resolved = stack
            .resolve(mark)
            .unwrap_or_else(|| panic!("U+{:04X} resolves to nothing", mark as u32));
        assert_ne!(
            resolved.font, 0,
            "U+{:04X} came from the lead, which carries no Hebrew",
            mark as u32
        );
    }

    // The lead must also declare itself, so a future stack cannot satisfy every assertion
    // above with some other 22px face.
    let lead = stack.name(0).unwrap_or_default();
    assert!(
        lead.contains("JetBrains"),
        "the lead face is {lead:?}, not the one this stack ships"
    );
}

#[test]
fn a_named_family_takes_over_the_lead() {
    // The one that nearly shipped broken. `find_family` scanned only the four system font
    // directories, so a face inside the app's own Resources could not be named in the config
    // at all -- `with_primary` would silently fall back to the default stack and the operator
    // would see no change and no error.
    //
    // Menlo is the discriminator now that JetBrains ships as the default: naming it must move
    // the cell back to 19px rows.
    let named = FontStack::with_primary(Some("Menlo"), 16.0).expect("named lead");
    assert_eq!(
        (named.metrics().width, named.metrics().height),
        MENLO_CELL,
        "`Menlo` did not take, so `with_primary` fell back to the default stack"
    );

    // And the vendored family still resolves BY NAME, under both the short name an operator
    // would type and the full one off the file. `find_family` matches the file STEM by
    // substring, so the short name works only because the asset is named for the family --
    // worth pinning, since renaming the file would break every config that says "JetBrains
    // Mono" while the default stack, which asks by filename, kept working.
    for family in ["JetBrains Mono", "JetBrains Mono Nerd Font"] {
        assert!(
            FontStack::family_resolves(family),
            "`{family}` resolved to no font file"
        );
    }
}

#[test]
fn a_family_that_resolves_to_nothing_still_yields_a_usable_terminal() {
    // The documented boundary, and it must stay true now that the search list is longer.
    let fallback =
        FontStack::with_primary(Some("no such face anywhere"), 16.0).expect("a usable stack");
    assert_eq!(
        (fallback.metrics().width, fallback.metrics().height),
        CELL
    );
}

#[test]
fn an_empty_family_is_a_miss_rather_than_a_lottery() {
    // Found by rendering, not by reading. `find_family` matches a file stem by SUBSTRING, and
    // every string contains the empty one -- so `font-family = ""` loaded whatever sorted first
    // in the first font directory that existed. On this machine that was a 7x22 cell where the
    // shipped one is 10x22: a wrong grid, chosen at random, per machine, reported by nothing.
    for family in ["", "   ", "-_-"] {
        assert!(
            !FontStack::family_resolves(family),
            "{family:?} resolved to a font file"
        );
        let stack = FontStack::with_primary(Some(family), 16.0).expect("a usable stack");
        assert_eq!(
            (stack.metrics().width, stack.metrics().height),
            CELL,
            "{family:?} took over the lead instead of falling back"
        );
    }
}

// The chrome's colours. ONE place, and every value in it is achromatic.
//
// The maintainer, 2026-08-25: "למה הטרמינל עצמו המנוע, והמעטפת שבנינו לא מסונכרנים על אותם הצבעים?
// זה נראה מאוד מוזר ה Sidebar שעשית, תעבוד עם אפור, שחור, לבן, עד שנפתח Themes לאפליקציה
// של הטרמינל של Termisu".
//
// THE ANSWER TO THE QUESTION, because it is the reason this file exists. The two surfaces
// were never synced because they had no shared source to sync to. The terminal paints
// what the CHILD asks for -- the shell's own palette, plus OSC 4 and OSC 11 overrides,
// which is data arriving down a pty at runtime. The chrome painted a set of constants
// typed into three separate files from a screenshot of another terminal: an emerald
// #2BD99F for anything active, an indigo #5865F2 for anything hot, and greys with a blue
// cast (#0B0D12, #1E222B, #C9CED8). Nothing computed either from the other, so "the same
// colours" was never a thing the code could be true or false about.
//
// UNTIL THEMES LANDS, the answer is to stop competing. A chrome with no hue of its own
// cannot clash with a terminal palette it does not know, whatever the child sets. That is
// what makes greyscale the right answer NOW rather than a placeholder: an invented accent
// is wrong against every theme except the one it was sampled from, and grey is wrong
// against none of them.
//
// WHEN THEMES LANDS this type is where it plugs in: the chrome reads the session's own
// background and derives from it, the way `panelBackground()` in AppDelegate already
// does for the webview. That is one file to change instead of the four this replaced.
//
// EVERY VALUE IS r == g == b, and `--smoke-chrome` asserts it. That is not decoration:
// the failure being guarded is somebody re-sampling a tasteful accent out of a screenshot
// a year from now, which is exactly how the three palettes this file replaced got here.

import AppKit

/// The chrome's ramp, as WHITE OVER THE TERMINAL'S OWN GROUND.
///
/// It was a set of absolute greys until 2026-08-25 evening, and the change is the maintainer's:
/// "צריך שזה ירגיש חלק מהטרמינל ולא חתיכה של Sidebar שפשוט הדבקנו". An absolute grey is
/// a chunk pasted on, because it is a colour the terminal beside it does not have. An
/// alpha over the terminal's own background is the SAME material as the terminal, lit a
/// little. That is the difference between a panel and a margin.
///
/// So every level here is an ALPHA, not a brightness, and `over(_:_:)` is how a level
/// becomes a colour. The ground comes from `Session.background`, which is the renderer's
/// own default background - the child's, through OSC 11 - so the chrome now tracks
/// whatever the terminal is without knowing anything about themes.
///
/// White specifically, never a sampled tint: white over any ground keeps the ground's hue
/// and only raises its value, so the chrome still asserts no colour of its own. That is
/// what keeps last commit's promise while dropping its absolute greys.
enum ChromeColor {
    /// The FALLBACK ground, used before any session has reported one. Opaque.
    static let ink: CGFloat = 0.04
    /// Primary label.
    static let text: CGFloat = 0.92
    /// Secondary label: a path, a branch, a hint.
    static let textMuted: CGFloat = 0.52
    /// What the emerald and the indigo both used to be. Pure white, nothing else.
    static let accent: CGFloat = 1.0

    /// The opaque fallback ground, for surfaces that float ABOVE the terminal rather than
    /// beside it -- the command palette's sheet, the offscreen shot's backdrop. Those
    /// cannot be translucent white over the terminal, because there is terminal text
    /// directly under them and it would read through.
    static func of(_ level: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(white: level, alpha: alpha)
    }

    /// A level as white at that alpha. Composite it over the ground yourself, or hand it
    /// to a layer whose superview already wears the ground.
    static func over(_ level: CGFloat) -> NSColor {
        NSColor(white: 1, alpha: level)
    }

    /// Every level this type publishes, for the gate. Listed rather than derived: a
    /// reflection-based sweep would silently stop covering a level somebody adds.
    static let all: [CGFloat] = [
        ink, text, textMuted, accent,
    ]
}

/// The visual bell.
///
/// BEL rang `NSSound.beep()` until 2026-08-26, the system alert sound. The maintainer that day: a
/// terminal should answer a bell with a terminal's own gesture, not with the OS chime.
///
/// A brief achromatic wash over the pane that rang. It is deliberately FAINT, and that is
/// the design rather than timidity: the bell already has a persistent half, the attention
/// bar on the session's tab, which outlives the flash.
/// The wash only has to catch an eye that is already on the screen. Anything bright enough
/// to be a "flash" in the ordinary sense is a strobe at three in the morning.
enum BellFlash {
    /// Peak opacity of the wash.
    static let peak: CGFloat = 0.10

    /// How long it takes to fade from peak back to nothing.
    static let duration: TimeInterval = 0.14

    /// The wash's grey level. Achromatic, like every other chrome colour.
    static let level: CGFloat = ChromeColor.accent

    /// The key the fade is filed under. One key is what makes a burst coalesce: a second
    /// bell REPLACES the animation instead of adding a second one, so a shell ringing in a
    /// loop is one flash rather than a stack of them whitening the pane.
    static let animationKey = "bell"
}

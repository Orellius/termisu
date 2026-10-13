// The veil over the top of the pane: Nodee's, reproduced.
//
// The maintainer, 2026-10-02, looking at the first cut of option 2 (blurred history behind the band, sharp
// text below it): "אי אפשר לעשות פייד שלא יחתוך את זה ככה? שזה יהיה נעים עם הטקסט כמו שעשינו ב
// Nodee?". The reference is Nodee's `.v2 .fade` (nodee src/renderer/styles.css): a 96px overlay
// from the window top that blurs what is under it by 10px, tints it from the ground colour
// (solid over the top 15%, 70% at 55%, clear at the bottom), and masks itself opaque over the
// top 45% and out to nothing at its bottom edge. The mask is what removes the edge: blur and
// tint both thin out together over the text, so no line marks where they stop.
//
// Termisu cannot blur the live pane behind a layer (both platform blurs failed, see
// TopFade.swift), so the host hands over a strip that already IS the blur: the history rows
// above the viewport and the viewport's first rows, blurred as one image. Laid exactly over the
// sharp rows and masked like Nodee's overlay, it reads the same.

import AppKit

enum TopVeil {
    /// Nodee's overlay height, measured from the window top.
    static let height: CGFloat = 96
    /// Nodee's blur, in points: `backdrop-filter: blur(10px)`.
    static let blur: CGFloat = 10
    /// Nodee's mask: opaque down to 45% of the overlay, then out to nothing at its bottom.
    static let solid: CGFloat = 0.45
    /// Nodee's tint, top to bottom: ground at full strength to 15%, 0.7 at 55%, clear at 100%.
    static let tint: [(location: CGFloat, alpha: CGFloat)] = [(0, 1), (0.15, 1), (0.55, 0.7), (1, 0)]

    /// The overlay in a top pane's coordinates: from the window top, `band` above the pane,
    /// down `height`, across the whole pane.
    static func frame(pane: NSRect, band: CGFloat) -> NSRect {
        NSRect(x: 0, y: pane.height + band - height, width: pane.width, height: height)
    }

    /// Where the strip's mask goes from clear to opaque, as fractions of the strip's height
    /// from its bottom: clear below the overlay, opaque over its top 45%.
    static func mask(strip: NSRect, veil: NSRect) -> (clear: CGFloat, opaque: CGFloat) {
        guard strip.height > 0 else { return (0, 0) }
        let fraction = { (y: CGFloat) in min(1, max(0, (y - strip.minY) / strip.height)) }
        return (fraction(veil.minY), fraction(veil.maxY - veil.height * solid))
    }
}

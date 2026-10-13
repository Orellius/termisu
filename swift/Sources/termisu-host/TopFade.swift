// The soft edge where the terminal meets the tab band.
//
// The maintainer, 2026-10-02, pointing at Nodee's top island: "תבדוק אם אפשר להוסיף לחלק העליון blur
// fade כמו פה". Nodee scrolls its content under the island and blurs it there. Termisu cannot
// do that without giving up layout A (the pane starts below the band so no row sits under
// glass) and teaching the renderer to draw history above row 0, which is option 2 in the
// checkpoint. This is option 1, his pick: the top strip of the pane fades into the band, so the
// terminal reads as passing under it while every row stays where it was.
//
// A FADE, NOT A BLUR, and both blurs were tried in a live capture first. NSVisualEffectView
// paints its material's own grey, which came out as a light stripe with a hard edge. A Core
// Image background filter on a layer over the pane drew nothing at all: the text under it
// stayed sharp. A real blur needs the rows behind the glass, which is option 2.
//
// Always on rather than only while scrolled back: Claude Code runs on the alternate screen,
// where the viewport never scrolls, and that is the screen he looks at most.

import AppKit

final class TopFadeView: NSView {
    /// How far down the pane the fade reaches: the margin and the first row, fading out over
    /// it. 16pt was tried first and changed nothing on screen, because the first row starts
    /// below the margin and the fade ended where the text began.
    static let height: CGFloat = 32

    /// Where the fade sits: across the top of the pane, inside it.
    static func frame(pane: NSRect) -> NSRect {
        let height = min(TopFadeView.height, max(0, pane.height))
        return NSRect(x: pane.minX, y: pane.maxY - height, width: pane.width, height: height)
    }

    private let tint = CAGradientLayer()

    /// The band's colour, which the fade ends in. Set with the window background, because
    /// the terminal's ground changes per session.
    var ground: NSColor = ChromeColor.of(ChromeColor.ink) {
        didSet { paint() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(tint)
        paint()
    }

    required init?(coder: NSCoder) { nil }

    /// Never takes a click: the pane under it owns the mouse, the first row included.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        CATransaction.commit()
    }

    private func paint() {
        // Layer coordinates have y up here, so the band end is the END point.
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        tint.colors = [ground.withAlphaComponent(0).cgColor, ground.cgColor]
    }
}

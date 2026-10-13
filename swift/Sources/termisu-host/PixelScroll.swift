// Smooth pixel scrolling (motion slice M4, the maintainer 2026-10-02), as a pure decision.
//
// THE PROBLEM. The host only ever draws whole viewport rows, and it scrolls on its own thread:
// a row asked for now lands in a frame one or two ticks later. A trackpad moves in points, every
// event. So the view is drawn SHIFTED: the last drawn grid sits `offset` points lower than its
// rest position, and the history rows directly above it (the host's sharp lead rows) fill the
// gap at the top. Whole rows are asked of the host in the background and, when one lands, the
// offset drops by exactly that many rows, so the picture never moves on a landing.
//
// HEADROOM. Climbing is free for several rows, because the lead image holds several rows above
// the grid. Coming back down has no rows below the grid to show, so while a gesture runs the
// grid is kept `headroom` rows under where the operator wants to be, and a trackpad heading back
// toward the live bottom has that many rows of time before it could outrun the pump.
//
// REST IS ALWAYS WHOLE ROWS. When the gesture and its momentum end, the offset glides to the
// nearest whole row and that many rows are asked for; once they land the offset is zero. A
// click, a selection or the caret therefore never sits on a shifted grid.

import CoreGraphics

struct PixelScroll {
    /// Rows the drawn grid is kept under the wanted position while a gesture runs.
    static let headroom = 2
    /// Ticks to wait for asked rows before deciding the host clamped them away.
    static let patience = 30

    /// Points the drawn grid sits below its rest position, relative to the viewport it was
    /// drawn at. May leave the showable range briefly while asked rows are in flight.
    private(set) var offset: CGFloat = 0
    /// Rows asked of the host that have not landed yet, positive toward history.
    private(set) var asked = 0
    /// True from the end of a gesture until the view is back on a whole row with offset zero.
    private(set) var resting = false
    private var askedFrom = 0
    private var waited = 0

    /// The offset to draw at: never below the rest position, and never higher than the real
    /// history rows above the grid can fill.
    func shown(row: CGFloat, above: Int) -> CGFloat {
        min(max(offset, 0), CGFloat(above) * row)
    }

    /// A trackpad delta in points, positive toward history. Returns the rows to ask the host
    /// for now, zero for none. `viewport` is the drawn grid's offset into history, `above` the
    /// real history rows over it, `lead` the rows the lead image holds.
    mutating func move(by delta: CGFloat, row: CGFloat, viewport: Int, above: Int, lead: Int) -> Int {
        resting = false
        offset += delta
        // Not past the live bottom, and not past the oldest row that is known to exist.
        offset = max(offset, -CGFloat(viewport) * row)
        offset = min(offset, CGFloat(min(above, lead)) * row)
        guard asked == 0, row > 0 else { return 0 }
        var rows = Int((offset / row).rounded(.down)) - PixelScroll.headroom
        rows = min(rows, above)
        rows = max(rows, -viewport)
        // Climb only once the offset is a full row past the headroom, so a trackpad resting
        // on a row boundary does not ask and give back the same row every event.
        if rows > 0, offset < CGFloat(PixelScroll.headroom + 1) * row { rows = 0 }
        return ask(rows, from: viewport)
    }

    /// The gesture and its momentum are over. Returns the offset to glide to (a whole row).
    mutating func rest(row: CGFloat, viewport: Int, above: Int) -> CGFloat {
        resting = true
        guard row > 0, asked == 0 else { return offset }
        let whole = (offset / row).rounded()
        offset = min(max(whole, -CGFloat(viewport)), CGFloat(above)) * row
        return offset
    }

    /// After the glide to a whole row: ask for the rows that put the grid where it shows.
    mutating func settle(row: CGFloat, viewport: Int) -> Int {
        guard resting, asked == 0, row > 0 else { return 0 }
        let rows = Int((offset / row).rounded())
        if rows == 0 {
            offset = 0
            resting = false
        }
        return ask(rows, from: viewport)
    }

    /// A frame was drawn at `viewport`. Landed rows come off the offset, so the picture is the
    /// same before and after.
    mutating func landed(viewport: Int, row: CGFloat) {
        guard asked != 0 else { return }
        if viewport != askedFrom {
            offset -= CGFloat(viewport - askedFrom) * row
            asked = 0
            waited = 0
            if resting, abs(offset) < row / 2 {
                offset = 0
                resting = false
            }
            return
        }
        waited += 1
        if waited > PixelScroll.patience {
            // The host never moved: history was pruned or the screen switched under us. At rest
            // that leaves nothing to glide to, so drop straight back onto the drawn grid.
            asked = 0
            waited = 0
            if resting { reset() }
        }
    }

    /// Anything else moved the view (a key, a page chord, a plain wheel): back to whole rows.
    mutating func reset() {
        offset = 0
        asked = 0
        waited = 0
        resting = false
    }

    private mutating func ask(_ rows: Int, from viewport: Int) -> Int {
        guard rows != 0 else { return 0 }
        asked = rows
        askedFrom = viewport
        waited = 0
        return rows
    }
}

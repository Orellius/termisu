// The terminal surface: blit target, key forwarding, and the app's keyboard chords.
//
// The view draws exactly what termisu_host_poll hands over -- an RGBA8 buffer at native
// (backing) resolution, because the host is spawned with font_size scaled by the window's
// backingScaleFactor and the layer's contentsScale set to match. Pixels map 1:1 to device
// pixels; nothing is stretched. Session plumbing lives in AppDelegate.swift.

import AppKit

/// Where the chrome's two pieces go, as arithmetic with no views in it: the title band at
/// the top, and the terminal pane under it.
///
/// THE SIDEBAR IS GONE, the maintainer's call 2026-10-02: "אני לא רוצה שיהיה Sidebars בטרמינל שלי,
/// אני רוצה שיהיה טאבים". The sessions it listed are the tab island in the band now
/// (Tabs.swift), so the pane takes the full width of the window.
///
/// The band is mockup A, his pick the same day: a separate 52pt strip that holds the
/// traffic lights and the island, with the terminal starting below it. The alternative was
/// the island floating over the grid's first rows, and the reason against it is that a
/// terminal's top row is real output that nothing should cover. So the inset belongs to the
/// pane, and without it the band's glass would sit on top of the first line.
struct ChromeLayout: Equatable {
    let pane: NSRect
    /// The title band, full width, at the top of the content.
    let band: NSRect

    /// The unified title band's height. See `TabMetrics.bandHeight`.
    static let topInset: CGFloat = TabMetrics.bandHeight

    static func compute(content: NSSize, topInset: CGFloat = ChromeLayout.topInset) -> ChromeLayout {
        let band = min(max(0, topInset), max(0, content.height))
        let paneHeight = max(0, content.height - band)
        return ChromeLayout(
            pane: NSRect(x: 0, y: 0, width: max(0, content.width), height: paneHeight),
            band: NSRect(x: 0, y: paneHeight, width: max(0, content.width), height: band))
    }
}

final class TerminalView: NSView {
    /// Breathing room between the glyph grid and the window edge, in points. The grid
    /// itself stays exactly cols x rows; the margin belongs to the window, not the pty.
    static let padding: CGFloat = 8

    /// The terminal draws inside this sublayer, inset by `padding`. The root layer
    /// holds only the background color, so the margin matches the terminal's own black.
    let contentLayer = CALayer()

    /// The GPU present target (B1): the bottom sublayer of `contentLayer`, filling it.
    ///
    /// A sublayer rather than a replacement, deliberately. `contentLayer` also carries the
    /// ghost suggestion and supplies the geometry the caret and the wheel arithmetic read, so
    /// swapping its class would drag unrelated code into a rendering change. Inside it, the
    /// metal layer clips and slides with the lead rows and the caret during a pixel scroll (M4).
    let presentLayer = CAMetalLayer()

    /// The history rows above row 0 and the first rows themselves, blurred as one image,
    /// rising out of this view's bounds behind the tab band (option 2 of the top blur, the maintainer
    /// 2026-10-02). Its overlap lies exactly over the sharp first rows and its mask fades it out
    /// there, which is Nodee's veil (see TopVeil.swift). The pane, its grid and every row-0
    /// calculation stay as they were; the band's glass draws over all of it because the island
    /// is a later sibling of the pane container.
    let stripLayer = CALayer()
    private let stripMask = CAGradientLayer()
    /// Nodee's tint over the same overlay, across the whole pane.
    let veilLayer = CAGradientLayer()
    private var stripImage: CGImage?
    private var stripOverlap = 0

    /// The sharp history rows directly above the grid, sliding in at the top as it moves down.
    let leadLayer = CALayer()
    private var pixelScroll = PixelScroll()
    /// The viewport the grid was last drawn at, and the lead rows that match it.
    private var drawnViewport = 0
    private var leadRows = 0
    private var leadAbove = 0
    private var leadPixels = CGSize.zero
    /// Rest is decided a moment after the fingers lift, unless momentum takes over.
    private var restWork: DispatchWorkItem?
    /// Whether a trackpad slides the grid by points (motion on, CPU frames) or steps rows.
    var pixelScrolling = false {
        didSet { if !pixelScrolling { resetPixelScroll() } }
    }
    /// Whether a wheel with these mods would scroll the viewport rather than reach the child.
    var onWheelViewport: ((UInt32) -> Bool)?
    /// From the first event of a gesture until it comes to rest.
    private var sliding = false
    /// Reads the lead rows now, at the start of a gesture, when they were not being kept fresh.
    var onLeadNeeded: (() -> Void)?

    /// Whether the lead rows can show or steer a move: while a gesture runs or the grid sits
    /// off its rest position. At rest the GUI does not read them, which saves a lead image per
    /// streaming frame (step 2 of the render speed work, 2026-10-02).
    var needsLead: Bool {
        pixelScrolling
            && (sliding || pixelScroll.offset != 0 || pixelScroll.asked != 0 || pixelScroll.resting)
    }

    /// The caret, on a layer of its own so it can glide between cells and blink softly
    /// (motion slice M3, the maintainer 2026-10-02). The grid no longer paints it; the host hands over
    /// the exact one-cell image the grid used to paint, and this places it.
    let caretLayer = CALayer()
    /// The cell the caret is on and the cell's size in device pixels; nil while hidden.
    private var caretCell: (column: Int, row: Int)?
    private var caretPixels = CGSize.zero
    private var caretBlinks = false
    private var veilGround: NSColor = ChromeColor.of(ChromeColor.ink)

    /// One keyboard event for the host's key encoder: (action, key, mods,
    /// consumedMods, utf8, unshiftedCodepoint) in the termisu_host_key vocabulary.
    /// Returns whether the terminal produced bytes.
    var onKey: ((UInt32, UInt32, UInt32, UInt32, [UInt8], UInt32) -> Bool)?
    var onPaste: (([UInt8]) -> Void)?
    var onNewSession: (() -> Void)?
    /// cmd+K: the receiver presents (or toggles) the command palette.
    var onPalette: (() -> Void)?
    /// cmd+1 to cmd+9: the receiver brings that tab forward. The argument is the digit,
    /// and 9 means the LAST tab, as it does in Safari and every macOS terminal.
    var onSelectTab: ((Int) -> Void)?
    /// cmd+shift+] and cmd+shift+[: the next or the previous tab, +1 or -1.
    var onStepTab: ((Int) -> Void)?
    /// cmd+shift+D: the receiver toggles the diff review panel (S6). Unset, and so a
    /// dead chord, unless `panels = true` in the config.
    var onDiffPanel: (() -> Void)?
    var onFilesPanel: (() -> Void)?
    /// A bare right-arrow while a ghost suggestion shows: returns whether the
    /// receiver accepted it (typed the remainder); false lets the key go to the child.
    var onAcceptSuggestion: (() -> Bool)?
    var onCloseSession: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    /// A click on a block's gutter bar. The receiver owns the menu and the actions.
    var onBlockClick: ((Block, NSEvent) -> Void)?
    /// cmd+click anywhere on the grid; the receiver resolves the cell and its OSC 8
    /// link, because only it knows the active session's cell metrics.
    var onCommandClick: ((NSPoint) -> Void)?

    /// A press that begins a selection: the point, and AppKit's click count so one handler
    /// covers drag, double-click word and triple-click line. The view does NOT convert to
    /// cells: that needs the session's metrics, which the delegate owns.
    var onSelectPress: ((NSPoint, Int) -> Void)?

    /// A move with the button held. Only sent while a press started a selection, so a drag
    /// that began on the gutter or in a reporting TUI never turns into one halfway.
    var onSelectDrag: ((NSPoint) -> Void)?

    /// cmd+A. Returns whether anything was selected, which is what decides between
    /// swallowing the chord and letting it reach the child.
    var onSelectAll: (() -> Bool)?

    /// cmd+C. Returns false when nothing is highlighted, and the chord then falls through
    /// to the child as `^C` -- which is the whole reason this is conditional: a terminal
    /// where cmd+C stopped interrupting a runaway command would be worse than one that
    /// could not copy at all.
    var onCopySelection: (() -> Bool)?
    /// Scrollback rows: positive climbs into history, Int32.min snaps to the bottom.
    /// The receiver forwards to the active session's host, which owns the clamping.
    var onScroll: ((Int32) -> Void)?
    /// One pointer event for mouse reporting: (action, button, mods, x, y) in the
    /// TERMISU_MOUSE_* vocabulary and surface pixels. Returns whether the terminal
    /// consumed it; false hands the event back to AppKit's default handling.
    var onMouse: ((UInt32, UInt32, UInt32, Float, Float) -> Bool)?
    /// One wheel gesture: (x, y, whole ticks positive-up, mods). Returns whether the
    /// terminal consumed it (mouse-mode report or alternate-scroll arrows); false
    /// means the viewport scroll below is ours.
    var onWheel: ((Float, Float, Int32, UInt32) -> Bool)?
    /// The view's pixel geometry for the mouse encoder: (width, height, inset), all in
    /// backing pixels. Fired from layout and backing-scale changes.
    var onMouseGeometry: ((UInt32, UInt32, UInt32) -> Void)?

    /// The gutter (S2): one thin bar per block in the left margin, drawn from the
    /// shell's OSC 133 marks. Empty without shell integration -- the margin stays bare
    /// rather than guessing at boundaries.
    private var blocks: [Block] = []
    /// The visual bell's wash, created on the first ring and REUSED for every ring after.
    ///
    /// One layer is what makes a burst coalesce. A layer per bell stacks their opacities,
    /// and a shell that rings in a loop -- a failing build script is the ordinary case --
    /// would white the pane out and leave it white. `--smoke-bell` pins that.
    private(set) var bellWash: CALayer?

    private var bars: [CALayer] = []
    /// What a cmd+click under the pointer would open, as rects in this view; empty when it
    /// would open nothing. Asked on every pointer move and every cmd press or release.
    var onLinkHover: ((NSPoint) -> [NSRect])?
    /// The underline under the link the pointer is on, one layer per row it crosses.
    /// Empty when nothing is marked.
    private var linkMarks: [CALayer] = []
    /// Whether the pointing hand is up, so clearing restores the arrow only once.
    private var showsHand = false
    /// Whether an underline is up. The poll re-asks only then, so a mark a streaming child
    /// scrolled away from moves or clears without a pointer move, at no cost otherwise.
    var isMarkingLink: Bool { !linkMarks.isEmpty }
    static let linkMarkColor = NSColor(white: 1, alpha: 0.85).cgColor
    /// Device pixels per cell row, from the active session's first frame; 0 = no grid.
    private var cellHeightDevice = 0
    /// Fractional wheel rows banked between events, so a slow trackpad swipe still
    /// eventually moves a row instead of being rounded away on every tick.
    private var wheelRemainder: CGFloat = 0
    private static let barColor = ChromeColor.of(ChromeColor.accent, alpha: 0.22).cgColor
    /// An indigo #5865F2 until 2026-08-25. It sat in the left margin, one cell from the
    /// child's own output, and it was the single most visible place the chrome disagreed
    /// with the terminal about what colour anything is.
    private static let barHotColor = ChromeColor.of(ChromeColor.accent).cgColor

    override var acceptsFirstResponder: Bool { true }

    /// Fired after the present layer's drawable size changed, with PHYSICAL pixels.
    ///
    /// Physical, not points: a swapchain configured in points on a Retina display is half
    /// resolution, and half resolution looks soft rather than broken, so nothing catches it.
    var onPresentResize: ((UInt32, UInt32) -> Void)?

    // MARK: splits (P3)

    /// A press landed in this pane. Raised BEFORE the press is forwarded, so the first
    /// click into an unfocused pane focuses it AND reaches the child, rather than being
    /// eaten by the focus change - which reads as a pane that ignores its first click.
    var onFocusRequest: (() -> Void)?
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    /// (axis, forward). Forward is right for horizontal and DOWN for vertical.
    var onFocusMove: ((SplitAxis, Bool) -> Void)?

    /// The wash over a pane the keyboard is not talking to, in a split. It replaced a white
    /// focus ring (the maintainer wanted Ghostty's splits): the focused pane is simply the clear one.
    /// Above the grid, strip and veil, so the whole pane recedes, margin included.
    private var dimLayer: CALayer?

    func setDimmed(_ dimmed: Bool, ground: NSColor) {
        guard dimmed || dimLayer != nil else { return }
        wantsLayer = true
        let dim: CALayer
        if let existing = dimLayer {
            dim = existing
        } else {
            dim = CALayer()
            // Focus moves at the speed of a key; an implicit quarter-second fade would leave
            // the pane just typed into still dim for the first characters.
            dim.actions = ["opacity": NSNull(), "backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            dim.zPosition = 1
            layer?.addSublayer(dim)
            dimLayer = dim
        }
        dim.frame = bounds
        dim.backgroundColor = ground.cgColor
        dim.opacity = dimmed ? SplitLook.dim : 0
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: TerminalView.padding, dy: TerminalView.padding)
        contentLayer.frame = content
        layoutLead()
        placeCaret()
        dimLayer?.frame = bounds
        layoutStrip()
        syncPresentLayer(to: content)
        layoutBars()
        pushMouseGeometry()
    }

    /// Where a caret of `cell` device pixels on (`column`, `row`) sits, in this view's
    /// bottom-up points: the grid starts at the top padding edge and grows downward.
    static func caretFrame(bounds: NSRect, column: Int, row: Int, cell: CGSize, scale: CGFloat) -> CGRect {
        let width = cell.width / scale
        let height = cell.height / scale
        return CGRect(
            x: padding + CGFloat(column) * width,
            y: bounds.height - padding - CGFloat(row + 1) * height,
            width: width, height: height)
    }

    /// Puts the caret on its cell. A move glides from wherever the caret is drawn right now,
    /// so a burst of moves chains into one motion rather than restarting from each old cell;
    /// `glide` false (motion off, or the caret just appeared) jumps.
    func showCaret(_ image: CGImage?, column: Int, row: Int, cell: CGSize, glide: Bool) {
        guard let image else {
            caretLayer.isHidden = true
            caretCell = nil
            return
        }
        let moved = caretCell.map { $0 != (column, row) } ?? false
        let appeared = caretCell == nil
        let from = caretLayer.presentation()?.position ?? caretLayer.position
        caretCell = (column, row)
        caretPixels = cell
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretLayer.contents = image
        caretLayer.isHidden = false
        placeCaret()
        CATransaction.commit()
        if moved && glide && !appeared {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = from
            slide.toValue = caretLayer.position
            slide.duration = Motion.glide
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            caretLayer.add(slide, forKey: "termisu.glide")
        }
        if moved || appeared { restartBlink() }
    }

    /// Blinking on or off: the focused pane of a split blinks, the others hold still.
    func setCaretBlink(_ on: Bool) {
        guard on != caretBlinks else { return }
        caretBlinks = on
        restartBlink()
    }

    private func placeCaret() {
        guard let cell = caretCell, let scale = window?.backingScaleFactor, caretPixels.width > 0 else { return }
        caretLayer.contentsScale = scale
        // In the content layer's coordinates: the caret slides and clips with the grid.
        caretLayer.frame = TerminalView.caretFrame(
            bounds: bounds, column: cell.column, row: cell.row, cell: caretPixels, scale: scale
        ).offsetBy(dx: -TerminalView.padding, dy: -TerminalView.padding)
    }

    /// Steady now, then the soft blink after a rest. The blink is scheduled in the layer's own
    /// clock rather than by a timer, so a key or a move simply replaces it.
    private func restartBlink() {
        caretLayer.removeAnimation(forKey: "termisu.blink")
        guard caretBlinks else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        // Lit, a slow fade out, dark, a slow fade back: a breath, not a flicker.
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.45, 0.6, 0.85, 1]
        blink.timingFunctions = [
            CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        blink.duration = Motion.blink
        blink.repeatCount = .infinity
        blink.beginTime = caretLayer.convertTime(CACurrentMediaTime(), from: nil) + Motion.caretRest
        caretLayer.add(blink, forKey: "termisu.blink")
    }

    /// Shows `image` as the strip, its bottom `overlap` pixel rows being the first rows of the
    /// grid, or hides strip and veil when nil.
    func showStrip(_ image: CGImage?, overlap: Int) {
        stripImage = image
        stripOverlap = overlap
        stripLayer.contents = image
        stripLayer.isHidden = image == nil
        veilLayer.isHidden = image == nil
        layoutStrip()
    }

    /// The ground the veil tints from: this pane's own background.
    func setVeilGround(_ colour: NSColor) {
        guard colour != veilGround else { return }
        veilGround = colour
        layoutStrip()
    }

    private func layoutStrip() {
        guard let image = stripImage else { return }
        let scale = window?.backingScaleFactor ?? stripLayer.contentsScale
        stripLayer.contentsScale = scale
        // Down with the grid while it slides, so the blurred copy stays on its rows.
        let strip = TerminalView.stripFrame(
            bounds: bounds, pixels: CGSize(width: image.width, height: image.height),
            overlap: CGFloat(stripOverlap), scale: scale
        ).offsetBy(dx: 0, dy: -shift)
        stripLayer.frame = strip
        let veil = TopVeil.frame(pane: bounds, band: ChromeLayout.topInset)
        veilLayer.frame = veil

        let (clear, opaque) = TopVeil.mask(strip: strip, veil: veil)
        stripMask.frame = stripLayer.bounds
        stripMask.startPoint = CGPoint(x: 0.5, y: 0)
        stripMask.endPoint = CGPoint(x: 0.5, y: 1)
        stripMask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        stripMask.locations = [0, clear, opaque, 1].map { NSNumber(value: Double($0)) }
        if stripLayer.mask !== stripMask {
            // The strip's own still actions, or every relayout cross-fades the mask.
            stripMask.actions = stripLayer.actions
            stripLayer.mask = stripMask
        }

        // Top to bottom, as Nodee's gradient is written: y = 1 is the layer's top here.
        veilLayer.startPoint = CGPoint(x: 0.5, y: 1)
        veilLayer.endPoint = CGPoint(x: 0.5, y: 0)
        veilLayer.colors = TopVeil.tint.map { veilGround.withAlphaComponent($0.alpha).cgColor }
        veilLayer.locations = TopVeil.tint.map { NSNumber(value: Double($0.location)) }
    }

    /// Where a strip of `pixels` goes: its overlap exactly over the grid's first rows, its left
    /// edge on the grid's, at its true pixel size, rising out of the pane into the band.
    static func stripFrame(bounds: NSRect, pixels: CGSize, overlap: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(
            x: padding, y: bounds.height - padding - overlap / scale,
            width: pixels.width / scale, height: pixels.height / scale)
    }

    /// Keeps the present layer congruent with the content layer, in both units at once.
    ///
    /// `frame` is points, `drawableSize` is device pixels, and getting the pair out of step is
    /// how a terminal ends up sharp on one display and soft on another.
    private func syncPresentLayer(to content: CGRect) {
        // Inside the content layer, which it fills.
        presentLayer.frame = CGRect(origin: .zero, size: content.size)
        let scale = window?.backingScaleFactor ?? presentLayer.contentsScale
        presentLayer.contentsScale = scale
        let pixels = CGSize(
            width: max(1, content.width * scale).rounded(),
            height: max(1, content.height * scale).rounded())
        guard pixels != presentLayer.drawableSize else { return }
        presentLayer.drawableSize = pixels
        onPresentResize?(UInt32(pixels.width), UInt32(pixels.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving between a Retina and a non-Retina display changes the scale without changing
        // the bounds, so layout() is never called and the swapchain would keep its old
        // resolution silently.
        syncPresentLayer(to: contentLayer.frame)
        pushMouseGeometry()
    }

    /// Sends the current pixel geometry to whoever owns the hosts. Public because
    /// geometry is PER-HOST state: session activation must re-send it to a host that
    /// was spawned or backgrounded while another session owned the view.
    func pushMouseGeometry() {
        guard let scale = window?.backingScaleFactor, bounds.width > 0, bounds.height > 0
        else { return }
        onMouseGeometry?(
            UInt32((bounds.width * scale).rounded()),
            UInt32((bounds.height * scale).rounded()),
            UInt32((TerminalView.padding * scale).rounded()))
    }

    /// A pointer location as the mouse encoder's surface pixels: view top-left origin
    /// (AppKit grows upward, the grid downward), backing scale applied.
    private func surfacePoint(_ event: NSEvent) -> (Float, Float)? {
        guard let scale = window?.backingScaleFactor else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return (Float(point.x * scale), Float((bounds.height - point.y) * scale))
    }

    private static func mouseMods(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= 1 }
        if flags.contains(.control) { mods |= 2 }
        if flags.contains(.option) { mods |= 4 }
        return mods
    }

    /// NSEvent.buttonNumber to the protocol's codes, Ghostty's own macOS mapping:
    /// 3/4 are back/forward (protocol 8/9), 7/8 the rare physical 4/5.
    private static func protocolButton(_ number: Int) -> UInt32 {
        switch number {
        case 0: return 1  // left
        case 1: return 3  // right
        case 2: return 2  // middle
        case 3: return 8
        case 4: return 9
        case 5: return 6
        case 6: return 7
        case 7: return 4
        case 8: return 5
        default: return 10  // unnamed in the protocol; bookkeeping only
        }
    }

    /// Forwards one pointer event to mouse reporting. Motion without any pressed
    /// button reports button "none" -- buttonNumber is meaningless on pure moves.
    @discardableResult
    private func forwardMouse(_ event: NSEvent, action: UInt32) -> Bool {
        guard let (x, y) = surfacePoint(event) else { return false }
        let button: UInt32 =
            event.type == .mouseMoved ? 0 : TerminalView.protocolButton(event.buttonNumber)
        return onMouse?(action, button, TerminalView.mouseMods(event.modifierFlags), x, y)
            ?? false
    }

    /// Motion tracking for mode 1003 (and drag-outside delivery). Installed always:
    /// with reporting off the host answers Ignored immediately, and the dedup state
    /// keeps the traffic bounded while it is on.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    /// Marks what a cmd+click would open under the pointer, the way a hyperlink shows on
    /// hover: an underline per row whenever the pointer is on it, and the pointing hand
    /// while cmd is held, because cmd+click is what opens it (a plain click still selects).
    /// The host answers only for text a click would really open, so nothing else is marked.
    func refreshLinkMark(command: Bool) {
        markLink(
            at: pinnedPointer ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) },
            command: command)
    }

    /// A pointer position that stands in for the real mouse, set only by
    /// `TERMISU_HOVER_TAP` so a capture's mark survives the poll's refresh.
    var pinnedPointer: NSPoint?

    /// The mark for a pointer at `point` in this view; nil clears it. Split from
    /// `refreshLinkMark` so a capture can place the pointer without a real mouse.
    func markLink(at point: NSPoint?, command: Bool = false) {
        var rects: [NSRect] = []
        if let point, bounds.contains(point), let onLinkHover {
            rects = onLinkHover(point)
        }
        while linkMarks.count > rects.count {
            linkMarks.removeLast().removeFromSuperlayer()
        }
        while linkMarks.count < rects.count {
            let mark = CALayer()
            mark.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            mark.backgroundColor = TerminalView.linkMarkColor
            layer?.addSublayer(mark)
            linkMarks.append(mark)
        }
        for (rect, mark) in zip(rects, linkMarks) {
            mark.frame = CGRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 1)
        }
        let hand = command && !rects.isEmpty
        if hand {
            NSCursor.pointingHand.set()
        } else if showsHand {
            NSCursor.arrow.set()
        }
        showsHand = hand
    }

    /// Replaces the gutter with the active session's blocks. Cheap when nothing moved.
    func updateGutter(blocks: [Block], cellHeightDevice: Int) {
        guard blocks != self.blocks || cellHeightDevice != self.cellHeightDevice else { return }
        self.blocks = blocks
        self.cellHeightDevice = cellHeightDevice
        while bars.count > blocks.count {
            bars.removeLast().removeFromSuperlayer()
        }
        while bars.count < blocks.count {
            let bar = CALayer()
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        layoutBars()
    }

    /// One point-space rect per block bar, y-flipped (AppKit views grow upward; grid
    /// rows grow downward from the top padding edge).
    private func layoutBars() {
        guard cellHeightDevice > 0, let scale = window?.backingScaleFactor else { return }
        let rowHeight = CGFloat(cellHeightDevice) / scale
        // Down with the grid while it slides, and cut where the grid is cut.
        let grid = CGRect(x: 0, y: TerminalView.padding, width: TerminalView.padding,
                          height: max(0, bounds.height - 2 * TerminalView.padding))
        for (block, bar) in zip(blocks, bars) {
            let top = TerminalView.padding + CGFloat(block.rows.lowerBound) * rowHeight
            let height = CGFloat(block.rows.count) * rowHeight
            let frame = CGRect(
                x: 2, y: bounds.height - top - height - shift, width: 3, height: height - 2
            ).intersection(grid)
            bar.frame = frame.isNull ? .zero : frame
            bar.backgroundColor = TerminalView.barColor
        }
    }

    /// The block whose bar band contains a click in the left margin, if any.
    private func block(at point: NSPoint) -> Block? {
        guard point.x < TerminalView.padding, cellHeightDevice > 0,
            let scale = window?.backingScaleFactor
        else { return nil }
        let rowHeight = CGFloat(cellHeightDevice) / scale
        let row = Int((bounds.height - point.y - TerminalView.padding) / rowHeight)
        return blocks.first { $0.rows.contains(row) }
    }

    /// One visible page of rows, for the cmd+PageUp/PageDown chords. Derived from the
    /// content layer and the live cell metrics rather than asked of anyone.
    private func pageRows() -> Int32 {
        guard cellHeightDevice > 0, let scale = window?.backingScaleFactor else { return 0 }
        return Int32(max(1, Int(contentLayer.bounds.height * scale) / cellHeightDevice))
    }

    /// Trackpad and wheel scrolling drive the scrollback viewport. Positive deltaY --
    /// fingers or wheel moving the content down, toward earlier output -- climbs into
    /// history, the direction every scrolling view on the platform means by it. Precise
    /// deltas arrive in points and are banked as fractional rows; line-based wheels
    /// report rows directly.
    ///
    /// A trackpad on a viewport that is the operator's slides instead (motion slice M4): see
    /// `PixelScroll` for the model and `slide` for the gesture.
    override func scrollWheel(with event: NSEvent) {
        markLink(at: nil)
        guard cellHeightDevice > 0, let scale = window?.backingScaleFactor else { return }
        let rowHeight = CGFloat(cellHeightDevice) / scale
        if pixelScrolling, event.hasPreciseScrollingDeltas,
            !(event.phase.isEmpty && event.momentumPhase.isEmpty),
            onWheelViewport?(TerminalView.mouseMods(event.modifierFlags)) == true
        {
            slide(event, row: rowHeight)
            return
        }
        resetPixelScroll()
        wheelRemainder +=
            event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / rowHeight
            : event.scrollingDeltaY
        let rows = Int32(wheelRemainder.rounded(.towardZero))
        if rows != 0 {
            wheelRemainder -= CGFloat(rows)
            // The terminal's precedence first (mouse-mode wheel reports, alternate
            // scroll); the viewport is the fallback, exactly the host's contract.
            if let (x, y) = surfacePoint(event),
                onWheel?(x, y, rows, TerminalView.mouseMods(event.modifierFlags)) == true
            {
                return
            }
            onScroll?(rows)
        }
    }

    /// One trackpad event while the viewport is the operator's: the grid follows the fingers
    /// by points, whole rows are asked of the host behind it, and when the fingers and the
    /// momentum stop it comes to rest on a whole row.
    private func slide(_ event: NSEvent, row: CGFloat) {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || event.momentumPhase.contains(.began)
        {
            restWork?.cancel()
            restWork = nil
        }
        // The first move is clamped by the rows above the grid, so they must be current.
        if !needsLead { onLeadNeeded?() }
        sliding = true
        let rows = pixelScroll.move(
            by: event.scrollingDeltaY, row: row, viewport: drawnViewport, above: leadAbove, lead: leadRows)
        applyShift()
        if rows != 0 { onScroll?(Int32(rows)) }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            restNow()
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            // Momentum, when there is any, begins a few milliseconds after the fingers lift.
            let work = DispatchWorkItem { [weak self] in self?.restNow() }
            restWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    /// Glides to the nearest whole row and asks the host for it. The glide is additive and
    /// visual only, so the rows may land while it plays without the picture moving.
    private func restNow() {
        restWork?.cancel()
        restWork = nil
        sliding = false
        guard cellHeightDevice > 0, let scale = window?.backingScaleFactor else { return }
        let row = CGFloat(cellHeightDevice) / scale
        let before = shift
        _ = pixelScroll.rest(row: row, viewport: drawnViewport, above: leadAbove)
        let after = shift
        applyShift()
        if after != before {
            let moved = after - before
            let layers: [(CALayer, String)] =
                [(contentLayer, "sublayerTransform.translation.y"), (stripLayer, "position.y")]
                + bars.map { ($0, "position.y") }
            for (layer, path) in layers {
                let glide = CABasicAnimation(keyPath: path)
                glide.fromValue = moved
                glide.toValue = 0
                glide.isAdditive = true
                glide.duration = Motion.settle
                glide.timingFunction = Motion.landing
                layer.add(glide, forKey: nil)
            }
        }
        let rows = pixelScroll.settle(row: row, viewport: drawnViewport)
        if rows != 0 { onScroll?(Int32(rows)) }
    }

    /// Back to whole rows at once: a key, a page chord or a plain wheel moved the view.
    func resetPixelScroll() {
        restWork?.cancel()
        restWork = nil
        sliding = false
        guard pixelScroll.offset != 0 || pixelScroll.asked != 0 || pixelScroll.resting else { return }
        pixelScroll.reset()
        applyShift()
    }

    /// A frame was drawn at `viewport`, with the lead rows the host has now. Rows that landed
    /// come off the offset in the same transaction as the new frame, so nothing moves.
    func drewGrid(viewport: Int, lead: CGImage?, rows: Int, above: Int, leadViewport: Int) {
        drawnViewport = viewport
        // The two channels are read one after the other, so the lead may still describe the
        // previous viewport for a tick. Then the gap shows ground rather than the wrong rows.
        let matched = lead != nil && leadViewport == viewport
        if matched, let lead {
            leadRows = rows
            leadAbove = above
            leadPixels = CGSize(width: lead.width, height: lead.height)
            leadLayer.contents = lead
        }
        leadLayer.isHidden = !matched
        guard pixelScrolling, cellHeightDevice > 0, let scale = window?.backingScaleFactor else { return }
        pixelScroll.landed(viewport: viewport, row: CGFloat(cellHeightDevice) / scale)
        layoutLead()
        applyShift()
        // Rows still owed after a landing that fell short, or a rest that waited on one.
        if pixelScroll.resting, pixelScroll.asked == 0, pixelScroll.offset != 0 { restNow() }
    }

    /// The offset to draw at, in points, on whole device pixels so glyphs stay sharp.
    private var shift: CGFloat {
        guard pixelScrolling, cellHeightDevice > 0, let scale = window?.backingScaleFactor else { return 0 }
        let row = CGFloat(cellHeightDevice) / scale
        return (pixelScroll.shown(row: row, above: leadAbove) * scale).rounded() / scale
    }

    /// The current shift, for the slide tap's log.
    var pixelShift: CGFloat { shift }

    /// Slides the grid, its lead rows, caret and ghost, and the strip and gutter with them.
    private func applyShift() {
        contentLayer.sublayerTransform = CATransform3DMakeTranslation(0, -shift, 0)
        layoutStrip()
        layoutBars()
    }

    /// The lead rows sit directly on top of the grid, out of sight until the grid slides down.
    private func layoutLead() {
        guard let scale = window?.backingScaleFactor, leadPixels.height > 0 else { return }
        leadLayer.contentsScale = scale
        leadLayer.frame = CGRect(
            x: 0, y: contentLayer.bounds.height,
            width: leadPixels.width / scale, height: leadPixels.height / scale)
    }

    /// True between a press that began a selection and its release.
    ///
    /// Gated rather than always-on: `mouseDragged` also fires for a drag that started on the
    /// block gutter or inside a TUI with mouse reporting, and turning those into selections
    /// halfway through is how a click on a button becomes a highlight.
    private var selecting = false

    override func mouseUp(with event: NSEvent) {
        selecting = false
        if !forwardMouse(event, action: 1) {
            super.mouseUp(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if selecting {
            onSelectDrag?(convert(event.locationInWindow, from: nil))
            return
        }
        if !forwardMouse(event, action: 2) {
            super.mouseDragged(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        refreshLinkMark(command: event.modifierFlags.contains(.command))
        if !forwardMouse(event, action: 2) {
            super.mouseMoved(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !forwardMouse(event, action: 0) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !forwardMouse(event, action: 1) {
            super.rightMouseUp(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !forwardMouse(event, action: 2) {
            super.rightMouseDragged(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !forwardMouse(event, action: 0) {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !forwardMouse(event, action: 1) {
            super.otherMouseUp(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !forwardMouse(event, action: 2) {
            super.otherMouseDragged(with: event)
        }
    }

    /// cmd+click into an inactive window is macOS's click-without-activating, and AppKit
    /// only delivers it to a view that accepts first mouse. Refused, every cmd+click made
    /// while another app was in front vanished before `mouseDown` (2026-10-02). A plain
    /// click is still refused: it activates the window and must not also select.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.modifierFlags.contains(.command) ?? false
    }

    override func mouseExited(with event: NSEvent) {
        markLink(at: nil)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Focus FIRST, then let the press through. Focusing on mouseUp instead would make
        // the first click into an unfocused pane do nothing visible, and returning early
        // here would eat it - both read as a pane that ignores its first click.
        onFocusRequest?()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            if onCommandClick == nil {
                FileHandle.standardError.write(Data("link: cmd+click on a pane with no handler\n".utf8))
            }
            onCommandClick?(point)
            markLink(at: nil)
            return
        }
        guard let block = block(at: point) else {
            // The app's own affordances (cmd+click links, the gutter) outrank
            // reporting; past them the child's mouse protocol gets the click.
            // Shift is the conventional override every terminal honours: it takes the
            // click back from a TUI that asked for mouse reporting, which is the only way
            // to copy a line out of vim or a pager. Checked BEFORE forwarding, or the TUI
            // would consume it and there would be no override at all.
            let forced = event.modifierFlags.contains(.shift)
            if forced || !forwardMouse(event, action: 0) {
                // Last, not first: a TUI that asked for reporting gets the click, and
                // selection is what an ordinary shell prompt does with one.
                selecting = true
                onSelectPress?(point, event.clickCount)
            }
            return
        }
        // The clicked bar flashes hot so the menu visibly belongs to it.
        if let index = blocks.firstIndex(of: block), index < bars.count {
            bars[index].backgroundColor = TerminalView.barHotColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, index < self.bars.count else { return }
                self.bars[index].backgroundColor = TerminalView.barColor
            }
        }
        onBlockClick?(block, event)
    }

    /// The app's chords, caught before the key-equivalent machinery falls through to
    /// keyDown -- the minimal host has no menu bar to own them. cmd+V hands the host raw
    /// clipboard bytes: the host owns the encoding (fenceposts or newline folding, by the
    /// child's mode 2004), and building either sequence here would duplicate the
    /// oracle-measured transform.
    ///
    /// Matched on the PHYSICAL key, never on characters: under a Hebrew input source the
    /// V key reports "ו" in charactersIgnoringModifiers, and a character match silently
    /// disables every chord for exactly the user this terminal is built for (found live,
    /// 2026-07-29). ANSI key codes are layout-independent.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Function keys (PageUp/PageDown/Home/End) stamp .function and .numericPad into
        // the flags on their own; stripped so "cmd alone" still reads as cmd alone.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        // The zoom pair also answers with shift held: cmd+shift+= is how most fingers
        // type "cmd plus", and nothing else owns those chords.
        let zoomKey = event.keyCode == 24 || event.keyCode == 27
        // cmd+shift+D is the panel. Shift-qualified deliberately: bare cmd+D belongs to
        // the child (it is EOF-adjacent muscle memory) and taking it would be a chord
        // the terminal stole from every program running in it.
        if mods == [.command, .shift], event.keyCode == 2, let onDiffPanel {
            onDiffPanel()
            return true
        }
        // cmd+shift+E is the file panel, E for explorer. keyCode 14 is kVK_ANSI_E, the
        // physical key, for the Hebrew-layout reason above. Bare cmd+E stays the child's.
        if mods == [.command, .shift], event.keyCode == 14, let onFilesPanel {
            onFilesPanel()
            return true
        }
        // cmd+\ splits right, cmd+shift+\ splits down.
        //
        // NOT cmd+D, which every other terminal uses: the comment above is why, and it
        // still holds - bare cmd+D is EOF-adjacent muscle memory that belongs to the
        // child, and cmd+shift+D is already the diff panel. `\` is VS Code's split chord,
        // it is not muscle memory for anything in a shell, and both halves were free.
        //
        // keyCode 42 is kVK_ANSI_Backslash, the PHYSICAL key. Matching the character
        // would die silently under a Hebrew layout, where nothing logs and the feature is
        // simply absent.
        if event.keyCode == 42 {
            if mods == [.command] {
                onSplitRight?()
                return true
            }
            if mods == [.command, .shift] {
                onSplitDown?()
                return true
            }
        }
        // cmd+shift+[ and ] step through the tabs, the Safari and Terminal chord. Physical
        // keys again: under a Hebrew layout these report other characters.
        if mods == [.command, .shift], let step = TerminalView.tabStep(for: event.keyCode) {
            onStepTab?(step)
            return true
        }
        if mods == [.command], let number = TerminalView.tabNumber(for: event.keyCode) {
            onSelectTab?(number)
            return true
        }
        // cmd+opt+arrow moves focus between panes. Arrow keyCodes are layout-independent.
        if mods == [.command, .option], let move = TerminalView.focusMove(for: event.keyCode) {
            onFocusMove?(move.axis, move.forward)
            return true
        }
        guard mods == [.command] || (mods == [.command, .shift] && zoomKey)
        else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 24:  // kVK_ANSI_Equal -- cmd+= / cmd++
            onZoomIn?()
            return true
        case 27:  // kVK_ANSI_Minus -- cmd+-
            onZoomOut?()
            return true
        case 29:  // kVK_ANSI_0 -- cmd+0, back to the configured size
            onZoomReset?()
            return true
        case 9:  // kVK_ANSI_V
            if let text = NSPasteboard.general.string(forType: .string) {
                onPaste?(Array(text.utf8))
                return true
            }
            return false
        case 0:  // kVK_ANSI_A -- cmd+A, select the visible grid
            return onSelectAll?() ?? false
        case 8:  // kVK_ANSI_C -- cmd+C, copy the highlight, or fall through as ^C
            return onCopySelection?() ?? false
        case 17:  // kVK_ANSI_T
            onNewSession?()
            return true
        case 40:  // kVK_ANSI_K -- cmd+K, the command palette
            onPalette?()
            return true
        case 13:  // kVK_ANSI_W
            onCloseSession?()
            return true
        case 116:  // kVK_PageUp -- cmd+page-up, one page into history
            resetPixelScroll()
            onScroll?(pageRows())
            return true
        case 121:  // kVK_PageDown -- cmd+page-down, one page back toward the bottom
            resetPixelScroll()
            onScroll?(-pageRows())
            return true
        case 115:  // kVK_Home -- cmd+home, the top of scrollback (host clamps)
            resetPixelScroll()
            onScroll?(Int32.max / 2)
            return true
        case 119:  // kVK_End -- cmd+end, the live bottom
            resetPixelScroll()
            onScroll?(Int32.min)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // A key changes what is on screen; a mark left behind would underline other text.
        markLink(at: nil)
        resetPixelScroll()
        // A caret mid-blink while the operator types reads as lag. Steady until they stop.
        restartBlink()
        // Fish's accept gesture: a BARE right-arrow while a ghost shows completes it.
        // Arrow keys stamp .function/.numericPad on their own, so those don't count
        // as modifiers; any real modifier lets the arrow reach the child untouched.
        if event.keyCode == 124,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad]).isEmpty,
            onAcceptSuggestion?() == true
        {
            return
        }
        forwardKey(event, action: event.isARepeat ? 2 : 1)
    }

    /// Releases matter now: kitty's report-events flag asks for them, and the host
    /// answers Ignored under every legacy mode, so forwarding is free.
    override func keyUp(with event: NSEvent) {
        forwardKey(event, action: 0)
    }

    /// A modifier's own press and release arrive as flagsChanged, not keyDown; the
    /// keyCode names the modifier and its flag's presence gives the direction. Kitty
    /// mode with report-all is the consumer. NEVER read characters here -- AppKit
    /// raises on flagsChanged events -- hence the empty text override.
    override func flagsChanged(with event: NSEvent) {
        refreshLinkMark(command: event.modifierFlags.contains(.command))
        guard let flag = TerminalView.modifierFlag(for: event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }
        let action: UInt32 = event.modifierFlags.contains(flag) ? 1 : 0
        forwardKey(event, action: action, textOverride: [])
    }

    /// Which focus move an arrow keyCode names. `forward` is right for the horizontal axis
    /// and DOWN for the vertical one, matching the arrow rather than the coordinate space:
    /// AppKit's y grows upward, and a mover that inherited that would send focus up when
    /// the operator pressed down.
    private static func focusMove(for keyCode: UInt16) -> (axis: SplitAxis, forward: Bool)? {
        switch keyCode {
        case 123: return (.horizontal, false)  // kVK_LeftArrow
        case 124: return (.horizontal, true)  // kVK_RightArrow
        case 125: return (.vertical, true)  // kVK_DownArrow
        case 126: return (.vertical, false)  // kVK_UpArrow
        default: return nil
        }
    }

    /// Which tab digit a keyCode names, 1 to 9. The ANSI digit keyCodes are not in order,
    /// which is why this is a table and not arithmetic.
    static func tabNumber(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1  // kVK_ANSI_1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    /// Which way a bracket keyCode steps through the tabs.
    static func tabStep(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 30: return 1  // kVK_ANSI_RightBracket
        case 33: return -1  // kVK_ANSI_LeftBracket
        default: return nil
        }
    }

    /// Which modifier a flagsChanged keyCode names (left/right pairs share a flag).
    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 54, 55: return .command
        case 57: return .capsLock
        default: return nil
        }
    }

    /// NSEvent modifiers to the GhosttyMods bitmask the encoder speaks. macOS has no
    /// numlock flag; the bit stays clear and mode 1035's default covers the keypad.
    private static func keyMods(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= 1 }
        if flags.contains(.control) { mods |= 2 }
        if flags.contains(.option) { mods |= 4 }
        if flags.contains(.command) { mods |= 8 }
        if flags.contains(.capsLock) { mods |= 16 }
        return mods
    }

    /// The event's translated text, Ghostty's own macOS rules (NSEvent+Extension.swift):
    /// a lone control character is re-translated without control -- the encoder owns
    /// control mapping -- and AppKit's private-use function-key scalars (U+F700...)
    /// never reach the child. Releases carry no text; kitty's associated text is a
    /// press/repeat concept.
    private static func eventText(_ event: NSEvent) -> [UInt8] {
        guard event.type == .keyDown, let characters = event.characters, !characters.isEmpty
        else { return [] }
        if characters.count == 1, let scalar = characters.unicodeScalars.first,
            scalar.value < 0x20
        {
            let plain = event.characters(
                byApplyingModifiers: event.modifierFlags.subtracting(.control))
            return Array((plain ?? "").utf8)
        }
        if characters.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF })
        {
            return []
        }
        return Array(characters.utf8)
    }

    /// Builds the host key event: the generated keycode map for identity, mods minus
    /// control and command as consumed (Ghostty's years-old heuristic -- those two
    /// never contribute to text translation on macOS), and the unmodified codepoint
    /// via byApplyingModifiers rather than charactersIgnoringModifiers, whose
    /// behavior shifts under ctrl.
    @discardableResult
    private func forwardKey(
        _ event: NSEvent, action: UInt32, textOverride: [UInt8]? = nil
    ) -> Bool {
        let key = KeyMap.keyByCode[event.keyCode] ?? 0
        let mods = TerminalView.keyMods(event.modifierFlags)
        let consumed = TerminalView.keyMods(
            event.modifierFlags.subtracting([.control, .command]))
        let text = textOverride ?? TerminalView.eventText(event)
        var unshifted: UInt32 = 0
        if event.type == .keyDown || event.type == .keyUp,
            let chars = event.characters(byApplyingModifiers: []),
            let scalar = chars.unicodeScalars.first
        {
            unshifted = scalar.value
        }
        return onKey?(action, key, mods, consumed, text, unshifted) ?? false
    }

    /// BEL: a brief achromatic wash over the pane, in place of the system alert sound.
    ///
    /// The sound is gone rather than joined, and that is deliberate. `NSSound.beep()` says
    /// something needs you and says nothing about WHICH pane, which is useless the moment
    /// more than one agent is running. The two halves that do carry that are the wash here,
    /// which names the pane, and the attention bar on the dock rail, which outlives it.
    func flashBell() {
        // Self-sufficient on purpose. `wantsLayer` is set by whoever builds the pane, and a
        // bell that silently does nothing when it is not would be a defect no gate could see
        // from the outside.
        wantsLayer = true
        let wash: CALayer
        if let existing = bellWash {
            wash = existing
        } else {
            wash = CALayer()
            wash.backgroundColor = ChromeColor.of(BellFlash.level).cgColor
            // The RESTING value is transparent, so the pane is never left tinted once the
            // fade ends -- the animation supplies the peak and nothing else does.
            wash.opacity = 0
            layer?.addSublayer(wash)
            bellWash = wash
        }
        // The WHOLE pane, margin included, rather than `contentLayer.frame`. A wash that
        // stops at the grid leaves an unwashed black border around itself, which reads as a
        // rectangle appearing rather than as the pane flashing. It also means the bell does
        // not depend on layout having run.
        wash.frame = bounds

        // Replacing under one key is the coalescing. A second bell restarts the fade from
        // peak; it never adds a second fade whose opacity would add to the first.
        wash.removeAnimation(forKey: BellFlash.animationKey)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = BellFlash.peak
        fade.toValue = 0
        fade.duration = BellFlash.duration
        // The chrome's landing curve, so the bell decays the way everything else settles.
        fade.timingFunction = Motion.landing
        wash.add(fade, forKey: BellFlash.animationKey)
    }

}

/// The draggable band between two panes.
///
/// A view rather than a hit-tested rectangle so the cursor can change over it without a
/// tracking area on every pane, and so AppKit's own drag loop carries the gesture: a
/// hand-rolled one has to guess when the mouse leaves the window, and it always guesses
/// wrong on the fast drag that ends outside it.
///
/// It refuses first responder for the reason every chrome view here does: the grid holds
/// it, and a strip that accepts it swallows the next keystroke into nothing, which reads
/// as the terminal having frozen rather than as a focus bug.
final class SplitDividerHandle: NSView {
    private let divider: SplitDivider
    /// Called with the pointer in the SUPERVIEW's coordinates, which is where the layout
    /// arithmetic works. Converting inside the drag loop instead would use this view's
    /// own space, and this view moves while the drag is happening.
    var onDrag: ((NSPoint) -> Void)?

    /// The visible hairline. The view itself is the wider, clear grab area around it.
    private let line = CALayer()

    init(divider: SplitDivider, line colour: NSColor) {
        self.divider = divider
        let grab = SplitLayout.grabRect(divider)
        super.init(frame: grab)
        wantsLayer = true
        line.frame = divider.rect.offsetBy(dx: -grab.minX, dy: -grab.minY)
        line.backgroundColor = colour.cgColor
        layer?.addSublayer(line)
    }

    func setLine(_ colour: NSColor) {
        line.backgroundColor = colour.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        addCursorRect(
            bounds,
            cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        // AppKit's own drag loop. `.leftMouseDragged` plus `.leftMouseUp` only: adding
        // `.periodic` here would deliver timer events this code has no branch for and the
        // loop would spin on them.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onDrag?(superview.convert(next.locationInWindow, from: nil))
        }
    }
}

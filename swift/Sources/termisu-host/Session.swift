// One terminal session: a host handle, its geometry, and the newest image it drew.
//
// The app holds an array of these and blits whichever is active. A background session
// keeps running -- its pty child and pump thread never pause -- and polling it stays
// cheap because an unchanged frame comes back without drawing.

import AppKit
import CTermisuHost

final class Session {
    /// A stable handle, unique for the life of the process.
    ///
    /// The split tree refers to panes by this and NEVER by an index into `sessions`,
    /// because closing a pane shifts every index after it: a tree holding indices would
    /// silently re-point at a neighbour, and the operator would watch a pane they did not
    /// close change into a different program. Assigned here rather than by the host so
    /// there is one source of ids and no way to mint a duplicate.
    let paneID: Int = { Session.nextPaneID += 1; return Session.nextPaneID }()
    private nonisolated(unsafe) static var nextPaneID = 0

    /// The spawn label; shown until the program sets a real title (OSC 0/2).
    let spawnTitle: String
    /// The live title, program-set. The tab strip reads this.
    private(set) var liveTitle: String?
    var title: String { liveTitle ?? spawnTitle }

    /// Deterministic work state -- explicit signals ONLY (the operator's rule: no
    /// idle guessing). OSC 9;4 progress is authoritative when a program emits it;
    /// otherwise the per-CLI title classifier reads the markers the CLI itself
    /// prints. `.done` means "was working, signal cleared, tab not yet looked at".
    /// `.attention` is the fifth, and it is the only one that means the session has STOPPED
    /// and cannot continue without the operator. The maintainer's call 2026-08-26, after the measurement
    /// that killed the alternative: with Claude Code frozen on a permission prompt there is no
    /// title, no `OSC 9;4` and no bell of its own, so the only explicit signal a terminal can
    /// build this on is BEL, which is the oldest "I need you" in the protocol.
    enum WorkState { case idle, working, error, done, attention }
    private(set) var workState: WorkState = .idle
    /// Which classifier table applies -- the first word of the spawned command.
    private let cli: String
    private(set) var host: OpaquePointer?
    private(set) var cols: UInt16
    private(set) var rows: UInt16
    /// Device pixels per cell, derived from the first frame -- the C surface reports
    /// pixels, not metrics.
    private(set) var cellWidth = 0
    private(set) var cellHeight = 0
    /// The terminal's own background, sampled from the frame so the window margin can
    /// wear it. When theme support arrives, the margin follows automatically -- nothing
    /// app-side hardcodes a color.
    private(set) var background: CGColor?
    /// One OSC 133 class byte per grid row (TERMISU_ROW_*), from the last drawn frame.
    /// Empty until a shell with integration has marked something. The gutter's input.
    private(set) var rowClasses: [UInt8] = []
    /// The caret's cell and visibility from the last polled frame (S4's ghost anchor).
    private(set) var cursorCol = 0
    private(set) var cursorRow = 0
    private(set) var cursorVisible = false
    /// Rows scrolled into history at last poll; ghosts only show at the live bottom.
    private(set) var viewportOffset = 0
    private(set) var exited = false

    /// The workspace (S5 worktree) this session belongs to, or nil for an ordinary
    /// session in whatever directory it opened. Purely a label plus the directory the
    /// session was PLACED in; the live cwd still comes from OSC 7, because the child is
    /// free to walk away from where it started.
    let workspace: String?

    convenience init?(
        command: String?, cols: UInt16, rows: UInt16, fontSize: Float, autoDirection: Bool,
        config: OpaquePointer? = nil, title: String, cwd: String? = nil,
        workspace: String? = nil
    ) {
        guard
            let host = spawnHost(
                cols: cols, rows: rows, fontSize: fontSize, command: command,
                autoDirection: autoDirection, config: config, cwd: cwd)
        else { return nil }
        self.init(
            host: host, cols: cols, rows: rows, title: title,
            cli: (command ?? "").split(separator: " ").first.map(String.init) ?? "shell",
            workspace: workspace)
    }

    /// Spawns an agent CLI instead of a shell, on the same pipeline.
    ///
    /// A `Result` rather than an optional, because the three ways this fails are three
    /// different things for the operator to do: install something, remove a flag, or read a
    /// real error. An optional collapses them into "nothing happened", which is how a refused
    /// bypass would look exactly like a missing binary.
    static func agent(
        _ agent: Agent, argv: [String] = [], cols: UInt16, rows: UInt16, fontSize: Float,
        autoDirection: Bool, config: OpaquePointer? = nil, cwd: String? = nil,
        workspace: String? = nil
    ) -> Result<Session, AgentLaunchFailure> {
        spawnAgentHost(
            id: agent.id, argv: argv, cols: cols, rows: rows, fontSize: fontSize,
            autoDirection: autoDirection, config: config, cwd: cwd
        )
        .map { host in
            Session(
                host: host, cols: cols, rows: rows, title: agent.name,
                // The agent's REGISTRY ID, not the binary's name. It is what the busy-marker
                // table below is keyed on, and the two differ the moment an agent ships under
                // more than one binary name -- `antigravity` answers to `agy` on a fresh
                // install, and a tab keyed on that would silently stop classifying.
                cli: agent.id, workspace: workspace)
        }
    }

    /// The one place a session's fields are set. Both spawn paths funnel here so a field
    /// added later cannot be filled in on one path and forgotten on the other.
    private init(
        host: OpaquePointer, cols: UInt16, rows: UInt16, title: String, cli: String,
        workspace: String?
    ) {
        self.host = host
        self.cols = cols
        self.rows = rows
        self.spawnTitle = title
        self.cli = cli
        self.workspace = workspace
    }

    /// Explicit-signal classification, per CLI. The rule itself lives in `WorkStateRule`
    /// so a gate can read it without a pty behind it, which is how two of Claude Code's
    /// three title glyphs stayed missing from the table for as long as it existed.
    private func classify(title: String) {
        guard let next = WorkStateRule.decide(cli: cli, title: title, current: workState)
        else { return }
        workState = next
    }

    func apply(progress state: UInt8) {
        workState = WorkStateRule.afterProgress(state, current: workState)
    }

    /// The child rang the bell. The only explicit "I need you" a terminal is given.
    func ring() {
        workState = WorkStateRule.rang(current: workState)
    }

    func applyTitle(_ text: String) {
        liveTitle = text.isEmpty ? nil : text
        classify(title: text)
    }

    /// The operator looked at the tab; a badge is delivered. Attention included: a badge is
    /// a message TO the operator, and looking is what delivers it.
    func markSeen() {
        workState = WorkStateRule.afterSeen(workState)
    }

    /// Whether this session is presenting into a metal layer rather than handing back pixels.
    private(set) var presenting = false

    /// Takes over a `CAMetalLayer`, so polled frames go to the screen on the GPU.
    ///
    /// `width` and `height` are DEVICE pixels (the layer's drawableSize). Returns whether the
    /// host accepted it; a refusal means the adapter cannot drive that window or the window
    /// offered no usable format, and the caller should stay on the image path rather than show
    /// an empty layer.
    @discardableResult
    func attachLayer(_ layer: CAMetalLayer, width: Int, height: Int) -> Bool {
        guard let host, !exited else { return false }
        let raw = Unmanaged.passUnretained(layer).toOpaque()
        let ok = termisu_host_attach_layer(host, raw, UInt32(width), UInt32(height))
            == TERMISU_HOST_SUCCESS
        presenting = ok
        return ok
    }

    func detachLayer() {
        guard let host, presenting else { return }
        _ = termisu_host_detach_layer(host)
        presenting = false
    }

    /// Reconfigures the swapchain. DEVICE pixels.
    func resizeLayer(width: Int, height: Int) {
        guard let host, presenting else { return }
        _ = termisu_host_resize_layer(host, UInt32(width), UInt32(height))
    }

    /// Puts the current frame on screen. No-op unless a layer is attached.
    @discardableResult
    func present() -> Bool {
        guard let host, presenting, !exited else { return false }
        return termisu_host_present(host) == TERMISU_HOST_SUCCESS
    }

    /// Polls once. Returns a fresh image when the host drew; `exited` flips when the
    /// child is gone. Safe to call at any rate -- unchanged frames cost almost nothing.
    ///
    /// While presenting, the host leaves `frame.pixels` NULL on purpose - the frame never
    /// crosses to the CPU - so this returns nil every time and the caller drives `present()`
    /// instead of looking for an image.
    @discardableResult
    func poll() -> CGImage? {
        guard let host, !exited else { return nil }
        var frame = TermisuHostFrame()
        guard termisu_host_poll(host, &frame) == TERMISU_HOST_SUCCESS else { return nil }

        // The C surface reports the renderer's default background outright -- sampling
        // the corner pixel instead picks up the caret whenever the cursor sits at home,
        // which the margin then wears (measured 2026-07-29, the gray-frame screenshot).
        let (r, g, b, _) = frame.background
        background = CGColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
            alpha: 1)

        var fresh: CGImage?
        if frame.drew, let pixels = frame.pixels {
            fresh = Session.makeImage(pixels, width: Int(frame.width), height: Int(frame.height))
        }
        // Derived from the REPORTED grid size, never from the pixel buffer. The C surface
        // reports width and height off the renderer's canvas whether or not it lends any
        // pixels, and while presenting it lends none by design. These two numbers gate
        // `fitToPane`, so keying them off the readback froze the grid at its spawn size for
        // the whole session: the window grew, the terminal did not, and nothing reported a
        // failure because nothing had failed. (Operator-reported from a screenshot,
        // 2026-08-04; the readback removal took the cell metrics with it.)
        if frame.drew, cellWidth == 0, frame.width > 0, frame.height > 0, cols > 0, rows > 0 {
            cellWidth = Int(frame.width) / Int(cols)
            cellHeight = Int(frame.height) / Int(rows)
        }
        if let semantics = frame.row_semantics, frame.row_count > 0 {
            rowClasses = Array(UnsafeBufferPointer(start: semantics, count: Int(frame.row_count)))
        }
        cursorCol = Int(frame.cursor_col)
        cursorRow = Int(frame.cursor_row)
        cursorVisible = frame.cursor_visible
        viewportOffset = Int(frame.viewport_offset)
        if frame.child_exited { exited = true }
        return fresh
    }

    /// The blurred strip behind the tab band: the history rows above the viewport and its
    /// first rows. Nil before the host drew one.
    private(set) var stripImage: CGImage?
    /// How many of the strip's bottom pixel rows are the viewport's own first rows.
    private(set) var stripOverlap = 0
    private var stripGeneration: UInt64 = 0

    /// Reads the strip, blurred by `radius` device pixels; true when `stripImage` changed.
    /// One seqlock read and a row-stamp check when nothing did.
    @discardableResult
    func pollStrip(radius: UInt32) -> Bool {
        guard let host, !exited else { return false }
        var strip = TermisuHostStrip()
        guard termisu_host_strip(host, radius, &strip) == TERMISU_HOST_SUCCESS,
            strip.generation != stripGeneration, let pixels = strip.pixels
        else { return false }
        stripGeneration = strip.generation
        stripOverlap = Int(strip.overlap)
        stripImage = Session.makeImage(pixels, width: Int(strip.width), height: Int(strip.height))
        return true
    }

    // The caret on its own layer (motion slice M3).
    private(set) var caretImage: CGImage?
    private(set) var caretColumn = 0
    private(set) var caretRow = 0
    private(set) var caretVisible = false
    /// The caret image's size in device pixels: one cell.
    private(set) var caretPixels = CGSize.zero
    private var caretGeneration: UInt64 = 0

    /// Stops the grid painting its own caret; the GUI draws it from `pollCaret` instead.
    func handCaretToLayer() {
        guard let host else { return }
        termisu_host_set_caret(host, false)
    }

    /// Reads the caret from the last polled frame; true when anything about it changed.
    @discardableResult
    func pollCaret() -> Bool {
        guard let host, !exited else { return false }
        var caret = TermisuHostCaret()
        guard termisu_host_caret(host, &caret) == TERMISU_HOST_SUCCESS,
            caret.generation != caretGeneration, let pixels = caret.pixels
        else { return false }
        caretGeneration = caret.generation
        caretColumn = Int(caret.column)
        caretRow = Int(caret.row)
        caretVisible = caret.visible
        caretPixels = CGSize(width: Int(caret.width), height: Int(caret.height))
        caretImage = Session.makeImage(pixels, width: Int(caret.width), height: Int(caret.height))
        return true
    }

    // The sharp history rows above the viewport, for pixel scrolling (motion slice M4).
    private(set) var leadImage: CGImage?
    /// Rows in the image, and how many of the bottom ones are real history.
    private(set) var leadRows = 0
    private(set) var leadAbove = 0
    /// The viewport offset the rows sit above.
    private(set) var leadViewport = 0
    private var leadGeneration: UInt64 = 0

    /// Reads the lead rows; true when anything about them changed.
    @discardableResult
    func pollLead() -> Bool {
        guard let host, !exited else { return false }
        var lead = TermisuHostLead()
        guard termisu_host_lead(host, &lead) == TERMISU_HOST_SUCCESS,
            lead.generation != leadGeneration, let pixels = lead.pixels
        else { return false }
        leadGeneration = lead.generation
        leadRows = Int(lead.rows)
        leadAbove = Int(lead.above)
        leadViewport = Int(lead.viewport)
        leadImage = Session.makeImage(pixels, width: Int(lead.width), height: Int(lead.height))
        return true
    }

    /// Whether a wheel tick with `mods` would scroll the viewport rather than reach the child.
    func wheelScrollsViewport(mods: UInt32) -> Bool {
        guard let host, !exited else { return false }
        return termisu_host_wheel_scrolls_viewport(host, mods)
    }

    /// One row's text, filtered by OSC 133 mark (TERMISU_TEXT_ALL for every cell). Empty
    /// when the row is out of range or nothing has been polled yet.
    func rowText(_ row: UInt16, semantic: UInt8) -> String {
        guard let host else { return "" }
        var length = 0
        guard termisu_host_row_text(host, row, semantic, nil, 0, &length) == TERMISU_HOST_SUCCESS,
            length > 0
        else { return "" }
        var buffer = [UInt8](repeating: 0, count: length)
        guard
            buffer.withUnsafeMutableBufferPointer({ pointer in
                termisu_host_row_text(host, row, semantic, pointer.baseAddress, length, &length)
            }) == TERMISU_HOST_SUCCESS
        else { return "" }
        return String(decoding: buffer, as: UTF8.self)
    }

    enum HostEvent {
        case clipboard(String)
        case notify(title: String, body: String)
        case bell
        case title(String)
        case progress(state: UInt8)
        /// OSC 133;C: execution began -- the typed command is final (S4 records it).
        case commandStart
        /// OSC 7: the working directory, RAW and undecoded. Kept as bytes because the
        /// host normalizes it (percent-escapes, the file:// host) and doing it twice in
        /// two languages is how the two copies drift apart.
        case pwd([UInt8])
    }

    /// The last OSC 7 report this session made, raw. History is keyed by it.
    private(set) var pwdRaw: [UInt8] = []

    /// Records a command under the directory this session last reported.
    ///
    /// Both history calls live here rather than inline at the view layer because
    /// `pwdRaw` is the argument that makes them correct, and getting it wrong is
    /// SILENT: an empty cwd falls back to global history and looks exactly like the
    /// feature not existing. Keeping them on the session is what lets
    /// `--smoke-history` drive the same code the window runs, instead of a copy of it.
    func recordCommand(_ store: OpaquePointer?, command: String) {
        let bytes = Array(command.utf8)
        _ = bytes.withUnsafeBufferPointer { pointer in
            pwdRaw.withUnsafeBufferPointer { cwdPointer in
                termisu_history_append(
                    store, pointer.baseAddress, pointer.count,
                    cwdPointer.baseAddress, pwdRaw.count)
            }
        }
    }

    /// The whole suggested command for `input` (not the remainder), or nil when the
    /// store has nothing. A match made in this directory outranks a newer one made
    /// elsewhere -- the preference is the host's, and `pwdRaw` is how it learns where
    /// "here" is.
    func suggestion(_ store: OpaquePointer?, for input: String) -> String? {
        let inputBytes = Array(input.utf8)
        var length = 0
        let sized = inputBytes.withUnsafeBufferPointer { pointer in
            pwdRaw.withUnsafeBufferPointer { cwdPointer in
                termisu_history_suggest(
                    store, pointer.baseAddress, pointer.count,
                    cwdPointer.baseAddress, pwdRaw.count, nil, 0, &length)
            }
        }
        guard sized == TERMISU_HOST_SUCCESS, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        let copied = inputBytes.withUnsafeBufferPointer { pointer in
            pwdRaw.withUnsafeBufferPointer { cwdPointer in
                buffer.withUnsafeMutableBufferPointer { outPointer in
                    termisu_history_suggest(
                        store, pointer.baseAddress, pointer.count,
                        cwdPointer.baseAddress, pwdRaw.count,
                        outPointer.baseAddress, length, &length)
                }
            }
        }
        guard copied == TERMISU_HOST_SUCCESS else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Drains every pending host-facing event, oldest first. The C contract consumes an
    /// event only when the buffer held it, so size-then-fetch loses nothing.
    func drainEvents() -> [HostEvent] {
        guard let host else { return [] }
        var drained: [HostEvent] = []
        while true {
            var kind: UInt32 = 0
            var length = 0
            guard termisu_host_next_event(host, &kind, nil, 0, &length) == TERMISU_HOST_SUCCESS,
                kind != 0
            else { break }
            var payload = [UInt8](repeating: 0, count: length)
            if length > 0 {
                var fetched: UInt32 = 0
                guard
                    payload.withUnsafeMutableBufferPointer({ pointer in
                        termisu_host_next_event(
                            host, &fetched, pointer.baseAddress, length, &length)
                    }) == TERMISU_HOST_SUCCESS, fetched == kind
                else { break }
            }
            let text = String(decoding: payload, as: UTF8.self)
            switch kind {
            case 1: drained.append(.clipboard(text))
            case 2:
                let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                drained.append(
                    .notify(
                        title: parts.first.map(String.init) ?? "",
                        body: parts.count > 1 ? String(parts[1]) : ""))
            case 3: drained.append(.bell)
            case 4: drained.append(.title(text))
            case 5: drained.append(.progress(state: payload.first ?? 0))
            case 6: drained.append(.commandStart)
            case 7:
                // Held on the session as well as delivered: a suggestion is asked for on
                // ticks where no event arrived, and it still needs to know where it is.
                pwdRaw = payload
                drained.append(.pwd(payload))
            default: break
            }
        }
        return drained
    }

    /// The OSC 8 URI under a cell, if any (last polled frame).
    func linkAt(col: UInt16, row: UInt16) -> String? {
        guard let host else { return nil }
        var length = 0
        guard termisu_host_link_at(host, col, row, nil, 0, &length) == TERMISU_HOST_SUCCESS,
            length > 0
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard
            buffer.withUnsafeMutableBufferPointer({ pointer in
                termisu_host_link_at(host, col, row, pointer.baseAddress, length, &length)
            }) == TERMISU_HOST_SUCCESS
        else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// The cells a cmd+click on a cell would open, one run per row, from
    /// `termisu_host_link_span_at`: what the hover mark underlines. Empty when a click there
    /// would open nothing, so the mark never promises more than the click does.
    func linkSpanAt(col: UInt16, row: UInt16) -> [TermisuHostCellRun] {
        guard let host else { return [] }
        var count = 0
        let cwd = pwdRaw
        let sized = cwd.withUnsafeBufferPointer { raw in
            termisu_host_link_span_at(host, col, row, raw.baseAddress, raw.count, nil, 0, &count)
        }
        guard sized == TERMISU_HOST_SUCCESS, count > 0 else { return [] }
        var runs = [TermisuHostCellRun](repeating: TermisuHostCellRun(), count: count)
        let fetched = cwd.withUnsafeBufferPointer { raw in
            runs.withUnsafeMutableBufferPointer { out in
                termisu_host_link_span_at(
                    host, col, row, raw.baseAddress, raw.count, out.baseAddress, out.count, &count)
            }
        }
        guard fetched == TERMISU_HOST_SUCCESS else { return [] }
        return Array(runs.prefix(count))
    }

    /// The file a cmd+click on a cell means, with the 1-based line and column the text
    /// named, from `termisu_host_path_at`: an OSC 8 `file://` link there, or path-like text
    /// resolved against this pane's OSC 7 directory. The policy is Rust's (`paths.rs`).
    func pathAt(col: UInt16, row: UInt16) -> (path: String, line: Int?, column: Int?)? {
        guard let host else { return nil }
        var length = 0
        var line: UInt32 = 0
        var column: UInt32 = 0
        let cwd = pwdRaw
        let sized = cwd.withUnsafeBufferPointer { raw in
            termisu_host_path_at(
                host, col, row, raw.baseAddress, raw.count, nil, 0, &length, &line, &column)
        }
        guard sized == TERMISU_HOST_SUCCESS, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let fetched = cwd.withUnsafeBufferPointer { raw in
            buffer.withUnsafeMutableBufferPointer { out in
                termisu_host_path_at(
                    host, col, row, raw.baseAddress, raw.count, out.baseAddress, length, &length,
                    &line, &column)
            }
        }
        guard fetched == TERMISU_HOST_SUCCESS else { return nil }
        return (
            String(decoding: buffer, as: UTF8.self), line > 0 ? Int(line) : nil,
            column > 0 ? Int(column) : nil
        )
    }

    // MARK: selection

    /// Selects the word under a cell, the double-click gesture. `false` means nothing was
    /// selectable there, which is an ordinary answer rather than a failure.
    @discardableResult
    func selectWord(col: UInt16, row: UInt16) -> Bool {
        guard let host else { return false }
        var found = false
        guard termisu_host_select_word_at(host, col, row, &found) == TERMISU_HOST_SUCCESS else {
            return false
        }
        return found
    }

    /// Selects the line under a cell, the triple-click gesture. Trailing blanks are trimmed
    /// by the engine, so a 200-column row holding 12 characters copies 12.
    @discardableResult
    func selectLine(col: UInt16, row: UInt16) -> Bool {
        guard let host else { return false }
        var found = false
        guard termisu_host_select_line_at(host, col, row, &found) == TERMISU_HOST_SUCCESS else {
            return false
        }
        return found
    }

    /// Extends a drag from the cell the press landed on to the cell the pointer holds.
    @discardableResult
    func selectTo(anchor: (col: UInt16, row: UInt16), col: UInt16, row: UInt16) -> Bool {
        guard let host else { return false }
        var found = false
        guard
            termisu_host_select_to(host, anchor.col, anchor.row, col, row, &found)
                == TERMISU_HOST_SUCCESS
        else { return false }
        return found
    }

    /// Selects the visible grid. Not the scrollback: a frame is a viewport.
    @discardableResult
    func selectAll() -> Bool {
        guard let host else { return false }
        var found = false
        guard termisu_host_select_all(host, &found) == TERMISU_HOST_SUCCESS else { return false }
        return found
    }

    func clearSelection() {
        guard let host else { return }
        _ = termisu_host_select_clear(host)
    }

    /// The clipboard text for the current highlight, formatted by the engine.
    ///
    /// Never assembled here from row text: soft-wrap joining and trailing-whitespace rules
    /// are corpus-pinned against the real reference library, and a copy that walked the grid
    /// in Swift would look right on screen and paste wrong.
    func selectionText() -> String? {
        guard let host else { return nil }
        var length = 0
        guard termisu_host_selection_text(host, nil, 0, &length) == TERMISU_HOST_SUCCESS,
            length > 0
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard
            buffer.withUnsafeMutableBufferPointer({ pointer in
                termisu_host_selection_text(host, pointer.baseAddress, length, &length)
            }) == TERMISU_HOST_SUCCESS
        else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Scrolls the view through scrollback; positive climbs into history, negative
    /// returns, `Int32.min` snaps to the live bottom (the host's documented sentinel).
    /// The host clamps against what history holds; the landed position rides back in
    /// the next polled frame's viewport_offset.
    func scroll(_ rows: Int32) {
        guard let host else { return }
        _ = termisu_host_scroll(host, rows)
    }

    func send(_ bytes: [UInt8]) {
        guard let host else { return }
        _ = bytes.withUnsafeBufferPointer { buffer in
            termisu_host_send(host, buffer.baseAddress, buffer.count)
        }
    }

    /// Tells the host what pixel space pointer events arrive in: the view's size and
    /// content insets, in backing pixels. Re-sent on every layout change AND on session
    /// activation -- geometry is per-host state, and a session spawned while another
    /// was frontmost has never seen the view.
    func mouseGeometry(width: UInt32, height: UInt32, inset: UInt32) {
        guard let host else { return }
        _ = termisu_host_mouse_geometry(host, width, height, inset, inset, inset, inset)
    }

    /// One pointer event in surface pixels. True when the terminal consumed it (a
    /// report went to the child); false hands the event back to AppKit.
    func mouse(action: UInt32, button: UInt32, mods: UInt32, x: Float, y: Float) -> Bool {
        guard let host else { return false }
        return termisu_host_mouse(host, action, button, mods, x, y) == TERMISU_HOST_SUCCESS
    }

    /// One wheel gesture in whole ticks, positive up. True when the terminal consumed
    /// it (mouse-mode report or alternate-scroll arrows); false means the viewport
    /// scroll is ours.
    func wheel(x: Float, y: Float, ticks: Int32, mods: UInt32) -> Bool {
        guard let host else { return false }
        return termisu_host_wheel(host, x, y, ticks, mods) == TERMISU_HOST_SUCCESS
    }

    /// One keyboard event through the host's encoder -- every mode (DECCKM, keypad,
    /// kitty flags) rides the frame, so this replaces byte-building entirely. True
    /// when the terminal produced bytes.
    func key(
        action: UInt32, key: UInt32, mods: UInt32, consumedMods: UInt32,
        text: [UInt8], unshiftedCodepoint: UInt32
    ) -> Bool {
        guard let host else { return false }
        return text.withUnsafeBufferPointer { buffer in
            termisu_host_key(
                host, action, key, mods, consumedMods,
                buffer.baseAddress, buffer.count, unshiftedCodepoint)
        } == TERMISU_HOST_SUCCESS
    }

    func paste(_ bytes: [UInt8]) {
        guard let host else { return }
        _ = bytes.withUnsafeBufferPointer { buffer in
            termisu_host_paste(host, buffer.baseAddress, buffer.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard let host, cols != self.cols || rows != self.rows else { return }
        if termisu_host_resize(host, cols, rows) == TERMISU_HOST_SUCCESS {
            self.cols = cols
            self.rows = rows
        }
    }

    /// Live zoom: pty resize plus renderer rebuild at the new size, one C call. Cell
    /// metrics re-derive from the next frame -- the C surface reports pixels, and the
    /// old numbers describe a dead font.
    func setFontSize(_ fontSize: Float, cols: UInt16, rows: UInt16) {
        guard let host else { return }
        if termisu_host_set_font_size(host, fontSize, cols, rows) == TERMISU_HOST_SUCCESS {
            self.cols = cols
            self.rows = rows
            cellWidth = 0
            cellHeight = 0
        }
    }

    func close() {
        if let host {
            termisu_host_free(host)
            self.host = nil
        }
    }

    deinit { close() }

    private static func makeImage(
        _ pixels: UnsafePointer<UInt8>, width: Int, height: Int
    ) -> CGImage? {
        // Copied because the borrow dies at the next poll, and CoreGraphics reads lazily.
        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            // The core's palette bytes are sRGB values and the render crate deliberately
            // does no gamma work ("any gamma decision belongs to whoever puts these
            // pixels on a screen" -- gpu.rs). DeviceRGB would hand those numbers to the
            // panel's native gamut, oversaturating every colour on a P3 display.
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

extension Optional where Wrapped == String {
    /// Runs `body` with a C string for the wrapped value, or NULL for nil -- the shape
    /// every optional-string C parameter here wants.
    func withCStringOrNil<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let value): return value.withCString { body($0) }
        case .none: return body(nil)
        }
    }
}

/// What a press does, by AppKit's click count.
///
/// A static rule rather than a `switch` inside the delegate, for the same reason
/// `LastPaneOutcome`, `WorkStateRule`, `ChromeTransition` and `PanelNavigation` are: the
/// delegate's copy needs a live window, a live pty and a pointer, so it could never be
/// asserted, and this project has now shipped four separate defects that lived exactly
/// there. The fifth was selection existing on one host path and not the other.
enum SelectGesture {
    enum Kind: Equatable {
        /// Arm a drag from this cell, and drop whatever was highlighted.
        case arm
        /// Double-click.
        case word
        /// Triple-click and beyond. AppKit keeps counting past three within the interval,
        /// and a fourth click reading as "nothing" would make a fast hand lose its line.
        case line
    }

    static func decide(clicks: Int) -> Kind {
        switch clicks {
        case ..<2: return .arm
        case 2: return .word
        default: return .line
        }
    }

    /// Whether a drag may extend the current selection.
    ///
    /// Only a single click arms one. Without this a drag that began as a double-click would
    /// silently collapse the word back into a one-cell range the moment the pointer moved a
    /// pixel, which is the ordinary hand tremor after a double-click.
    static func extends(_ kind: Kind) -> Bool { kind == .arm }
}

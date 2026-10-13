// The app: a top tab strip over one terminal surface.
//
// Each session is its own TermisuHost -- pty, pump thread, renderer -- and the app blits
// whichever is active. Background sessions keep running and are polled at a low rate
// only to notice exits; their frames queue in the seqlock (the writer never blocks), so
// a switch shows the newest state immediately.

import AppKit
import CTermisuHost
import UserNotifications

/// What happens when the LAST pane closes. Policy, split out from `closePane` so a gate
/// can read it: the behaviour it decides is one an app run would have to be driven to
/// reach, and the wrong answer is the app disappearing.
///
/// The maintainer, 2026-08-25: "למה שסוגרים את הטאב האחרון שנשאר זה עושה eliminate לאפליקציה
/// וסוגר אותה לגמרי במקום להתחיל zsh חדש?" - and he is right about the gesture. cmd+W
/// says close this TAB. Answering it by quitting the application is the app deciding that
/// the operator meant cmd+Q, and the whole window goes with it.
///
/// So an EXPLICIT close of the last pane spawns a fresh shell in the same window, and a
/// CHILD THAT EXITED still terminates. The split is not a hedge, it is the only version
/// with a way out: `exit` and `logout` are the universal "I am done with this terminal"
/// gesture, and respawning there would make the app unquittable by the route most hands
/// reach for. Quitting stays available three ways -- cmd+Q, the red traffic light, and
/// typing `exit`.
enum LastPaneOutcome: Equatable {
    /// A fresh shell in the same window.
    case respawn
    /// The application quits.
    case terminate

    static func decide(childExited: Bool) -> LastPaneOutcome {
        childExited ? .terminate : .respawn
    }
}

final class HostAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let command: String?
    private let autoDirection: Bool
    /// The loaded settings handle; contributes the theme palette at every spawn. Owned
    /// for the app's lifetime (the borrowed strings read at launch depend on it).
    private let config: OpaquePointer?
    /// Logical font size from the config (or the default); scaled per spawn.
    private let baseFontSize: Float
    /// The configured lead font family, for metric queries that must match the
    /// renderer's own stack (zoom math with the wrong font drifts the grid).
    private let fontFamily: String?
    /// What could not be honoured in the config, shown once at launch -- a settings file
    /// that silently half-applies looks like a broken app, so the failure is loud.
    private let configError: String?
    /// Overrides the workflows directory the same way it overrides config.toml, so
    /// captures and taps never touch (or require) the real ~/.ruuah.
    private let configDir: String?
    /// Where the built panel document lives, when it is not in the app bundle. The bare
    /// CLI binary has no resource bundle, so the smoke and any tap pass `--web-dir`.
    private let webDir: String?
    private var window: NSWindow!

    // MARK: panes (P3)

    /// The band the split tree tiles inside. Pane surfaces are its subviews, so the chrome
    /// arithmetic keeps producing ONE rectangle and the split arithmetic subdivides it -
    /// two problems that stay separable, and two gates that stay separable with them.
    private var paneContainer: NSView!
    /// One live surface per visible pane, keyed by `Session.paneID`. Several exist at once,
    /// which is the whole feature: a single shared view is what made this a tab strip.
    private var paneViews: [Int: TerminalView] = [:]
    /// The resize handles, rebuilt on every layout pass. They are views rather than
    /// hit-tested rectangles so the cursor can change over them without a tracking area
    /// per pane.
    private var dividerViews: [SplitDividerHandle] = []
    /// The tabs, each with its own split tree. Sessions not in the current tab's tree belong
    /// to background tabs, which keep their tiling for when they come back.
    private var tabSet = TabSet()
    /// Which panes are on screen and how they are arranged: the current tab's tree. Read-only
    /// here; every change goes through `tabSet`, so the tab and the screen cannot disagree.
    private var tree: SplitTree { tabSet.currentTab?.tree ?? .leaf(-1) }
    private var focusedPaneID: Int { tabSet.currentTab?.focused ?? -1 }

    /// The focused pane's surface.
    ///
    /// Computed rather than stored so every existing call site keeps meaning "the surface
    /// the operator is looking at" without knowing panes are now plural. Nil only before
    /// the first session exists, which is why the window setup no longer touches it.
    private var view: TerminalView! { paneViews[focusedPaneID] }

    /// The tab island in the title band, and what it draws. See Tabs.swift.
    private let tabs = TabModel()
    private var tabsHost: TabIslandHost!
    /// The blur and fade where the pane meets the band. See TopFade.swift.
    private let topFade = TopFadeView(frame: .zero)
    /// Option 2 of the top blur: the history above row 0, blurred, behind the band. Its own
    /// switch beside the fade's, so all four combinations can be compared on the live window.
    /// `TERMISU_TOP_BLUR=0` starts it off for a scripted capture.
    private var topBlurOn = ProcessInfo.processInfo.environment["TERMISU_TOP_BLUR"] != "0"
    /// Panes whose top edge is the container's: only their strips have a band above them.
    /// A pane lower in a split would lay its strip over the pane above it.
    private var topPanes: Set<Int> = []
    /// Branch per directory, computed on miss and never invalidated within a run.
    ///
    /// `git rev-parse` costs a process, and `refreshChrome` is driven by title and progress
    /// events that a busy agent emits several times a second. Uncached, this would spawn git
    /// at that rate on the main thread. The stated cost of never invalidating: a branch
    /// switched underneath a running session shows stale until the session moves directory.
    private var branchCache: [String: String] = [:]
    private var timer: Timer?

    private var sessions: [Session] = []
    /// Derived from the focused pane, never stored. Two stores for "which session is in
    /// front" is how a strip highlights one pane while the keyboard talks to another.
    private var activeIndex: Int {
        sessions.firstIndex { $0.paneID == focusedPaneID } ?? -1
    }
    private var spawnCount = 0
    private var windowSized = false
    private var tick: UInt64 = 0
    /// Zoom multiplier over the configured base size (cmd+= / cmd+- / cmd+0).
    private var fontScale: Float = 1.0
    /// Background sessions are polled once per this many active ticks (~2 Hz at 60).
    private static let backgroundEvery: UInt64 = 30

    // MARK: web panels (S6)

    /// The open panel, or nil. At most one: panels are modal-feeling overlays, and two
    /// of them competing for Escape is a worse problem than any layout it would buy.
    private var webPanel: WebPanel?
    /// The repository the open panel is showing, and the file list it was given. The
    /// list is the ALLOWED SET for `requestDiff`: a path the host never advertised is
    /// refused rather than handed to git, so the panel cannot widen its own reach.
    private var panelRoot: String?
    private var panelFiles: [ChangedFile] = []
    /// Which panel `webPanel` is, so one toggle can switch between them.
    private var panelKind: PanelKind?
    /// The file panel's root: every path it sends is resolved under this and nowhere
    /// else (`FileAccess.resolve`).
    private var filesRoot: String?
    /// A root chosen for a file rather than for the session: a cmd+clicked path outside the
    /// session's repository opens under its own repository, or its own directory. Kept while
    /// the panel stays open so Refresh does not jump back to the session's root.
    private var filesRootOverride: String?
    /// The file a cmd+click asked for, posted once the panel has its root and first listing.
    private var pendingSelect: (path: String, line: Int?)?
    /// Directory listings and file reads run here, off the main thread, for the same
    /// reason git does.
    private let fileQueue = DispatchQueue(label: "termisu.files", qos: .userInitiated)
    /// git runs here, never on the main thread -- `status` on a large tree is tens of
    /// milliseconds and the terminal is blitting at 60 Hz on the other side of it.
    private let gitQueue = DispatchQueue(label: "termisu.git", qos: .userInitiated)

    init(
        command: String?, autoDirection: Bool, config: OpaquePointer?,
        baseFontSize: Float, configError: String?, configDir: String? = nil,
        webDir: String? = nil
    ) {
        self.command = command
        self.autoDirection = autoDirection
        self.config = config
        self.baseFontSize = baseFontSize
        self.configError = configError
        self.configDir = configDir
        self.webDir = webDir
        if let config, let family = termisu_config_font_family(config) {
            self.fontFamily = String(cString: family)
        } else {
            self.fontFamily = nil
        }
    }

    /// One report per run. A present that fails does so every frame, and 60 lines a second
    /// buries the message it is trying to deliver.
    private var presentReported = false

    /// Builds one pane's surface and binds it to its session.
    ///
    /// Every line here used to run ONCE, in `applicationDidFinishLaunching`, against the
    /// single shared view. It is a factory now because a pane is no longer a singleton, and
    /// the thing that made this worth extracting rather than copying is the binding: the
    /// POINTER handlers resolve to the pane they are over, not to the focused one.
    ///
    /// Keys are different and correctly so. AppKit delivers a key event to the first
    /// responder, and only the focused pane is ever first responder, so `activeSession` is
    /// already the right answer there. A wheel or a click is delivered to whatever view is
    /// under the pointer, so routing those through the focused session would scroll a pane
    /// the operator is not pointing at - which looks like the scroll wheel being broken.
    private func makePaneView(for session: Session) -> TerminalView {
        let pane = TerminalView(frame: .zero)
        pane.wantsLayer = true
        let id = session.paneID

        pane.onPresentResize = { [weak self] width, height in
            guard let self, let owner = self.session(for: id) else { return }
            owner.resizeLayer(width: Int(width), height: Int(height))
        }

        pane.layer?.backgroundColor = NSColor.black.cgColor
        // Below the content layer: the metal layer carries the frame, the content layer keeps
        // its sublayers (the ghost suggestion) and its geometry, and overlays stay on top.
        // Device and pixel format are deliberately NOT set here - the surface owns them, and a
        // layer configured with one device while the renderer draws on another is a black
        // window with no error anywhere.
        pane.presentLayer.isOpaque = true
        pane.presentLayer.contentsScale = window.backingScaleFactor
        // The drawable joins the Core Animation transaction it was presented in, so a pixel
        // scroll's new offset and the frame drawn for it reach the screen together, never a
        // frame apart (wgpu reads this off the layer at every acquire).
        pane.presentLayer.presentsWithTransaction = true
        pane.presentLayer.magnificationFilter = .nearest
        // A frame is NEVER scaled to fit its layer. The default gravity is `.resize`,
        // which stretches whatever was last drawn across the new bounds -- so during a
        // resize, before the pty has caught up, the terminal renders as soft, oversized
        // glyphs with the previous frame's edges smeared over the gap. Anchoring at the
        // top-left leaves a stale frame at its true pixel size with the background
        // showing past it, which is what every terminal does mid-drag and reads as
        // "not repainted yet" instead of "broken". (Operator-reported, 2026-08-02.)
        pane.presentLayer.contentsGravity = .topLeft
        pane.layer?.addSublayer(pane.contentLayer)
        // The content layer clips; inside it the grid (the metal layer), the lead rows on top
        // of it, and the caret over both, so pixel scrolling (M4) slides all of them with one
        // transform.
        pane.contentLayer.masksToBounds = true
        pane.contentLayer.addSublayer(pane.presentLayer)
        pane.leadLayer.magnificationFilter = .nearest
        pane.leadLayer.isHidden = true
        pane.contentLayer.addSublayer(pane.leadLayer)
        // The caret over the grid, where the grid's own caret used to be.
        pane.caretLayer.magnificationFilter = .nearest
        pane.caretLayer.isHidden = true
        pane.contentLayer.addSublayer(pane.caretLayer)
        session.handCaretToLayer()
        // Over the grid, because its overlap fades out over the sharp first rows.
        pane.layer?.addSublayer(pane.stripLayer)
        pane.layer?.addSublayer(pane.veilLayer)

        // Standalone CALayers implicitly ANIMATE property changes -- a 0.25s crossfade on
        // every `contents` swap. At a 60 Hz blit the overlapping fades read as typing at
        // five frames a second (found live, 2026-07-29). A terminal frame is a hard cut.
        let hardCut: [String: CAAction] = [
            "contents": NSNull(), "backgroundColor": NSNull(),
            "bounds": NSNull(), "position": NSNull(),
        ]
        pane.contentLayer.actions = hardCut.merging(["sublayerTransform": NSNull()]) { $1 }
        pane.leadLayer.actions = hardCut.merging(["hidden": NSNull()]) { $1 }
        let still = hardCut.merging(["hidden": NSNull(), "colors": NSNull(), "locations": NSNull()]) { $1 }
        pane.stripLayer.actions = still
        pane.veilLayer.actions = still
        pane.stripLayer.isHidden = true
        pane.veilLayer.isHidden = true
        pane.layer?.actions = hardCut

        // Typing and pasting snap the view to the live bottom first -- the standard
        // terminal policy, applied here because the C surface deliberately leaves it
        // to the embedder. A no-op when already at the bottom.
        pane.onKey = { [weak self] action, key, mods, consumed, text, unshifted in
            guard let session = self?.activeSession else { return false }
            // Typing snaps to the live bottom, the policy the C surface leaves to the
            // embedder -- presses only, so a held modifier's release doesn't snap.
            if action != 0 {
                session.scroll(Int32.min)
            }
            return session.key(
                action: action, key: key, mods: mods, consumedMods: consumed,
                text: text, unshiftedCodepoint: unshifted)
        }
        pane.onPaste = { [weak self] bytes in
            guard let session = self?.activeSession else { return }
            self?.paneViews[session.paneID]?.resetPixelScroll()
            session.scroll(Int32.min)
            session.paste(bytes)
        }
        // Pointer handlers: THIS pane's session, resolved by id.
        pane.onScroll = { [weak self] rows in self?.session(for: id)?.scroll(rows) }
        pane.onMouse = { [weak self] action, button, mods, x, y in
            self?.session(for: id)?
                .mouse(action: action, button: button, mods: mods, x: x, y: y) ?? false
        }
        pane.onWheel = { [weak self] x, y, ticks, mods in
            self?.session(for: id)?.wheel(x: x, y: y, ticks: ticks, mods: mods) ?? false
        }
        pane.onWheelViewport = { [weak self] mods in
            self?.session(for: id)?.wheelScrollsViewport(mods: mods) ?? false
        }
        pane.onLeadNeeded = { [weak self] in
            guard let self, let session = self.session(for: id) else { return }
            session.pollLead()
            self.refreshLead(of: session)
        }
        // A click anywhere in a pane focuses it BEFORE the press is forwarded, so the
        // first click into an unfocused pane is not swallowed by the focus change.
        pane.onFocusRequest = { [weak self] in self?.focus(paneID: id) }
        pane.onAcceptSuggestion = { [weak self] in
            guard let self, !self.ghostRemainder.isEmpty,
                let session = self.activeSession
            else { return false }
            // The paste path types the remainder; bracketed mode is its concern.
            session.paste(self.ghostRemainder)
            self.hideGhost()
            return true
        }
        // Geometry goes to every session: it is per-host state, and a background
        // session must not come to the front with a stale (or never-set) view size.
        pane.onMouseGeometry = { [weak self] width, height, inset in
            self?.session(for: id)?
                .mouseGeometry(width: width, height: height, inset: inset)
        }
        pane.onNewSession = { [weak self] in self?.newSession() }
        pane.onPalette = { [weak self] in self?.togglePalette() }
        pane.onSelectTab = { [weak self] number in self?.selectTab(number: number) }
        pane.onStepTab = { [weak self] step in self?.stepTab(by: step) }
        pane.onSplitRight = { [weak self] in self?.split(axis: .horizontal) }
        pane.onSplitDown = { [weak self] in self?.split(axis: .vertical) }
        pane.onFocusMove = { [weak self] axis, forward in
            self?.moveFocus(axis: axis, forward: forward)
        }
        if termisu_config_panels(config) {
            pane.onDiffPanel = { [weak self] in self?.toggleDiffPanel() }
            pane.onFilesPanel = { [weak self] in self?.toggleFilesPanel() }
        }
        pane.onCloseSession = { [weak self] in
            guard let self else { return }
            self.closePane(id)
        }
        pane.onBlockClick = { [weak self] block, event in
            self?.showBlockMenu(block, with: event)
        }
        pane.onCommandClick = { [weak self] point in self?.openLink(at: point) }
        pane.onLinkHover = { [weak self, weak pane] point in
            guard let self, let pane, let owner = self.session(for: id) else { return [] }
            return self.linkRects(at: point, in: pane, of: owner)
        }
        pane.onSelectPress = { [weak self] point, clicks in self?.beginSelection(point, clicks) }
        pane.onSelectDrag = { [weak self] point in self?.extendSelection(point) }
        pane.onSelectAll = { [weak self] in self?.selectAll() ?? false }
        pane.onCopySelection = { [weak self] in self?.copySelection() ?? false }
        pane.onZoomIn = { [weak self] in self?.zoom(by: 1.1) }
        pane.onZoomOut = { [weak self] in self?.zoom(by: 1 / 1.1) }
        pane.onZoomReset = { [weak self] in self?.zoom(to: 1.0) }
        return pane
    }

    private func session(for paneID: Int) -> Session? {
        sessions.first { $0.paneID == paneID }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        paneContainer = NSView(frame: .zero)
        paneContainer.autoresizesSubviews = false
        // The tab switch cross-fades on this layer, so it must have one of its own rather
        // than borrowing whatever AppKit happens to give the window.
        paneContainer.wantsLayer = true

        tabs.onSelect = { [weak self] index in self?.activate(tab: index) }
        tabs.onNew = { [weak self] in self?.showNewMenu() }
        tabs.onIdealWidthChange = { [weak self] in self?.layoutIsland(animated: true) }
        tabsHost = TabIslandHost(rootView: TabIsland(model: tabs))
        // Frames are set by hand, from the measured strip; nothing should size it otherwise.
        tabsHost.sizingOptions = []
        // The island lives IN the title bar, so the title bar's safe area must not apply to
        // it. With the default, SwiftUI pushed the chips down by the band's own 52pt and they
        // drew on the terminal's first row while the frame sat empty in the band. Seen live.
        tabsHost.safeAreaRegions = []
        tabsHost.clipsToBounds = true

        // Full-size content with a transparent title bar, and an EMPTY unified toolbar. The
        // toolbar has no items; it is there because it is what makes the title bar the 52pt
        // band of macOS 26 with the traffic lights centred in it, which is the band the tab
        // island lives in. The pane starts under it -- see `ChromeLayout`.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "termisu-vt host"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "termisu.band")
        window.toolbarStyle = .unified

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizesSubviews = true
        content.addSubview(paneContainer)
        // Over the pane, under the island. `TERMISU_TOP_FADE=0` starts with it off, so a
        // scripted capture can show both sides of the A/B without driving the palette.
        // Off by default since the blur's veil does its job; `TERMISU_TOP_FADE=1` starts it on.
        topFade.isHidden = ProcessInfo.processInfo.environment["TERMISU_TOP_FADE"] != "1"
        content.addSubview(topFade)
        content.addSubview(tabsHost)
        window.contentView = content
        layoutChrome()
        window.delegate = self
        window.center()
        // `TERMISU_BACKGROUND=1` shows the window without taking the keyboard, for scripted
        // captures: a dev build that activated on launch took the maintainer's typing (2026-10-02).
        let background = ProcessInfo.processInfo.environment["TERMISU_BACKGROUND"] == "1"
        if background { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }

        setupSuggestions()
        newSession()
        guard !sessions.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        // AFTER the first pane exists, not before: `view` is the focused pane's surface
        // now, and there is no surface until a session has one.
        attachGhost()
        window.makeFirstResponder(view)
        if !background { NSApp.activate(ignoringOtherApps: true) }

        // The live-tap hooks (SCAR-014). A panel and a workspace are GUI seams, and proving
        // them means seeing them in a real window. Opening from the environment is what
        // lets that be a scripted capture instead of synthesized keystrokes into whatever
        // the operator happens to be doing.
        if termisu_config_panels(config) {
            let open = ProcessInfo.processInfo.environment["TERMISU_PANEL_OPEN"]
            if open == "1" || open == "diff" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.toggleDiffPanel()
                }
            }
            if open == "files" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.toggleFilesPanel()
                }
            }
        }
        if let branch = ProcessInfo.processInfo.environment["TERMISU_WORKSPACE_TAP"],
            !branch.isEmpty
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let directory = self.activeDirectory(),
                    let root = Git.repositoryRoot(containing: directory)
                else { return }
                self.createWorkspace(root: root, branch: branch)
            }
        }
        // The cmd+hover mark has the same problem: `TERMISU_HOVER_TAP=x,y` (pane points,
        // top-left origin) marks what a cmd+click there would open, so a capture can show it.
        if let tap = ProcessInfo.processInfo.environment["TERMISU_HOVER_TAP"] {
            let parts = tap.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, let pane = self.view, let session = self.activeSession else { return }
                    let point = NSPoint(x: parts[0], y: pane.bounds.height - parts[1])
                    let rects = self.linkRects(at: point, in: pane, of: session)
                    FileHandle.standardError.write(
                        Data("hover: \(point) cell \(session.cellWidth)x\(session.cellHeight) -> \(rects)\n".utf8))
                    pane.pinnedPointer = point
                    pane.markLink(at: point)
                }
            }
        }
        // Splits have the same problem and the same answer: `TERMISU_SPLIT_TAP=right` or
        // `=down` opens a second pane so a capture can show a real tiling.
        if let where0 = ProcessInfo.processInfo.environment["TERMISU_SPLIT_TAP"],
            !where0.isEmpty
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.split(axis: where0 == "down" ? .vertical : .horizontal)
            }
        }

        // `TERMISU_SPLIT_DIM=0` starts with the unfocused wash off, for the other side of the A/B.
        if ProcessInfo.processInfo.environment["TERMISU_SPLIT_DIM"] == "0" { splitDim = false }

        // `TERMISU_PALETTE_TAP=1` opens the palette at 2.5s and closes it at 4s, so a capture
        // can show it arriving and leaving without a keystroke into the window.
        if ProcessInfo.processInfo.environment["TERMISU_PALETTE_TAP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.togglePalette() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.togglePalette() }
        }

        // `TERMISU_MOTION_SLOW=n` plays every Core Animation in the window n times slower. The
        // transitions last 0.11 to 0.16s, under two frames of a window capture; slowed, the
        // frames in between can be looked at. Capture only: it changes no timing constant.
        if let slow = ProcessInfo.processInfo.environment["TERMISU_MOTION_SLOW"].flatMap({ Float($0) }),
            slow > 0
        {
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.speed = 1 / slow
        }

        // `TERMISU_MOTION=0` starts with motion off, so a scripted capture can show both sides.
        if ProcessInfo.processInfo.environment["TERMISU_MOTION"] == "0" { tabs.motion = false }

        // Overflow needs tabs. `TERMISU_NEW_TABS=n` opens n more at launch, so a capture can
        // show a crowded strip. There is no wheel tap: a synthetic wheel posted to the system,
        // to this pid or straight to the strip's scroll view never moved it (2026-10-02), so
        // the wheel is proven by the conversion gate in --smoke-chrome and a real hand.
        if let extra = ProcessInfo.processInfo.environment["TERMISU_NEW_TABS"].flatMap({ Int($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                for _ in 0..<extra { self?.newSession() }
            }
        }
        // The tab island is SwiftUI under the title bar, and whether a click there reaches a
        // chip or is eaten by the title bar is a question no geometry gate answers.
        // `TERMISU_CLICK_TAP=x,y` (window points, top-left origin) sends one click through
        // `NSWindow.sendEvent`, the same hit-testing a real click takes, and logs which tab
        // is in front afterwards. `x,y;x,y` clicks again a second later, so a capture can go
        // to a tab and come back.
        if let tap = ProcessInfo.processInfo.environment["TERMISU_CLICK_TAP"] {
            let clicks = tap.split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }
            for (order, parts) in clicks.enumerated() where parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(order)) { [weak self] in
                    guard let self, let content = self.window.contentView else { return }
                    let point = NSPoint(x: parts[0], y: content.bounds.height - parts[1])
                    FileHandle.standardError.write(
                        Data("click: before tab \(self.tabSet.current) of \(self.tabSet.tabs.count)\n".utf8))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: self.window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                        {
                            self.window.sendEvent(event)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        FileHandle.standardError.write(
                            Data("click: after tab \(self.tabSet.current) panes \(self.tree.leaves) island \(self.tabsHost.frame)\n".utf8))
                    }
                }
            }
        }

        // `TERMISU_SLIDE_TAP=points,steps` plays one trackpad gesture into the focused pane at
        // 3s: began, `steps` moves 16ms apart adding up to `points` (positive climbs into
        // history), then the fingers lift with no momentum. `;` plays another a second later.
        // The events go straight to the pane, never through the system, so a capture can show
        // pixel scrolling (M4) without touching the operator's input; each step logs the shift.
        if let tap = ProcessInfo.processInfo.environment["TERMISU_SLIDE_TAP"] {
            let gestures = tap.split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }
            for (order, parts) in gestures.enumerated() where parts.count == 2 && parts[1] >= 1 {
                let steps = Int(parts[1])
                let step = parts[0] / Double(steps)
                // Phases as CGScrollPhase numbers: began 1, changed 2, ended 4.
                let phases = [(1, 0.0)] + Array(repeating: (2, step), count: steps) + [(4, 0.0)]
                // One timer per gesture, without tolerance: separate `asyncAfter` blocks are
                // coalesced into bursts, which is a different gesture from the one asked for.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(order) * 1.5) { [weak self] in
                    var index = 0
                    let timer = Timer(timeInterval: 0.016, repeats: true) { timer in
                        guard let self, index < phases.count else {
                            timer.invalidate()
                            return
                        }
                        let (phase, delta) = phases[index]
                        index += 1
                        guard let pane = self.paneViews[self.focusedPaneID],
                            let cg = CGEvent(
                                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0)
                        else { return }
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
                        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta)
                        guard let event = NSEvent(cgEvent: cg) else { return }
                        pane.scrollWheel(with: event)
                        let viewport = self.session(for: self.focusedPaneID)?.viewportOffset ?? -1
                        FileHandle.standardError.write(Data(
                            "slide: t \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) phase \(phase) delta \(event.scrollingDeltaY) shift \(pane.pixelShift) viewport \(viewport)\n".utf8))
                    }
                    timer.tolerance = 0
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
        }

        // For screenshots: `screencapture -l` takes this id. Written unbuffered, because a
        // scripted capture reads it while the app is still running.
        FileHandle.standardOutput.write(
            Data("TERMISU_HOST_WINDOW=\(window.windowNumber)\n".utf8))
        // The frame too, top-left origin, so scripted captures and synthetic-input
        // tests (SCAR-014 live taps) can aim without a window-server query.
        let screenHeight = window.screen?.frame.height ?? 0
        let frame = window.frame
        FileHandle.standardOutput.write(
            Data(
                "TERMISU_HOST_FRAME=\(Int(frame.origin.x)),\(Int(screenHeight - frame.origin.y - frame.height)),\(Int(frame.width)),\(Int(frame.height))\n"
                    .utf8))

        if let configError {
            FileHandle.standardError.write(Data("config: \(configError)\n".utf8))
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Settings could not be fully applied"
            alert.informativeText = "\(configError)\n\nDefaults are in effect for the parts that failed."
            alert.runModal()
        }

        // A mouse wheel over the tabs scrolls them sideways. A local monitor rather than an
        // override on the host view, because the wheel lands on the scroll view SwiftUI keeps
        // inside it, and a monitor is the one place that sees the event before routing.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, let tabsHost = self.tabsHost,
                let content = self.window.contentView,
                tabsHost.frame.contains(content.convert(event.locationInWindow, from: nil))
            else { return event }
            return TabWheel.sideways(event)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            self?.pollTick()
        }
    }

    /// The terminal pane and the title band -- recomputed on every window resize
    /// (manual frames; two views do not earn Auto Layout here).
    private func layoutChrome() {
        guard let content = window.contentView else { return }
        let layout = ChromeLayout.compute(content: content.bounds.size)
        paneContainer.frame = layout.pane
        paneContainer.autoresizingMask = []
        tilePanes()
        topFade.frame = TopFadeView.frame(pane: layout.pane)
        layoutIsland()
    }

    /// The island's frame: past the traffic lights, as wide as its tabs, and never past the
    /// right margin. Also run whenever the island's own width changes (a tab opened, a title
    /// grew), because only this side knows how much room the band has.
    /// `animated` only when the island's own width changed (a tab arrived or left), never on a
    /// window resize: a frame easing behind a live drag reads as lag.
    private func layoutIsland(animated: Bool = false) {
        guard let content = window.contentView, let tabsHost else { return }
        let band = ChromeLayout.compute(content: content.bounds.size).band
        // Read off the real zoom button rather than assumed: its place depends on the title
        // bar style, and full screen hides it entirely.
        var leading = TabMetrics.margin
        if let zoom = window.standardWindowButton(.zoomButton), let bar = zoom.superview,
            !zoom.isHidden
        {
            leading = content.convert(zoom.frame, from: bar).maxX + TabMetrics.margin
        }
        let frame = TabMetrics.islandFrame(
            band: band, leading: leading, ideal: tabs.idealWidth)
        guard tabsHost.frame != frame else { return }
        // The chips' share of the island: everything but the `+` and the gap before it.
        let settled = max(0, frame.width - TabMetrics.spacing - TabMetrics.chipHeight)
        if abs(tabs.settledRoom - settled) > 0.5 { tabs.settledRoom = settled }
        // The chips spring into place inside the island; the island's own edge has to travel
        // with them, or the `+` jumps to its new place before the tab it makes room for exists.
        if animated, tabs.motion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.response
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                tabsHost.animator().frame = frame
            }
        } else {
            tabsHost.frame = frame
        }
    }

    /// Puts every visible pane where the split tree says it goes, and resizes its pty to
    /// match.
    ///
    /// Manual frames throughout: each pane's grid is derived from ITS OWN rect, so the
    /// frame set here is what resizes that pty. An autoresizing mask would let AppKit move
    /// a pane behind that derivation's back and the child would be told a size it does not
    /// have.
    private func tilePanes() {
        guard paneContainer != nil else { return }
        let rect = paneContainer.bounds
        let panes = SplitLayout.tile(tree, in: rect)
        topPanes = SplitLayout.topPanes(panes, in: rect)

        for pane in panes {
            guard let surface = paneViews[pane.id] else { continue }
            surface.frame = pane.rect
            surface.autoresizingMask = []
            if let session = session(for: pane.id) { showStrip(of: session) }
            if surface.superview !== paneContainer { paneContainer.addSubview(surface) }
            if let session = session(for: pane.id) { fit(session, to: pane.rect) }
        }
        // A surface for a pane no longer in the tree is a background tab's: off screen,
        // still alive, still polled at the background rate.
        let visible = Set(panes.map(\.id))
        for (id, surface) in paneViews where !visible.contains(id) {
            surface.removeFromSuperview()
        }

        // Handles are rebuilt rather than repositioned. There is one per branch and the
        // tree changes shape, so a pool would have to be reconciled against it - and a
        // stale handle drags a divider that is no longer there.
        for handle in dividerViews { handle.removeFromSuperview() }
        dividerViews = SplitLayout.dividers(tree, in: rect).map { divider in
            let handle = SplitDividerHandle(
                divider: divider, line: SplitLook.line(ground: focusedGround))
            handle.onDrag = { [weak self] point in
                guard let self else { return }
                self.tabSet.retile(self.tree.adjusting(
                    dividerAt: divider.index,
                    to: SplitLayout.fraction(for: divider, at: point)))
                self.tilePanes()
            }
            paneContainer.addSubview(handle)
            return handle
        }
        refreshSplitFocus()
    }

    /// In a split, every pane but the focused one recedes under a wash of its own ground,
    /// Ghostty's way of saying which pane the keyboard is talking to. Without some mark a
    /// split is two terminals and the operator finds out by typing into the wrong one.
    private func refreshSplitFocus() {
        // Panes ON SCREEN, not pane views. A tab in the background keeps its view, so
        // counting views marked a lone pane as soon as a second tab existed. The maintainer saw it on
        // every new tab, 2026-10-02.
        let split = tree.leaves.count > 1
        // Only the caret the keyboard is talking to blinks, and only in the key window, as
        // in every macOS text view: a blink in a window you are not using pulls the eye.
        let blinks = Motion.on(tabs.motion) && (window?.isKeyWindow == true || caretBlinkTap)
        for (id, surface) in paneViews {
            let ground = session(for: id)?.background.flatMap { NSColor(cgColor: $0) }
                ?? ChromeColor.of(ChromeColor.ink)
            surface.setDimmed(split && splitDim && id != focusedPaneID, ground: ground)
            surface.setCaretBlink(blinks && id == focusedPaneID)
            surface.pixelScrolling = Motion.on(tabs.motion)
        }
    }

    /// The focused session's ground, which the window band already wears; the hairline is
    /// drawn from it.
    private var focusedGround: NSColor {
        window.backgroundColor ?? ChromeColor.of(ChromeColor.ink)
    }

    /// `TERMISU_CARET_BLINK=1` blinks the caret even when the window is not key, so a capture
    /// can show the blink without taking focus from whatever the operator is typing into.
    private let caretBlinkTap = ProcessInfo.processInfo.environment["TERMISU_CARET_BLINK"] == "1"

    /// The A/B for the unfocused wash: Ghostty's look, or panes left at full strength.
    private var splitDim = true

    private func fit(_ session: Session, to rect: NSRect) {
        // A session that has not drawn yet knows no cell size of its own. A fresh split pane
        // is exactly that when the layout runs, and skipping it left its child at the old
        // pane's whole grid for good: `stty size` said 80 columns in a 39-column pane, so
        // right-aligned Hebrew fell off the pane (2026-10-02). Every pane shares the font,
        // so it borrows the size of one that has drawn.
        guard windowSized,
            let metrics = session.cellWidth != 0
                ? session : sessions.first(where: { $0.cellWidth != 0 })
        else { return }
        let (cols, rows) = SplitLayout.grid(
            for: rect, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
            scale: window.backingScaleFactor, padding: TerminalView.padding)
        session.resize(cols: cols, rows: rows)
    }

    // MARK: splits (P3)

    /// Splits the focused pane, putting a fresh session beside or below it.
    private func split(axis: SplitAxis) {
        guard let current = activeSession else { return }
        spawnCount += 1
        let word = command?.split(separator: " ").first.map(String.init) ?? "zsh"
        let title = word == "sh" ? "session \(spawnCount)" : "\(word) \(spawnCount)"
        // The new pane inherits the focused pane's directory, which is what every terminal
        // does and the only behaviour that makes a split useful mid-task.
        let scale = Float(window.backingScaleFactor)
        let (cols, rows) = (current.cols, current.rows)
        guard let session = Session(
            command: command, cols: cols, rows: rows,
            fontSize: baseFontSize * scale * fontScale,
            autoDirection: autoDirection, config: config, title: title,
            cwd: directory(of: current))
        else {
            warn("Could not split", "The pty or the renderer refused a new pane.")
            return
        }
        guard tabSet.split(current.paneID, with: session.paneID, axis: axis) else {
            // The focused pane was not in the tree, which means the tree and the focus
            // disagree. Closing the new session is the honest response: leaking a pty to
            // paper over an inconsistency is how one becomes several.
            session.close()
            return
        }
        sessions.append(session)
        paneViews[session.paneID] = makePaneView(for: session)
        layoutChrome()
        attachPresent(session)
        refreshChrome()
        window.makeFirstResponder(paneViews[session.paneID])
    }

    /// Moves focus to the pane in a direction, or does nothing when there is none. It
    /// deliberately does NOT wrap: focus arriving on the far side of the window is
    /// disorienting, and every terminal that does it gets complained about.
    private func moveFocus(axis: SplitAxis, forward: Bool) {
        let panes = SplitLayout.tile(tree, in: paneContainer.bounds)
        guard let next = SplitLayout.neighbor(
            of: focusedPaneID, among: panes, axis: axis, forward: forward)
        else { return }
        focus(paneID: next)
    }

    private func focus(paneID: Int) {
        guard paneID != focusedPaneID, paneViews[paneID] != nil else { return }
        tabSet.focus(paneID)
        if let session = session(for: paneID) {
            session.markSeen()
            window.title = session.title
            applyBackground(of: session)
        }
        hideGhost()
        attachGhost()
        lastInputLine = ""
        refreshSplitFocus()
        refreshChrome()
        window.makeFirstResponder(paneViews[paneID])
    }

    /// Closes one pane. Any pane with a sibling collapses out of the tree and hands its
    /// space over; the LAST one goes to `LastPaneOutcome`, which is where the policy is
    /// written and where a gate can read it.
    ///
    /// `childExited` is passed by the two poll paths that detect a dead pty, and defaults
    /// to false so that every operator-driven close is a tab close. A new call site that
    /// forgets the flag therefore gets the SAFE behaviour: a stray shell, not a lost
    /// window.
    private func closePane(_ paneID: Int, childExited: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.paneID == paneID }) else { return }
        let wasCurrent = tabSet.index(containing: paneID) == tabSet.current
        sessions[index].close()
        sessions.remove(at: index)
        paneViews[paneID]?.removeFromSuperview()
        paneViews.removeValue(forKey: paneID)

        if case .closedTab = tabSet.remove(paneID) {
            guard !tabSet.tabs.isEmpty else {
                switch LastPaneOutcome.decide(childExited: childExited) {
                case .respawn:
                    // `newSession` ends in `activate`, which rebuilds the tree, the
                    // surface and the chrome, so there is nothing left for the tail of
                    // this function to do.
                    newSession()
                    // A spawn CAN fail -- no pty, no shell -- and an empty window with no
                    // way to get a pane back is worse than the quit this replaced.
                    if sessions.isEmpty { NSApp.terminate(nil) }
                case .terminate:
                    NSApp.terminate(nil)
                }
                return
            }
            // The tab on screen closed: the one that slid into its place comes forward,
            // with its own tiling. A background tab closing changes only the strip.
            if wasCurrent {
                activate(tab: tabSet.current, force: true)
                return
            }
        }
        layoutChrome()
        refreshChrome()
        if let surface = paneViews[focusedPaneID] { window.makeFirstResponder(surface) }
    }

    private var activeSession: Session? {
        activeIndex >= 0 && activeIndex < sessions.count ? sessions[activeIndex] : nil
    }

    // MARK: session lifecycle

    /// Opens a session as a new TAB: a single pane replacing the current tiling. Splitting
    /// is `split(axis:)`, which keeps what is on screen and divides it.
    private func newSession() {
        spawnCount += 1
        let word = command?.split(separator: " ").first.map(String.init) ?? "zsh"
        // The bundled splash command is an implementation detail nobody wants as a label.
        let title = word == "sh" ? "session \(spawnCount)" : "\(word) \(spawnCount)"
        let (cols, rows) = gridForPane()
        let scale = Float(window.backingScaleFactor)
        guard
            let session = Session(
                command: command, cols: cols, rows: rows,
                fontSize: baseFontSize * scale * fontScale,
                autoDirection: autoDirection, config: config, title: title)
        else { return }
        openTab(session)
    }

    // MARK: agents

    /// Opens a tab running `agent`, in the active session's directory.
    ///
    /// The directory is the point. "Launch Claude" nearly always means "launch it HERE", and
    /// an agent that opens at HOME while the operator is three levels into a repository has to
    /// be told where it is before it can do anything. `activeDirectory` is the live OSC 7
    /// report, so it follows the shell rather than where the pane started; nil (no shell
    /// integration, or nothing reported yet) falls back to HOME, which is the archive's own
    /// default and a defensible place to be.
    private func newAgentSession(_ agent: Agent) {
        spawnCount += 1
        let (cols, rows) = gridForPane()
        let scale = Float(window.backingScaleFactor)
        let outcome = Session.agent(
            agent, cols: cols, rows: rows, fontSize: baseFontSize * scale * fontScale,
            autoDirection: autoDirection, config: config, cwd: activeDirectory())
        switch outcome {
        case .success(let session):
            report("agent \(agent.id) at \(agent.path ?? "?") in \(activeDirectory() ?? "~")")
            openTab(session)
        case .failure(let why):
            // Named, never silent. A launch that fails without saying why is the shape that
            // sends an operator hunting through their own PATH for our bug.
            report("agent \(agent.id) did not launch: \(why.summary)")
            warn("Could not launch \(agent.name)", why.summary)
        }
    }

    /// One palette row per agent: installed ones launch, the rest hand over their install
    /// command.
    ///
    /// The uninstalled ones are LISTED rather than hidden, and they are not dead rows -- they
    /// copy the install line. Hiding them makes the feature invisible to anyone who has not
    /// already installed an agent, which is everyone the first time.
    private func agentPaletteItems() -> [PaletteItem] {
        let agents = Agent.all()
        let here = activeDirectory().map { ($0 as NSString).lastPathComponent }
        return agents.sorted { $0.isInstalled && !$1.isInstalled }.map { agent in
            if agent.isInstalled {
                return PaletteItem(
                    title: "Agent: \(agent.name)",
                    subtitle: here.map { "a new tab in \($0)" } ?? "a new tab",
                    workflowIndex: nil,
                    action: { [weak self] in self?.newAgentSession(agent) })
            }
            return PaletteItem(
                title: "Agent: \(agent.name)", subtitle: "not installed \u{2022} \(agent.installHint)",
                workflowIndex: nil,
                action: { [weak self] in self?.clip(agent.installHint) })
        }
    }

    // MARK: the island's plus

    /// The `+` menu. Everything that opens a pane, in one visible place.
    ///
    /// A MENU rather than straight to the form, because four of the five things this
    /// offers need no form at all and going through one to reach them would be worse than
    /// the palette it is replacing. The saved hosts are listed here for the same reason
    /// the `+` exists: a feature reachable only from a fuzzy search box is invisible to
    /// anyone who has not been told it is there.
    private func showNewMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Session", action: #selector(menuNewSession), keyEquivalent: "")
        menu.addItem(
            withTitle: "New Workspace...", action: #selector(menuNewWorkspace), keyEquivalent: "")
        menu.addItem(.separator())

        let hosts = SSHConfig.hosts()
        if hosts.isEmpty {
            let empty = NSMenuItem(title: "No hosts in ~/.ssh/config", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for host in hosts.prefix(HostAppDelegate.sshMenuLimit) {
            let item = NSMenuItem(
                title: host.alias, action: #selector(menuSSHHost(_:)), keyEquivalent: "")
            item.target = self
            // The subtitle the palette shows, as a tooltip: a menu row is one line, and
            // two aliases pointing at the same box are otherwise indistinguishable here.
            item.toolTip = host.summary
            item.representedObject = host.alias
            menu.addItem(item)
        }
        if hosts.count > HostAppDelegate.sshMenuLimit {
            // Stated, not silently truncated. A menu that quietly drops hosts reads as a
            // config that lost them.
            let more = NSMenuItem(
                title: "\(hosts.count - HostAppDelegate.sshMenuLimit) more in cmd+K",
                action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "SSH Connection...", action: #selector(menuSSHConnect), keyEquivalent: "")
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = self
        }
        // Under the pointer, which is on the `+` that was just clicked. SwiftUI does not
        // hand out the button's frame, and the pointer is where the eye already is.
        guard let content = window.contentView else { return }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: point.y - 8), in: content)
    }

    /// How many saved hosts the menu shows before deferring to the palette. A menu longer
    /// than the screen scrolls, and a scrolling menu is worse than a search box.
    private static let sshMenuLimit = 12

    @objc private func menuNewSession() { newSession() }

    @objc private func menuNewWorkspace() {
        // After the menu has torn itself down. A modal run from inside a dismissing menu
        // swallows its own keys, which is the same trap the palette hit.
        DispatchQueue.main.async { [weak self] in self?.newWorkspace() }
    }

    @objc private func menuSSHHost(_ item: NSMenuItem) {
        guard let alias = item.representedObject as? String else { return }
        openSSH(argv: ["ssh", alias], title: alias)
    }

    @objc private func menuSSHConnect() {
        DispatchQueue.main.async { [weak self] in self?.promptSSHConnection() }
    }

    /// The connection form, and what happens to what it collects.
    ///
    /// On save the ALIAS is dialled, not the assembled argv, so the pane runs the same
    /// thing a later `ssh <alias>` from any shell would run. If the two ever disagree, the
    /// config is wrong and the operator finds out immediately rather than the next time
    /// they use scp.
    private func promptSSHConnection() {
        switch SSHConnect.prompt(over: window) {
        case .cancelled:
            return
        case .connect(let connection):
            openSSH(
                argv: connection.arguments,
                title: connection.alias.isEmpty ? connection.hostName : connection.alias)
        case .saveAndConnect(let connection):
            switch SSHConfig.append(connection) {
            case .failure(let why):
                warn("Nothing was saved", why.summary)
            case .success(let alias):
                report("ssh: appended Host \(alias) to \(SSHConfig.defaultPath)")
                openSSH(argv: ["ssh", alias], title: alias)
            }
        }
    }

    // MARK: ssh hosts

    /// One palette row per concrete host in `~/.ssh/config`.
    ///
    /// Read at every palette open rather than cached: a host added to the config while the
    /// app is running should appear on the next cmd+K, and a cache here would be the copy
    /// that goes stale. The file is small and the palette is not a hot path.
    ///
    /// Nothing is offered when the file is absent, which is the normal state of a machine
    /// that has never used ssh. An empty section is better than a section of one dead row
    /// explaining what an ssh config is.
    private func sshPaletteItems() -> [PaletteItem] {
        SSHConfig.hosts().map { host in
            PaletteItem(
                title: "SSH: \(host.alias)", subtitle: host.summary, workflowIndex: nil,
                action: { [weak self] in self?.newSSHSession(host) })
        }
    }

    /// Opens a pane running `ssh <alias>`.
    ///
    /// The ALIAS is spawned, never the resolved hostname, user or port. Rebuilding an
    /// `ssh -p 2222 user@host` line out of parsed fields would quietly drop every other
    /// directive the operator wrote - ProxyJump, IdentityFile, ForwardAgent - and it would
    /// drop them silently, so the connection either fails for no visible reason or, worse,
    /// succeeds over a path they did not intend.
    ///
    /// The alias is also not shell-quoted here because it is not going through a shell:
    /// `command` is the child's own line and the concrete-pattern filter has already
    /// refused anything with a glob character in it.
    private func newSSHSession(_ host: SSHHost) {
        openSSH(argv: ["ssh", host.alias], title: host.alias)
    }

    /// The ONE place an ssh child is spawned, and the one place its words are quoted.
    ///
    /// It takes argv, never a command line, because the host hands the string to
    /// `/bin/sh -c` and a caller that assembles its own line is one interpolation away from
    /// running an alias's semicolon. Every path in - a saved host, the form's Connect, the
    /// form's Save & Connect - comes through here so there is exactly one place that can
    /// be wrong about it.
    private func openSSH(argv: [String], title: String) {
        spawnCount += 1
        let (cols, rows) = gridForPane()
        let scale = Float(window.backingScaleFactor)
        guard
            let session = Session(
                command: SSHConnection.shellQuoted(argv), cols: cols, rows: rows,
                fontSize: baseFontSize * scale * fontScale,
                autoDirection: autoDirection, config: config, title: title)
        else {
            warn("Could not open a pane for \(title)", "The pty or the renderer refused.")
            return
        }
        openTab(session)
    }

    // MARK: workspaces (S5)

    /// Spawns a session placed in `directory`, labelled with its workspace.
    private func newSession(in directory: String, workspace: String) {
        spawnCount += 1
        let (cols, rows) = gridForPane()
        let scale = Float(window.backingScaleFactor)
        guard
            let session = Session(
                command: command, cols: cols, rows: rows,
                fontSize: baseFontSize * scale * fontScale,
                autoDirection: autoDirection, config: config, title: workspace,
                cwd: directory, workspace: workspace)
        else { return }
        openTab(session)
    }

    /// Asks for a name and creates a worktree plus a session in it.
    ///
    /// Modal on purpose. This is the app's only repository-mutating action, and a
    /// confirmation the operator cannot miss is the price of that (`Worktrees.swift`
    /// header). The prompt is also where the target path is shown, so nobody learns
    /// where their worktree went by finding it later.
    private func newWorkspace() {
        guard let directory = activeDirectory(),
            let root = Git.repositoryRoot(containing: directory)
        else {
            report("new workspace: the active session is not in a git repository")
            warn(
                "Not a git repository",
                "A workspace is a git worktree, so this session has to be inside a "
                    + "repository first.")
            return
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "branch name"
        let alert = NSAlert()
        alert.messageText = "New workspace"
        alert.informativeText =
            "Creates a git worktree beside \((root as NSString).lastPathComponent) and opens a "
            + "session in it. An existing branch is checked out; a new name creates the branch."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        createWorkspace(root: root, branch: field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// The half of `newWorkspace` past the prompt: validate, create, open a session.
    ///
    /// Split out so the live-tap hook drives the REAL path (worktree creation, the cwd
    /// spawn, the pill label) rather than a copy of it. The modal above is the only part
    /// the tap does not cover, and it is named as untested in the PR rather than implied.
    private func createWorkspace(root: String, branch: String) {
        if let invalid = Worktrees.validate(branch: branch) {
            warn("Cannot create that workspace", invalid.description)
            return
        }

        gitQueue.async { [weak self] in
            let outcome = Worktrees.add(root: root, branch: branch)
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let worktree):
                    self.report("workspace \(branch) at \(worktree.path)")
                    self.newSession(in: worktree.path, workspace: branch)
                case .failure(let error):
                    self.report("new workspace failed: \(error.description)")
                    self.warn("Could not create the workspace", error.description)
                }
            }
        }
    }

    /// Closes the active session and offers to remove its worktree.
    ///
    /// Two separate acts, and the session closes either way: a workspace with
    /// uncommitted work must still be closable without deleting it. git's refusal to
    /// remove a dirty tree is shown verbatim rather than forced past.
    private func closeWorkspace() {
        guard let session = activeSession, let workspace = session.workspace else {
            report("close workspace: the active session is not a workspace")
            return
        }
        guard let directory = activeDirectory(),
            let root = Git.repositoryRoot(containing: directory),
            case .success(let trees) = Worktrees.list(containing: directory),
            let worktree = trees.first(where: { $0.branch == workspace })
        else {
            report("close workspace: could not resolve the worktree for \(workspace)")
            closeSession(index: activeIndex)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close workspace \"\(workspace)\"?"
        alert.informativeText =
            "The session closes either way. Removing the worktree deletes \(worktree.path); "
            + "git refuses if it has uncommitted changes, and nothing here overrides that."
        alert.addButton(withTitle: "Close session only")
        alert.addButton(withTitle: "Close and remove worktree")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        closeSession(index: activeIndex)
        guard choice == .alertSecondButtonReturn else { return }

        gitQueue.async { [weak self] in
            let outcome = Worktrees.remove(root: root, worktree: worktree)
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = outcome {
                    self.report("worktree remove refused: \(error.description)")
                    self.warn("The worktree was kept", error.description)
                } else {
                    self.report("removed worktree \(worktree.path)")
                }
            }
        }
    }

    private func warn(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Index-addressed close, kept for the strip and the palette, which both think in
    /// positions. It DELEGATES rather than duplicating: one place removes a session, so a
    /// close can never leave a pane view bound to a dead pty or a tree holding an id that
    /// no longer resolves.
    private func closeSession(index: Int) {
        guard index >= 0 && index < sessions.count else { return }
        closePane(sessions[index].paneID)
    }

    /// Brings a tab to the front with its own tiling, and the keyboard on the pane it last
    /// had. `force` redoes the work when the index did not change but the tab under it did
    /// (the tab on screen closed and its neighbour slid into the same index).
    private func activate(tab index: Int, force: Bool = false) {
        guard let target = tabSet.tabs.indices.contains(index) ? tabSet.tabs[index] : nil,
            let session = session(for: target.focused)
        else { return }
        let panes = target.tree.leaves.compactMap { self.session(for: $0) }
        for pane in panes where paneViews[pane.paneID] == nil {
            paneViews[pane.paneID] = makePaneView(for: pane)
        }
        // A short cross-fade between the outgoing pane and the incoming one. Core Animation
        // snapshots the container now and fades to whatever it holds at the end of this pass,
        // so the swap below, the blit included, lands inside the fade and input never waits.
        if Motion.on(tabs.motion) && (index != tabSet.current || force) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.crossfade
            fade.timingFunction = Motion.landing
            paneContainer.layer?.add(fade, forKey: "termisu.crossfade")
        }
        tabSet.select(index)
        layoutChrome()
        session.markSeen()
        window.title = session.title
        refreshChrome()
        // Every pane of the tab, not only the focused one: a split coming back from the
        // background shows all of its panes at once.
        for pane in panes {
            attachPresent(pane)
            blit(pane)
            applyBackground(of: pane)
        }
        // Mouse geometry is per-host state; a session activated (or just spawned)
        // after the last layout pass has never seen the view's size.
        view.pushMouseGeometry()
        // The ghost and its input tracking belong to the outgoing session's grid.
        hideGhost()
        attachGhost()
        lastInputLine = ""
        window.makeFirstResponder(view)
    }

    /// The margin around the grid wears the terminal's own background, so a future
    /// theme colors it without any app-side change.
    private func applyBackground(of session: Session) {
        guard let background = session.background,
            let surface = paneViews[session.paneID]
        else { return }
        // The session's OWN surface. Painting the focused pane with a background sampled
        // from a different session is how two panes running different themes end up
        // wearing each other's margins.
        surface.layer?.backgroundColor = background
        surface.setVeilGround(NSColor(cgColor: background) ?? ChromeColor.of(ChromeColor.ink))

        // THE CHROME WEARS IT TOO, but only for the FOCUSED session. The maintainer, 2026-08-25:
        // "צריך שזה ירגיש חלק מהטרמינל ולא חתיכה של Sidebar שפשוט הדבקנו".
        //
        // Two surfaces were giving him three different darks in one window. The 28pt band
        // holding the traffic lights was `window.backgroundColor`, which nobody had set,
        // so it was AppKit's default window grey - measurably lighter than the terminal
        // under it, and the single loudest seam. The dock was an absolute #0A0A0A, close
        // to the terminal's #0D0D0D and not equal to it, which is worse than either being
        // obviously different or being the same.
        //
        // Both took the session's own background. The dock is gone since 2026-10-02; the
        // band that holds the tab island is this same window background, so the island's
        // glass sits on the terminal's own colour.
        //
        // Focused only, and deliberately: with a split running two themes, the window band
        // can only wear one of them, and the one the keyboard is talking to is the answer
        // that is never surprising.
        guard session.paneID == focusedPaneID else { return }
        let colour = NSColor(cgColor: background) ?? ChromeColor.of(ChromeColor.ink)
        window.backgroundColor = colour
        for handle in dividerViews { handle.setLine(SplitLook.line(ground: colour)) }
        topFade.ground = colour
    }

    /// Puts one session's newest frame on its own pane.
    ///
    /// The host draws the frame on the GPU during the poll and leaves `pixels` null, so the
    /// frame never crosses the bus; the work here is a present call on that pane's own
    /// swapchain. There is no image fallback: the CGImage path was removed on 2026-10-02 once
    /// presenting measured at half its main-thread time, and drawing some other way when a
    /// present fails would hide the failure behind a working-looking window.
    @discardableResult
    private func blit(_ session: Session) -> Bool {
        guard paneViews[session.paneID] != nil else { return false }
        var mark = CACurrentMediaTime()
        func lap(_ name: String) {
            guard frameStats else { return }
            let now = CACurrentMediaTime()
            phaseTimes[name, default: []].append((now - mark) * 1000)
            mark = now
        }
        // Polled whether or not the pane presents: the poll also notices the child exiting.
        session.poll()
        lap("poll")
        guard session.presenting else { return false }
        let ok = session.present()
        lap("present")
        if !ok, !presentReported {
            presentReported = true
            FileHandle.standardError.write(Data("TERMISU_PRESENT=failed\n".utf8))
        }
        refreshLead(of: session)
        lap("lead")
        refreshStrip(of: session)
        lap("strip")
        refreshCaret(of: session)
        lap("caret")
        return ok
    }


    /// After the frame and before the strip: rows that landed come off the pixel offset in the
    /// same transaction as the grid image, and the strip is laid out at the offset that results.
    private func refreshLead(of session: Session) {
        guard let surface = paneViews[session.paneID] else { return }
        if surface.needsLead { session.pollLead() }
        surface.drewGrid(
            viewport: session.viewportOffset, lead: session.leadImage, rows: session.leadRows,
            above: session.leadAbove, leadViewport: session.leadViewport)
    }

    /// After the frame, like the strip: the caret is read from the frame just polled.
    private func refreshCaret(of session: Session) {
        guard session.pollCaret(), let surface = paneViews[session.paneID] else { return }
        surface.showCaret(
            session.caretVisible ? session.caretImage : nil,
            column: session.caretColumn, row: session.caretRow,
            cell: session.caretPixels, glide: Motion.on(tabs.motion))
    }

    /// After the frame, never before: the strip's overlap is drawn from the frame just polled.
    private func refreshStrip(of session: Session) {
        guard topBlurOn, topPanes.contains(session.paneID) else { return }
        let radius = UInt32((TopVeil.blur * window.backingScaleFactor).rounded())
        if session.pollStrip(radius: radius) { showStrip(of: session) }
    }

    /// Puts a session's strip above its pane, or hides it: switched off, not a top pane, or on
    /// the alternate screen, where there is no history to show.
    private func showStrip(of session: Session) {
        guard let surface = paneViews[session.paneID] else { return }
        let shown = topBlurOn && topPanes.contains(session.paneID)
        surface.showStrip(shown ? session.stripImage : nil, overlap: session.stripOverlap)
    }

    /// Attaches a session's renderer to ITS OWN pane's metal layer.
    ///
    /// The single-view host could only ever have one owner, because one layer is one
    /// swapchain and two renderers presenting into the same drawable is a race. With a
    /// layer per pane that constraint dissolves: each session owns its own, permanently,
    /// and nothing is detached on a focus change.
    private func attachPresent(_ session: Session) {
        guard let surface = paneViews[session.paneID] else { return }
        // Size the layer BEFORE attaching. An unsized CAMetalLayer reports a zero drawable
        // which the swapchain clamps to 1x1 - an attach that succeeds and then shows
        // nothing.
        surface.layoutSubtreeIfNeeded()
        let size = surface.presentLayer.drawableSize
        let ok = session.attachLayer(
            surface.presentLayer, width: Int(size.width), height: Int(size.height))
        if !ok {
            let report = "TERMISU_PRESENT_ATTACH=failed "
                + "drawable=\(Int(size.width))x\(Int(size.height))\n"
            FileHandle.standardError.write(Data(report.utf8))
            return
        }
        session.resizeLayer(width: Int(size.width), height: Int(size.height))
    }

    private func refreshChrome() {
        let items = tabSet.tabs.compactMap { tab -> TabItem? in
            guard let focused = session(for: tab.focused) else { return nil }
            let states = tab.tree.leaves.compactMap { session(for: $0)?.workState }
            return tabItem(for: focused, tab: tab.id, state: WorkStateRule.loudest(states))
        }
        tabs.update(items: items, active: tabSet.current)
    }

    /// One session's tab. The title falls back to the session title so an ordinary shell is
    /// not a blank chip; the detail is allowed to be empty, because a session with no shell
    /// integration reports no directory and inventing one would be worse than showing none.
    private func tabItem(for session: Session, tab: Int, state: Session.WorkState) -> TabItem {
        let directory = directory(of: session)
        var parts: [String] = []
        if let directory, let branch = branch(in: directory) { parts.append(branch) }
        if let directory { parts.append(abbreviate(directory)) }
        return TabItem(
            id: tab,
            title: session.workspace ?? session.title,
            detail: parts.joined(separator: " · "),
            state: state)
    }

    /// `$HOME/x` renders as `~/x`. Purely cosmetic, and it is here rather than in the view
    /// because the view must not know what a home directory is.
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The branch checked out in `directory`, or nil when it is not a work tree.
    ///
    /// Cached forever within a run; see `branchCache`. A detached HEAD answers `HEAD`,
    /// which is git's own word for it and is left as-is rather than translated.
    private func branch(in directory: String) -> String? {
        if let cached = branchCache[directory] { return cached.isEmpty ? nil : cached }
        let result = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        let name =
            result.status == 0
            ? result.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // The empty string is cached too, so a non-repository directory costs one process
        // rather than one per refresh. This is the whole point of the cache.
        branchCache[directory] = name
        return name.isEmpty ? nil : name
    }

    // MARK: polling

    /// `TERMISU_FRAME_STATS=1` logs main-thread time per tick and per blit phase every two
    /// seconds. Measurement only.
    private let frameStats = ProcessInfo.processInfo.environment["TERMISU_FRAME_STATS"] == "1"
    private var blitTimes: [Double] = []
    private var tickTimes: [Double] = []
    private var phaseTimes: [String: [Double]] = [:]
    private var statsSince = CACurrentMediaTime()

    private func pollTick() {
        guard frameStats else { return pollTickBody() }
        let start = CACurrentMediaTime()
        pollTickBody()
        let now = CACurrentMediaTime()
        tickTimes.append((now - start) * 1000)
        if now - statsSince >= 2 {
            func line(_ name: String, _ values: [Double]) -> String {
                let sorted = values.sorted()
                guard !sorted.isEmpty else { return "\(name) n=0" }
                let at = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
                return String(format: "%@ n=%d p50=%.2f p95=%.2f max=%.2f sum=%.0f",
                              name, sorted.count, at(0.5), at(0.95), sorted.last!, sorted.reduce(0, +))
            }
            let phases = phaseTimes.keys.sorted().map { line($0, phaseTimes[$0]!) }.joined(separator: " | ")
            FileHandle.standardError.write(Data(
                "stats: \(line("tick", tickTimes)) | \(line("blit", blitTimes)) | \(phases)\n".utf8))
            phaseTimes.removeAll()
            tickTimes.removeAll()
            blitTimes.removeAll()
            statsSince = now
        }
    }

    private func pollTickBody() {
        tick += 1
        // EVERY visible pane, not just the focused one. A split whose unfocused halves are
        // polled at the background rate is a split where the other panes update twice a
        // second, and the operator reads that as the terminal being slow rather than as a
        // polling policy. They are all on screen, so they are all live.
        let visible = tree.leaves
        for paneID in visible {
            guard let session = session(for: paneID) else { continue }
            let focused = paneID == focusedPaneID
            let blitStart = CACurrentMediaTime()
            let blitted = blit(session)
            if frameStats { blitTimes.append((CACurrentMediaTime() - blitStart) * 1000) }
            if blitted { applyBackground(of: session) }
            // Outside the new-frame branch deliberately: a child that prints once and goes
            // quiet never yields another image, and a view left at cellHeight 0 has no
            // wheel handling at all (found by the SGR-mouse live tap). updateGutter's own
            // change guard makes the every-tick call free.
            paneViews[paneID]?.updateGutter(
                blocks: computeBlocks(session.rowClasses, cursorRow: session.cursorRow),
                cellHeightDevice: session.cellHeight)
            // A hover mark is over text the child may have just moved; ask again so it
            // follows the text or clears, rather than underlining whatever scrolled under it.
            if let pane = paneViews[paneID], pane.isMarkingLink {
                pane.refreshLinkMark(command: NSEvent.modifierFlags.contains(.command))
            }
            // Events BEFORE the suggestion pass: the 133;C event and the cursor's move to
            // the fresh prompt land in the SAME polled frame, so recording must read the
            // previous tick's input line before captureAndSuggest overwrites it (the tap
            // caught exactly this race as an empty history file).
            apply(events: session.drainEvents(), to: session)
            // The ghost belongs to the pane being typed into. Running it for every visible
            // pane would have three suggestions competing for one `ghostRemainder`.
            if focused { captureAndSuggest(session) }
            if !windowSized && session.cellWidth != 0 {
                windowSized = true
                sizeWindowToGrid(session)
            }
        }
        // Collected first, closed after: closePane mutates the tree, and mutating it while
        // iterating its own leaves is how one exit takes a neighbour with it.
        let finished = visible.filter { session(for: $0)?.exited == true }
        for paneID in finished { closePane(paneID, childExited: true) }
        if !finished.isEmpty { return }

        if tick % HostAppDelegate.backgroundEvery == 0 {
            reapBackgroundSessions()
        }
    }

    /// What the child asked its terminal to do. Policy lives here, not in the core:
    /// OSC 52 writes the system clipboard (write-only -- reads are refused core-side),
    /// notifications post through the user-notification center when we are a real
    /// bundle (the bare CLI has no identity to post as), BEL washes the pane that rang.
    private func apply(events: [Session.HostEvent], to session: Session) {
        var chromeChanged = false
        for event in events {
            switch event {
            case .title(let text):
                session.applyTitle(text)
                chromeChanged = true
            case .progress(let state):
                session.apply(progress: state)
                chromeChanged = true
            case .clipboard(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .notify(let title, let body):
                postNotification(title: title.isEmpty ? "Termisu" : title, body: body)
            case .bell:
                // SEEN, not heard. `NSSound.beep()` was here until 2026-08-26 and it is gone
                // rather than joined: the system chime says something needs you and says
                // nothing about WHICH pane, which is useless the moment more than one agent
                // is running. The wash names the pane, and the attention bar on the dock rail
                // outlives it and survives the dock being collapsed.
                paneViews[session.paneID]?.flashBell()
                session.ring()
                refreshChrome()
            case .commandStart:
                // Execution began: the input line seen on the LAST tick is the final
                // typed command. Reading the row now would race the shell's redraw.
                recordExecutedCommand(of: session)
            case .pwd:
                // The session already stored it (`pwdRaw`). The consumer the old comment
                // here anticipated now exists: a tab's tooltip carries the directory, so a
                // `cd` must repaint the chrome. Without this, a tab keeps showing the
                // directory the session STARTED in, which is wrong in the one way that is
                // hardest to notice -- it is a real path, just not the current one.
                chromeChanged = true
            }
        }
        if chromeChanged {
            refreshChrome()
            if session === activeSession {
                window.title = session.title
            }
        }
    }

    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("notify: \(title): \(body)\n".utf8))
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Low-rate sweep over the sessions not on screen: keep their images warm and drop
    /// the ones whose child exited. Walked backwards so removal keeps indices honest.
    private func reapBackgroundSessions() {
        // Every VISIBLE pane is polled at full rate by pollTick; this is for the ones off
        // screen. Skipping only the focused one would poll a split's other halves twice
        // here and 60 times a second there.
        let visible = Set(tree.leaves)
        for index in stride(from: sessions.count - 1, through: 0, by: -1)
        where !visible.contains(sessions[index].paneID) {
            let session = sessions[index]
            session.poll()
            // Background sessions still ring, notify and set the clipboard -- the
            // program asked; being off-screen is not a veto.
            apply(events: session.drainEvents(), to: session)
            if session.exited {
                // Through closePane so the tree, the surfaces and the tabs all learn
                // about it. A bare `sessions.remove` here would leave a pane view bound
                // to a dead session and the tiling would keep a rectangle for it.
                closePane(session.paneID, childExited: true)
            }
        }
        refreshChrome()
    }

    // MARK: geometry

    /// The grid that fits the terminal pane right now, or the spawn default before any
    /// cell metrics exist.
    /// The grid a NEW session should spawn with: the focused pane's rect if there is one,
    /// otherwise the whole container.
    ///
    /// Routed through `SplitLayout.grid` rather than repeating the arithmetic, because the
    /// version that lived here read one shared view's bounds - correct while there was one
    /// pane and wrong for every pane after the first.
    private func gridForPane() -> (UInt16, UInt16) {
        guard let metrics = sessions.first(where: { $0.cellWidth != 0 }) else {
            return (80, 24)
        }
        let panes = SplitLayout.tile(tree, in: paneContainer.bounds)
        let rect = panes.first { $0.id == focusedPaneID }?.rect ?? paneContainer.bounds
        return SplitLayout.grid(
            for: rect, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
            scale: window.backingScaleFactor, padding: TerminalView.padding)
    }



    /// Sizes the window once so the terminal pane is exactly the spawn grid, in points.
    private func sizeWindowToGrid(_ session: Session) {
        let scale = window.backingScaleFactor
        let size = NSSize(
            width: CGFloat(session.cellWidth * Int(session.cols)) / scale
                + TerminalView.padding * 2,
            height: CGFloat(session.cellHeight * Int(session.rows)) / scale
                + TerminalView.padding * 2 + ChromeLayout.topInset
        )
        window.setContentSize(size)
        window.contentResizeIncrements = NSSize(
            width: CGFloat(session.cellWidth) / scale,
            height: CGFloat(session.cellHeight) / scale)
        layoutChrome()
    }

    /// cmd+click: resolve the cell under the point and open its OSC 8 link, if any.
    // MARK: selection

    /// The cell a press landed on, held so a drag knows where it started.
    ///
    /// The ANCHOR is the host's to remember and not the engine's: a drag is a press, a stream
    /// of moves and a release, and only the view knows which press started this one.
    private var selectionAnchor: (col: UInt16, row: UInt16)?

    /// A press: one click arms a drag, two selects a word, three selects a line.
    ///
    /// A single click also CLEARS whatever was highlighted, which is what makes a stale
    /// selection impossible to leave on screen: every press either replaces it or drops it.
    private func beginSelection(_ point: NSPoint, _ clicks: Int) {
        guard let session = activeSession, let cell = cell(at: point) else { return }
        let kind = SelectGesture.decide(clicks: clicks)
        selectionAnchor = SelectGesture.extends(kind) ? cell : nil
        switch kind {
        case .arm: session.clearSelection()
        case .word: session.selectWord(col: cell.col, row: cell.row)
        case .line: session.selectLine(col: cell.col, row: cell.row)
        }
        redrawActive()
    }

    /// A move with the button held. Only extends when a single click armed it, so a drag that
    /// began as a double-click does not silently turn the word back into a one-cell range.
    private func extendSelection(_ point: NSPoint) {
        guard let session = activeSession, let anchor = selectionAnchor,
            let cell = cell(at: point)
        else { return }
        session.selectTo(anchor: anchor, col: cell.col, row: cell.row)
        redrawActive()
    }

    private func selectAll() -> Bool {
        guard let session = activeSession else { return false }
        selectionAnchor = nil
        let found = session.selectAll()
        redrawActive()
        return found
    }

    /// cmd+C. `false` hands the chord back so it reaches the child as `^C`.
    ///
    /// Conditional on purpose: a terminal where cmd+C stopped interrupting a runaway command
    /// would be worse than one that could not copy at all.
    private func copySelection() -> Bool {
        guard let session = activeSession, let text = session.selectionText(), !text.isEmpty
        else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// A selection changes no terminal state, so nothing else would repaint it.
    ///
    /// The engine already resets its drawn generation when the highlight moves, which is what
    /// makes the next poll a full-frame draw; this only makes sure a poll happens now rather
    /// than whenever the child next writes. Without it a highlight appears one keystroke late,
    /// which reads as the mouse not working at all.
    private func redrawActive() {
        guard let session = activeSession else { return }
        blit(session)
    }

    /// A view point to the cell under it, for the ACTIVE session.
    ///
    /// One conversion, because there are now two callers and a selection landing one row off
    /// from where the link opens is the kind of defect nobody reports as a bug -- it reads as
    /// clumsiness. `nil` means the point is in the padding, outside the grid, or the session
    /// has no metrics yet.
    private func cell(at point: NSPoint) -> (col: UInt16, row: UInt16)? {
        guard let session = activeSession, session.cellWidth > 0, session.cellHeight > 0 else {
            return nil
        }
        let scale = window.backingScaleFactor
        let x = (point.x - TerminalView.padding) * scale
        // AppKit grows upward; grid rows grow downward from the top padding edge.
        let yTop = (view.bounds.height - point.y - TerminalView.padding) * scale
        guard x >= 0, yTop >= 0 else { return nil }
        return (
            UInt16(clamping: Int(x) / session.cellWidth),
            UInt16(clamping: Int(yTop) / session.cellHeight)
        )
    }

    /// What a cmd+click at `point` would open, as rects in `pane`, for the hover mark. The
    /// cell math of `cell(at:)`, but for the pane under the pointer, which with splits need
    /// not be the focused one.
    private func linkRects(at point: NSPoint, in pane: TerminalView, of session: Session) -> [NSRect] {
        guard session.cellWidth > 0, session.cellHeight > 0 else { return [] }
        let scale = window.backingScaleFactor
        let x = (point.x - TerminalView.padding) * scale
        let yTop = (pane.bounds.height - point.y - TerminalView.padding) * scale
        guard x >= 0, yTop >= 0 else { return [] }
        let col = UInt16(clamping: Int(x) / session.cellWidth)
        let row = UInt16(clamping: Int(yTop) / session.cellHeight)
        let cellWidth = CGFloat(session.cellWidth) / scale
        let cellHeight = CGFloat(session.cellHeight) / scale
        return session.linkSpanAt(col: col, row: row).map { run in
            NSRect(
                x: TerminalView.padding + CGFloat(run.start) * cellWidth,
                y: pane.bounds.height - TerminalView.padding - CGFloat(Int(run.row) + 1) * cellHeight,
                width: CGFloat(run.end - run.start) * cellWidth, height: cellHeight)
        }
    }

    private func openLink(at point: NSPoint) {
        // Every exit is traced, the early ones included. These two returned silently, so a
        // cmd+click that died here printed nothing at all and read as a click that never
        // arrived (2026-09-29, the P2 live tap).
        guard let session = activeSession else {
            FileHandle.standardError.write(Data("link: click at \(point) -> no active session\n".utf8))
            return
        }
        guard let (col, row) = cell(at: point) else {
            FileHandle.standardError.write(
                Data("link: click at \(point) -> no cell (cell \(session.cellWidth)x\(session.cellHeight), view \(view.bounds.size))\n".utf8))
            return
        }
        let uri = session.linkAt(col: col, row: row)
        // Permanent seam trace (SCAR-014): one line per cmd+click, so "nothing opened"
        // is always attributable to the event path, the cell math, or the lookup --
        // never a guess. Terminal apps live and die on their stderr being honest.
        FileHandle.standardError.write(
            Data("link: cell (\(col),\(row)) -> \(uri ?? "none")\n".utf8))
        // A web link opens as before. A file:// link falls through to the path lookup
        // below, which resolves it the same way as a path printed as text.
        if let uri, !uri.hasPrefix("file:"), let url = URL(string: uri) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let target = session.pathAt(col: col, row: row) else {
            FileHandle.standardError.write(Data("path: cell (\(col),\(row)) -> none\n".utf8))
            return
        }
        FileHandle.standardError.write(
            Data("path: cell (\(col),\(row)) -> \(target.path):\(target.line ?? 0)\n".utf8))
        if view.onFilesPanel != nil {
            showFile(target.path, line: target.line)
        } else {
            // Panels off: reveal, never open. Opening with the default app would run a
            // script or launch an .app someone printed (the maintainer's call, 2026-09-29).
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
        }
    }

    // MARK: zoom

    private func zoom(by factor: Float) { zoom(to: fontScale * factor) }

    /// The window keeps its pixel size; the grid that fits it moves with the metrics.
    /// Every session zooms together, so switching never changes the glyph size. Metrics
    /// for the NEW size come from the C query -- no session knows them until its next
    /// frame, which is too late to compute the grid.
    private func zoom(to scale: Float) {
        let clamped = min(max(scale, 0.5), 4.0)
        let device = window.backingScaleFactor
        let size = baseFontSize * Float(device) * clamped
        var cellW: UInt32 = 0
        var cellH: UInt32 = 0
        let metricsResult = fontFamily.withCStringOrNil { familyPointer in
            termisu_host_cell_metrics(size, familyPointer, &cellW, &cellH)
        }
        guard metricsResult == TERMISU_HOST_SUCCESS,
            cellW > 0, cellH > 0
        else { return }
        fontScale = clamped
        let inner = view.bounds.insetBy(dx: TerminalView.padding, dy: TerminalView.padding)
        let cols = UInt16(max(2, Int(inner.width * device) / Int(cellW)))
        let rows = UInt16(max(2, Int(inner.height * device) / Int(cellH)))
        for session in sessions {
            session.setFontSize(size, cols: cols, rows: rows)
        }
        window.contentResizeIncrements = NSSize(
            width: CGFloat(cellW) / device, height: CGFloat(cellH) / device)
    }

    /// Re-lays the chrome on every resize step.
    ///
    /// REGRESSION FIXED HERE (found by the operator, 2026-08-02, the same day S5.5
    /// shipped): the chrome used to be laid out ONCE and kept correct during a resize by
    /// autoresizing masks. S5.5 removed those masks -- correctly, because `.width` on the
    /// pane stretches it past its computed frame -- and did not put anything back
    /// in their place, so the views simply kept their old frames while the
    /// window moved around them. The masks were half of a mechanism and only half was
    /// replaced.
    ///
    /// Fires continuously through a live resize, which is what the frames need. The pty
    /// deliberately does NOT follow at this rate; that stays at end-of-resize below.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshSplitFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        refreshSplitFocus()
    }

    func windowDidResize(_ notification: Notification) {
        layoutChrome()
        // A drag is throttled to its end (below) because resizing the pty per step spams
        // SIGWINCH at the child. Everything else -- zoom, full screen, tiling, an
        // accessibility client setting the size -- produces no live-resize session at
        // all, so `windowDidEndLiveResize` never fires and the pty would keep the old
        // grid indefinitely. Found by resizing through the accessibility API while
        // verifying the fix above, which is exactly the case that does not fire.
        if !view.inLiveResize {
            refitAll()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // Every session, not just the active one: a background session that missed the
        // resize repaints at the old geometry the moment it is activated.
        refitAll()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        for session in sessions {
            session.close()
        }
        sessions.removeAll()
    }

    // MARK: blocks (S2)

    /// The clicked block's actions. The menu is built per click -- blocks move as the
    /// grid scrolls, so caching one would act on stale rows.
    // MARK: autosuggestions (S4)

    /// The command history handle, app-global. Loaded once; appends persist as they
    /// happen, so a crash costs at most the last command.
    private var historyStore: OpaquePointer?
    private let ghost = CATextLayer()
    /// The un-typed remainder of the current suggestion, ready for the paste path.
    private var ghostRemainder: [UInt8] = []
    /// The cursor row's input text as of the last tick, per session identity: the
    /// OSC 133;C event says WHEN a command executed, and this is WHAT it was -- read
    /// a tick earlier, because by event time the shell may already be redrawing.
    private var lastInputLine = ""

    private func setupSuggestions() {
        if let configDir {
            let path = (configDir as NSString).appendingPathComponent("history")
            _ = path.withCString { pointer in termisu_history_load(pointer, &historyStore) }
        } else {
            _ = termisu_history_load(nil, &historyStore)
        }
        ghost.actions = [
            "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "hidden": NSNull(), "string": NSNull(),
        ]
        ghost.foregroundColor = NSColor(white: 1, alpha: 0.35).cgColor
        ghost.isHidden = true
        // NOT attached here. This runs before the first pane exists, so there is no
        // surface to attach to yet - and there is more than one surface afterwards. The
        // ghost belongs to whichever pane is being typed into, so it FOLLOWS focus.
        //
        // Attaching it here crashed the app on launch, every time, with
        // "Unexpectedly found nil while implicitly unwrapping" - caught by running the
        // build rather than by any gate, because the gates stop below AppKit.
    }

    /// Moves the ghost suggestion layer onto the focused pane.
    ///
    /// A CALayer has exactly one superlayer, so this is a move and not a copy: adding it
    /// to a second pane silently removes it from the first. That is the behaviour wanted -
    /// there is one suggestion and it belongs where the typing is.
    private func attachGhost() {
        guard let surface = view else { return }
        guard ghost.superlayer !== surface.contentLayer else { return }
        ghost.removeFromSuperlayer()
        surface.contentLayer.addSublayer(ghost)
    }

    /// The typed text on the caret's row -- input-marked cells only, so the prompt
    /// itself never leaks in. Single-row deliberately: a wrapped command is a named
    /// v1 boundary, and joining a whole prompt RUN would merge adjacent commands
    /// (the cd-then-cd case measured in the tap).
    private func currentInputLine(_ session: Session) -> String {
        session.rowText(UInt16(session.cursorRow), semantic: UInt8(TERMISU_ROW_INPUT))
            .trimmingCharacters(in: .whitespaces)
    }

    /// The event half: OSC 133;C fired, so the last tick's input line IS the command.
    private func recordExecutedCommand(of session: Session) {
        guard session === activeSession, !lastInputLine.isEmpty else { return }
        session.recordCommand(historyStore, command: lastInputLine)
        lastInputLine = ""
    }

    /// Per tick: remember what is typed (for the C event) and refresh the ghost.
    /// Everything rides the OSC 133 rails -- no shell integration means no input
    /// marks, no history, no suggestions: the S2 dependency the backlog names.
    private func captureAndSuggest(_ session: Session) {
        let input = currentInputLine(session)
        lastInputLine = input
        updateGhost(session, input: input)
    }

    private func updateGhost(_ session: Session, input: String) {
        // Only at the live bottom, with a visible caret parked at the END of the
        // typed line -- a ghost mid-line would suggest an edit we cannot make.
        //
        // AT OR PAST the end, not exactly at it. `termisu_host_row_text` ends with
        // `trim_end_matches(' ')`, so spaces the operator actually typed are
        // invisible here: typing `echo ` puts the caret at column 7 against a
        // reported length of 6 and the old equality hid the ghost. Measured by
        // live tap 2026-07-31 -- `echo a` suggested, `echo ` did not, which made
        // the trailing space the single most common way to see nothing, since a
        // space is what you type before an argument.
        let rowText = session.rowText(
            UInt16(session.cursorRow), semantic: UInt8(TERMISU_TEXT_ALL))
        guard session.viewportOffset == 0, session.cursorVisible,
            session.cellWidth > 0, !input.isEmpty,
            session.cursorCol >= rowText.count
        else { return hideGhost() }

        // Keyed by the directory the session last reported (OSC 7): a command run HERE
        // outranks a newer one run elsewhere, and the host does the decoding.
        guard let suggestion = session.suggestion(historyStore, for: input) else {
            return hideGhost()
        }
        var remainder = String(suggestion.dropFirst(input.count))
        // Those same invisible spaces have to come off the FRONT of the remainder,
        // or the ghost redraws a space the caret is already sitting past and the
        // line reads `echo  alpha-here`. Bounded by how many the caret implies, so
        // a suggestion whose own next character is a space is not eaten.
        var typedSpaces = session.cursorCol - rowText.count
        while typedSpaces > 0, remainder.first == " " {
            remainder.removeFirst()
            typedSpaces -= 1
        }
        guard !remainder.isEmpty else { return hideGhost() }

        ghostRemainder = Array(remainder.utf8)
        let scale = window.backingScaleFactor
        let cellWidth = CGFloat(session.cellWidth) / scale
        let cellHeight = CGFloat(session.cellHeight) / scale
        let fontSize = CGFloat(baseFontSize * fontScale)
        ghost.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        ghost.fontSize = fontSize
        ghost.contentsScale = scale
        ghost.string = remainder
        ghost.frame = CGRect(
            x: CGFloat(session.cursorCol) * cellWidth,
            y: view.contentLayer.bounds.height - CGFloat(session.cursorRow + 1) * cellHeight,
            width: CGFloat(remainder.count) * cellWidth + cellWidth,
            height: cellHeight)
        ghost.isHidden = false
    }

    private func hideGhost() {
        ghost.isHidden = true
        ghostRemainder = []
    }

    // MARK: command palette (S3)

    private var palette: PaletteView?

    /// cmd+K toggles. Items are rebuilt and workflows reloaded at every open, so
    /// session changes and template file edits show up without a restart.
    private func togglePalette() {
        if palette != nil {
            dismissPalette()
            return
        }
        let workflows = Workflows(
            dir: configDir.map { ($0 as NSString).appendingPathComponent("workflows") })
        var items: [PaletteItem] = [
            PaletteItem(
                title: "New Session", subtitle: "cmd+T", workflowIndex: nil,
                action: { [weak self] in self?.newSession() }),
            PaletteItem(
                title: "Close Session", subtitle: "cmd+W", workflowIndex: nil,
                action: { [weak self] in
                    guard let self, self.activeIndex >= 0 else { return }
                    self.closeSession(index: self.activeIndex)
                }),
        ]
        // The A/B switch for the top fade. Not persisted: it exists to compare the two on the
        // live window, and the chosen one becomes the only one.
        items.append(
            PaletteItem(
                title: topFade.isHidden ? "Top Fade: On" : "Top Fade: Off",
                subtitle: "compare the band edge with and without the blur fade",
                workflowIndex: nil,
                action: { [weak self] in
                    guard let self else { return }
                    self.topFade.isHidden.toggle()
                }))
        items.append(
            PaletteItem(
                title: splitDim ? "Split Dim: Off" : "Split Dim: On",
                subtitle: "Ghostty's wash over the panes the keyboard is not in",
                workflowIndex: nil,
                action: { [weak self] in
                    guard let self else { return }
                    self.splitDim.toggle()
                    self.refreshSplitFocus()
                }))
        // The A/B for the motion slices: every animation the chrome has, on or off at once.
        items.append(
            PaletteItem(
                title: tabs.motion ? "Motion: Off" : "Motion: On",
                subtitle: "tabs that arrive and leave, a busy dot that breathes, a caret that glides and blinks",
                workflowIndex: nil,
                action: { [weak self] in
                    self?.tabs.motion.toggle()
                    self?.refreshSplitFocus()
                }))
        items.append(
            PaletteItem(
                title: topBlurOn ? "Top Blur: Off" : "Top Blur: On",
                subtitle: "the history above the first row, blurred behind the tab band",
                workflowIndex: nil,
                action: { [weak self] in
                    guard let self else { return }
                    self.topBlurOn.toggle()
                    for session in self.sessions { self.showStrip(of: session) }
                }))
        // Above workspaces: launching an agent is the thing this terminal exists for, and a
        // palette is read from the top.
        items.append(contentsOf: agentPaletteItems())
        items.append(contentsOf: sshPaletteItems())
        items.append(
            PaletteItem(
                title: "New Workspace", subtitle: "a git worktree and a session in it",
                workflowIndex: nil,
                // After the palette has torn itself down: both of these open a modal,
                // and a modal run from inside the dismissing view swallows its own keys.
                action: { [weak self] in
                    DispatchQueue.main.async { self?.newWorkspace() }
                }))
        if activeSession?.workspace != nil {
            items.append(
                PaletteItem(
                    title: "Close Workspace", subtitle: "session, and optionally the worktree",
                    workflowIndex: nil,
                    action: { [weak self] in
                        DispatchQueue.main.async { self?.closeWorkspace() }
                    }))
        }
        if view.onDiffPanel != nil {
            items.append(
                PaletteItem(
                    title: "Review Changes", subtitle: "cmd+shift+D", workflowIndex: nil,
                    action: { [weak self] in
                        // After the palette has dismissed itself, or the panel would be
                        // added under a view that is about to be torn down.
                        DispatchQueue.main.async { self?.toggleDiffPanel() }
                    }))
        }
        if view.onFilesPanel != nil {
            items.append(
                PaletteItem(
                    title: "Browse Files", subtitle: "cmd+shift+E", workflowIndex: nil,
                    action: { [weak self] in
                        DispatchQueue.main.async { self?.toggleFilesPanel() }
                    }))
        }
        for (index, session) in sessions.enumerated() where index != activeIndex {
            items.append(
                PaletteItem(
                    title: "Switch: \(session.title)", subtitle: "session \(index + 1)",
                    workflowIndex: nil,
                    action: { [weak self] in self?.show(pane: session.paneID) }))
        }
        if let session = activeSession,
            let block = computeBlocks(session.rowClasses, cursorRow: session.cursorRow).last
        {
            let command = session.command(of: block)
            if !command.isEmpty {
                items.append(
                    PaletteItem(
                        title: "Copy Last Command", subtitle: command, workflowIndex: nil,
                        action: { [weak self] in
                            guard let self, let session = self.activeSession else { return }
                            self.clip(session.command(of: block))
                        }))
                items.append(
                    PaletteItem(
                        title: "Copy Last Output", subtitle: "the block's output text",
                        workflowIndex: nil,
                        action: { [weak self] in
                            guard let self, let session = self.activeSession else { return }
                            self.clip(session.output(of: block))
                        }))
            }
        }
        items.append(
            PaletteItem(
                title: "Scroll to Top", subtitle: "cmd+Home", workflowIndex: nil,
                action: { [weak self] in self?.activeSession?.scroll(Int32.max / 2) }))
        items.append(
            PaletteItem(
                title: "Scroll to Bottom", subtitle: "cmd+End", workflowIndex: nil,
                action: { [weak self] in self?.activeSession?.scroll(Int32.min) }))
        for index in 0..<workflows.count {
            let description = workflows.field(index, TERMISU_WORKFLOW_DESCRIPTION)
            let command = workflows.field(index, TERMISU_WORKFLOW_COMMAND)
            items.append(
                PaletteItem(
                    title: workflows.field(index, TERMISU_WORKFLOW_NAME),
                    subtitle: description.isEmpty ? command : description,
                    workflowIndex: index, action: nil))
        }
        let errors = workflows.errors
        if !errors.isEmpty {
            items.append(
                PaletteItem(
                    title: "\u{26A0} Workflow files with errors",
                    subtitle: errors.replacingOccurrences(of: "\n", with: " \u{2022} "),
                    workflowIndex: nil,
                    action: {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Some workflow files were skipped"
                        alert.informativeText = errors
                        alert.runModal()
                    }))
        }

        let paletteView = PaletteView(items: items, workflows: workflows)
        paletteView.onDismiss = { [weak self] in self?.dismissPalette() }
        paletteView.onCommand = { [weak self] bytes in
            guard let session = self?.activeSession else { return }
            session.scroll(Int32.min)
            session.paste(bytes)
        }
        paletteView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paletteView)
        NSLayoutConstraint.activate([
            paletteView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            paletteView.topAnchor.constraint(equalTo: view.topAnchor, constant: 64),
            paletteView.widthAnchor.constraint(equalToConstant: 560),
        ])
        palette = paletteView
        paletteView.focus()
        // It settles down into place, from a hair smaller and a few points higher. Laid out
        // first, so the scale is about its real centre.
        if Motion.on(tabs.motion), let layer = paletteView.layer {
            view.layoutSubtreeIfNeeded()
            Motion.arrive(layer)
        }
    }

    /// Lets go of the palette at once (focus goes straight back to the pane, so the next key
    /// reaches the shell), then lets it fade out on its own time.
    private func dismissPalette() {
        guard let palette else { return }
        self.palette = nil
        window.makeFirstResponder(view)
        if Motion.on(tabs.motion) {
            Motion.leave(palette)
        } else {
            palette.removeFromSuperview()
        }
    }

    // MARK: diff review panel (S6)

    /// The active session's working directory, decoded.
    private func activeDirectory() -> String? {
        guard let session = activeSession else { return nil }
        return directory(of: session)
    }

    /// Any session's working directory, decoded.
    ///
    /// Decoded by the RUST side (`termisu_cwd_path`), never here: the percent-decode and
    /// the `file://host` strip already exist in one place, and a second copy in Swift
    /// is exactly the drift the OSC 7 slice was written to avoid.
    ///
    /// Generalised from `activeDirectory` for the tabs, which need the directory of
    /// every session rather than one. The decoding is untouched; only the session it
    /// reads from became a parameter.
    private func directory(of session: Session) -> String? {
        guard !session.pwdRaw.isEmpty else { return nil }
        var length = 0
        let raw = session.pwdRaw
        let sized = raw.withUnsafeBufferPointer { pointer in
            termisu_cwd_path(pointer.baseAddress, raw.count, nil, 0, &length)
        }
        guard sized == TERMISU_HOST_SUCCESS, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let copied = raw.withUnsafeBufferPointer { pointer in
            buffer.withUnsafeMutableBufferPointer { out in
                termisu_cwd_path(pointer.baseAddress, raw.count, out.baseAddress, length, &length)
            }
        }
        guard copied == TERMISU_HOST_SUCCESS else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// The panel wears the terminal's own background; the rest is the app's accent, the
    /// same indigo the gutter's hot bar uses. Only the background is live today -- the
    /// frame reports it, and nothing reports a foreground yet.
    private func panelTheme() -> PanelTheme {
        var background = "#16151b"
        if let color = activeSession?.background,
            let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB)
        {
            background = String(
                format: "#%02x%02x%02x", Int((srgb.redComponent * 255).rounded()),
                Int((srgb.greenComponent * 255).rounded()),
                Int((srgb.blueComponent * 255).rounded()))
        }
        return PanelTheme(
            background: background, foreground: "#e6e6e6", accent: "#5865f2", dim: "#8b8b96")
    }

    /// What a panel paints before its document has, matching the CSS `--panel`
    /// (`color-mix(in srgb, var(--bg) 88%, white 12%)`).
    ///
    /// Duplicated arithmetic, deliberately and narrowly: the container has to have a
    /// colour BEFORE any message reaches the document, so it cannot come from the theme
    /// the document is sent. Keeping the two in step is the reason the mix is written
    /// out here rather than approximated.
    private func panelBackground() -> NSColor {
        let base =
            activeSession?.background.flatMap { NSColor(cgColor: $0) }?
            // The FALLBACK only: with a session, the panel derives from the terminal's
            // own background, which is the sync the chrome elsewhere does not have. Before
            // any session reports one it was a blue-tinted near-black; achromatic now, for
            // the reason in `Chrome.swift`.
            .usingColorSpace(.sRGB) ?? ChromeColor.of(ChromeColor.ink).usingColorSpace(.sRGB)!
        return NSColor(
            srgbRed: base.redComponent * 0.88 + 0.12,
            green: base.greenComponent * 0.88 + 0.12,
            blue: base.blueComponent * 0.88 + 0.12, alpha: 1)
    }

    /// cmd+shift+D toggles. Only ever reachable when `panels = true`.
    private func toggleDiffPanel() { togglePanel(.diff) }

    /// cmd+shift+E toggles. Only ever reachable when `panels = true`.
    private func toggleFilesPanel() { togglePanel(.files) }

    /// Closes the open panel; opens `kind` unless that is the one that was open.
    ///
    /// One panel at a time (see `webPanel`), so asking for the files panel while the diff
    /// is up swaps them rather than stacking a second overlay.
    private func togglePanel(_ kind: PanelKind) {
        if let webPanel {
            let wasKind = panelKind
            webPanel.removeFromSuperview()
            self.webPanel = nil
            panelKind = nil
            panelRoot = nil
            panelFiles = []
            filesRoot = nil
            filesRootOverride = nil
            window.makeFirstResponder(view)
            if wasKind == kind { return }
        }
        guard let url = WebPanel.documentURL(override: webDir) else {
            report("panels are enabled but the panel document was not found (build web/)")
            return
        }
        guard let panel = WebPanel(documentURL: url, background: panelBackground()) else { return }
        panel.onProtocolError = { [weak self] detail in self?.report("panel bridge: \(detail)") }
        panel.onMessage = { [weak self] message in self?.handle(message) }
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        // 1080pt wide where there is room, otherwise the window minus a margin. The
        // preferred width is breakable so the required inequality wins on a narrow
        // window instead of the layout engine reporting a conflict.
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 1080)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(
                lessThanOrEqualTo: view.widthAnchor, constant: -48),
            preferredWidth,
            panel.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.82),
        ])
        webPanel = panel
        panelKind = kind
        panel.focus()
    }





    /// Every session is refitted, not just the active one: a background session keeps
    /// running with its own geometry, and one that missed the dock would repaint at the
    /// old width the moment it is activated.
    private func refitAll() {
        // Visible panes take their own rect from the tiling. A background session has no
        // rect at all, so it is fitted to the whole container - the size it will get the
        // moment it is brought forward as a single pane.
        let panes = SplitLayout.tile(tree, in: paneContainer.bounds)
        for session in sessions {
            let rect = panes.first { $0.id == session.paneID }?.rect ?? paneContainer.bounds
            fit(session, to: rect)
        }
        if let session = activeSession { blit(session) }
    }


    /// Focuses the session already living in `path`, or opens one there.
    ///
    /// The path is checked against the worktrees this host listed, for the same reason
    /// the diff panel checks its file paths: an argument that crosses the boundary is
    /// validated by the side that acts on it, and acting here means spawning a shell.
    private func openWorkspace(path: String) {
        guard let directory = activeDirectory(),
            case .success(let trees) = Worktrees.list(containing: directory),
            let worktree = trees.first(where: { $0.path == path })
        else {
            report("asked to open an unlisted worktree: \(path)")
            return
        }
        if let session = sessions.first(where: { $0.workspace == worktree.branch }) {
            show(pane: session.paneID)
            return
        }
        newSession(in: worktree.path, workspace: worktree.label)
    }


    private func handle(_ message: PanelMessage) {
        switch message {
        case .ready:
            let kind = panelKind ?? .diff
            webPanel?.post(.initialize(theme: panelTheme(), panel: kind))
            refresh(kind)
        case .refresh:
            refresh(panelKind ?? .diff)
        case .dismiss:
            if let panelKind { togglePanel(panelKind) }
        case .requestDiff(let path):
            sendDiff(path: path)
        case .listDirectory(let path):
            sendDirectory(path: path)
        case .openFile(let path):
            sendFile(path: path)
        case .viewerState:
            // Only the smoke asserts on this; the window has nothing to do with it.
            break
        case .openWorkspace, .createWorkspace:
            break
        case .pong:
            // Only the smoke asserts on this; the window has nothing to do with it.
            break
        case .decodeError(let detail):
            report("panel could not read a host message: \(detail)")
        }
    }

    private func refresh(_ kind: PanelKind) {
        switch kind {
        case .diff: refreshDiffPanel()
        case .files: refreshFilesPanel()
        case .workspaces: break
        }
    }

    /// Picks the file panel's root and posts it with its first listing.
    ///
    /// The repository containing the active session's directory, or that directory when
    /// there is no repository. `/` is refused as a root: it is what a pane reports when it
    /// never learned a directory, and a panel rooted there would browse the whole disk.
    private func refreshFilesPanel() {
        if let root = filesRootOverride {
            filesRoot = root
            webPanel?.post(.tree(root: root, error: nil))
            sendDirectory(path: "")
            postPendingSelect()
            return
        }
        guard let directory = activeDirectory(), directory != "/" else {
            filesRoot = nil
            webPanel?.post(.tree(root: nil, error: "this session has not reported a directory"))
            return
        }
        gitQueue.async { [weak self] in
            let root = Git.repositoryRoot(containing: directory) ?? directory
            DispatchQueue.main.async {
                guard let self, self.panelKind == .files else { return }
                self.filesRoot = root
                self.webPanel?.post(.tree(root: root, error: nil))
                self.sendDirectory(path: "")
                self.postPendingSelect()
            }
        }
    }

    private func postPendingSelect() {
        guard let pending = pendingSelect else { return }
        pendingSelect = nil
        webPanel?.post(.select(path: pending.path, line: pending.line))
    }

    /// Shows one file, by absolute path, in the file panel: under the repository that holds
    /// it, or its own directory when none does. Reuses the open panel when it already has
    /// that root, so a second click is a jump rather than a reload.
    private func showFile(_ path: String, line: Int?) {
        let directory = (path as NSString).deletingLastPathComponent
        gitQueue.async { [weak self] in
            let root = Git.repositoryRoot(containing: directory) ?? directory
            DispatchQueue.main.async {
                guard let self else { return }
                // The Rust side hands back a canonical path and git a canonical root, so a
                // plain prefix test is sound; anything else would mean the two disagree
                // about where the file is, and showing nothing is the honest answer.
                guard root != "/", path.hasPrefix(root + "/") else {
                    self.report("cmd+click: \(path) is not under its own root \(root)")
                    return
                }
                let relative = String(path.dropFirst(root.count + 1))
                if self.panelKind == .files, self.filesRoot == root {
                    self.webPanel?.post(.select(path: relative, line: line))
                    return
                }
                self.pendingSelect = (relative, line)
                if let open = self.panelKind { self.togglePanel(open) }
                self.filesRootOverride = root
                self.togglePanel(.files)
            }
        }
    }

    /// Answers one `listDirectory`, validated under `filesRoot`.
    private func sendDirectory(path: String) {
        guard panelKind == .files, let root = filesRoot else {
            report("listDirectory with no file panel root: \(path)")
            return
        }
        fileQueue.async { [weak self] in
            let outcome = FileAccess.list(root: root, relative: path) { directory, names in
                Git.ignoredNames(in: directory, names)
            }
            DispatchQueue.main.async {
                guard let self, self.panelKind == .files, self.filesRoot == root else { return }
                switch outcome {
                case .success(let listing):
                    let note = listing.truncated > 0
                        ? "\(listing.truncated) more entries not listed" : nil
                    self.webPanel?.post(.directory(path: path, entries: listing.entries, error: note))
                case .failure(let reason):
                    self.report("listDirectory \(path): \(reason)")
                    self.webPanel?.post(.directory(path: path, entries: [], error: reason.description))
                }
            }
        }
    }

    /// Answers one `openFile`, validated under `filesRoot`.
    private func sendFile(path: String) {
        guard panelKind == .files, let root = filesRoot else {
            report("openFile with no file panel root: \(path)")
            return
        }
        fileQueue.async { [weak self] in
            let outcome = FileAccess.read(root: root, relative: path)
            DispatchQueue.main.async {
                guard let self, self.panelKind == .files, self.filesRoot == root else { return }
                switch outcome {
                case .success(let text):
                    self.webPanel?.post(.fileContent(path: path, text: text, error: nil))
                case .failure(let reason):
                    self.webPanel?.post(.fileContent(path: path, text: "", error: reason.description))
                }
            }
        }
    }

    /// Recomputes the changed-file list off the main thread and posts it.
    private func refreshDiffPanel() {
        guard let directory = activeDirectory() else {
            panelRoot = nil
            panelFiles = []
            webPanel?.post(.files(repo: nil, files: [], error: nil))
            return
        }
        gitQueue.async { [weak self] in
            let root = Git.repositoryRoot(containing: directory)
            let outcome = root.map { Git.changedFiles(root: $0) }
            DispatchQueue.main.async {
                guard let self, self.webPanel != nil else { return }
                self.panelRoot = root
                switch outcome {
                case .none:
                    self.panelFiles = []
                    self.webPanel?.post(.files(repo: nil, files: [], error: nil))
                case .some(.success(let files)):
                    self.panelFiles = files
                    self.webPanel?.post(.files(repo: root, files: files, error: nil))
                case .some(.failure(let error)):
                    self.panelFiles = []
                    self.webPanel?.post(.files(repo: root, files: [], error: error.description))
                }
            }
        }
    }

    /// Answers one `requestDiff`.
    ///
    /// The path is checked against the list this host advertised. That is not paranoia
    /// about our own React: it is the IPC rule -- an argument arriving from the other
    /// side of a boundary is validated by the side that acts on it, and here acting
    /// means reading a file off disk.
    private func sendDiff(path: String) {
        guard let root = panelRoot, let file = panelFiles.first(where: { $0.path == path }) else {
            report("panel asked for a diff of an unlisted path: \(path)")
            webPanel?.post(.fileDiff(path: path, patch: "", error: "not a listed change"))
            return
        }
        let untracked = file.status.hasPrefix("??")
        gitQueue.async { [weak self] in
            let outcome = Git.diff(root: root, path: path, untracked: untracked)
            DispatchQueue.main.async {
                guard let self, self.webPanel != nil else { return }
                switch outcome {
                case .success(let patch):
                    self.webPanel?.post(.fileDiff(path: path, patch: patch, error: nil))
                case .failure(let error):
                    self.webPanel?.post(
                        .fileDiff(path: path, patch: "", error: error.description))
                }
            }
        }
    }

    /// One line to stderr per seam event (SCAR-014): a panel that shows nothing must be
    /// distinguishable from a panel that was never asked anything.
    private func report(_ detail: String) {
        FileHandle.standardError.write(Data("[panel] \(detail)\n".utf8))
    }

    private func showBlockMenu(_ block: Block, with event: NSEvent) {
        guard let session = activeSession else { return }
        let command = session.command(of: block)

        let menu = NSMenu()
        // Explicit enablement: auto-enablement re-validates through the responder chain
        // and silently turns the flags below back on.
        menu.autoenablesItems = false
        // The command as a disabled header, so the menu names what it acts on.
        let header = NSMenuItem(
            title: command.isEmpty ? "Block" : "$ \(command)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let copyCommand = NSMenuItem(
            title: "Copy Command", action: #selector(blockCopyCommand(_:)), keyEquivalent: "")
        let copyOutput = NSMenuItem(
            title: "Copy Output", action: #selector(blockCopyOutput(_:)), keyEquivalent: "")
        let rerun = NSMenuItem(
            title: "Run Again", action: #selector(blockRerun(_:)), keyEquivalent: "")
        for item in [copyCommand, copyOutput, rerun] {
            item.target = self
            item.representedObject = BlockRef(block: block)
            menu.addItem(item)
        }
        copyCommand.isEnabled = !command.isEmpty
        rerun.isEnabled = !command.isEmpty
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// NSMenuItem.representedObject wants a class; Block is a value.
    private final class BlockRef: NSObject {
        let block: Block
        init(block: Block) { self.block = block }
    }

    private func clip(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func blockCopyCommand(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? BlockRef,
            let session = activeSession
        else { return }
        clip(session.command(of: reference.block))
    }

    @objc private func blockCopyOutput(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? BlockRef,
            let session = activeSession
        else { return }
        clip(session.output(of: reference.block))
    }

    @objc private func blockRerun(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? BlockRef,
            let session = activeSession
        else { return }
        let command = session.command(of: reference.block)
        guard !command.isEmpty else { return }
        session.send(Array(command.utf8) + [0x0d])
    }

    // MARK: tabs

    /// cmd+1 to cmd+9. 9 is the last tab whatever the count, and a digit past the last tab
    /// does nothing rather than wrapping to somewhere the operator did not name.
    private func selectTab(number: Int) {
        let count = tabSet.tabs.count
        guard count > 0 else { return }
        let index = number == 9 ? count - 1 : number - 1
        guard index < count else { return }
        activate(tab: index)
    }

    /// cmd+shift+] and [. Wraps at both ends, as tab cycling does in every macOS app.
    private func stepTab(by step: Int) {
        let count = tabSet.tabs.count
        guard count > 0 else { return }
        activate(tab: ((tabSet.current + step) % count + count) % count)
    }

    /// A new tab holding `session` alone, brought to the front.
    private func openTab(_ session: Session) {
        sessions.append(session)
        activate(tab: tabSet.open(session.paneID))
    }

    /// Brings forward the tab that holds `pane`, with the keyboard on that pane.
    private func show(pane: Int) {
        guard let index = tabSet.index(containing: pane) else { return }
        tabSet.focus(pane)
        activate(tab: index, force: true)
    }

}

// The tab island: every session as one chip in the title band, drawn in SwiftUI glass.
//
// The maintainer, 2026-10-02: "אני לא רוצה שיהיה Sidebars בטרמינל שלי, אני רוצה שיהיה טאבים, ושימוש
// ב SwiftUI glass Islands כמו במאק". The docked sidebar is gone and this replaces it. The
// layout is mockup A from the same day: a 52pt band at the top of the window, the traffic
// lights centred in it, the island after them, and the terminal starting BELOW the band so no
// row ever sits under glass. The decision record is docs/decisions/2026-10-02-swiftui-glass-chrome.md.
//
// SwiftUI only for the chrome. The pane stays AppKit, because its input path (key encoding,
// first mouse, selection, the link underline) is all NSView overrides that SwiftUI has no
// equivalent for.
//
// WHAT THE SIDEBAR SHOWED AND WHERE IT WENT. A row had a title, `branch · directory` and a
// state dot. The chip keeps the title and the dot, and the second line becomes the chip's
// tooltip: it is the fact that tells two `claude` sessions in one repository apart, and a
// chip has no room for a second line.
//
// GLASS ONLY. A flat "plain" style shipped beside it as an in-app A/B, and the maintainer picked glass
// on 2026-10-02, so the other side is gone.

import AppKit
import SwiftUI

/// One session, as a tab sees it. A value type so the model can skip a publish when
/// nothing changed: titles and work states arrive several times a second from a busy agent.
struct TabItem: Equatable, Identifiable {
    /// The session's pane id. Stable across reorders, which an index is not.
    let id: Int
    let title: String
    /// `branch · directory`, either half optional. The chip's tooltip.
    let detail: String
    let state: Session.WorkState
}

/// What the island draws and where its clicks go. The app delegate owns the sessions; this
/// holds a copy of what the chips need and three callbacks back.
final class TabModel: ObservableObject {
    @Published private(set) var items: [TabItem] = []
    @Published private(set) var active = -1
    /// The palette's Motion switch. Off makes every change below instant.
    @Published var motion = true
    /// Per tab id, how many times its session arrived at a state worth a look. Kept here and
    /// not in the dot's view: the dot is a conditional child that SwiftUI rebuilds when the
    /// state changes, and a rebuilt view never sees its trigger move (the first build pinged
    /// nothing in a 10 fps capture).
    @Published private(set) var pings: [Int: Int] = [:]
    /// The room the chips will have once the island's frame settles, set by the host before it
    /// animates the frame there. The squeeze reads this, not the room measured mid-animation:
    /// a growing island measured on the way showed a new tab squeezed to "pr…f 2" for a frame.
    @Published var settledRoom: CGFloat = 0

    var onSelect: ((Int) -> Void)?
    /// The `+`. The receiver pops the new-session menu under the pointer.
    var onNew: (() -> Void)?
    /// The strip's natural width, measured by SwiftUI. The host frames the island at
    /// min(this, room), so it has to hear about every change.
    private(set) var idealWidth: CGFloat = 0
    var onIdealWidthChange: (() -> Void)?

    /// How far the strip is scrolled, for the click and wheel taps to log. Not published:
    /// nothing draws from it.
    var scrollOffset: CGFloat = 0

    func report(idealWidth: CGFloat) {
        guard abs(idealWidth - self.idealWidth) > 0.5 else { return }
        self.idealWidth = idealWidth
        onIdealWidthChange?()
    }

    /// Publishes only on a real change, so a title event that repeats the same title does
    /// not re-render the island.
    func update(items: [TabItem], active: Int) {
        guard items != self.items || active != self.active else { return }
        let before = Dictionary(self.items.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for item in items where motion && !reduce {
            if let old = before[item.id], Motion.pings(from: old, to: item.state) {
                pings[item.id, default: 0] += 1
            }
        }
        // One transaction for both, so a new tab that is also the active one arrives and takes
        // the highlight in a single movement rather than two.
        withAnimation(Motion.spring(enabled: motion, reduce: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
            if items != self.items { self.items = items }
            if active != self.active { self.active = active }
        }
    }
}

/// The island's measurements. Kept apart from the views so the gate can read them.
enum TabMetrics {
    /// The band the island sits in. 52 is the unified title bar's height on macOS 26 with a
    /// toolbar attached, which is also what centres the traffic lights in it.
    static let bandHeight: CGFloat = 52
    static let chipHeight: CGFloat = 30
    static let spacing: CGFloat = 6
    /// Gap between the zoom button and the island, and between the island and the right edge.
    static let margin: CGFloat = 12
    /// A title longer than this many characters is cut in the middle. Without a cap one long
    /// title takes the whole band and every other tab scrolls off.
    ///
    /// Characters rather than points, and that is deliberate: a SwiftUI frame with a maximum
    /// width does not truncate a Text measured at its ideal size, it lets it overflow. Cutting
    /// the string is the version that cannot overflow.
    static let maxTitle = 28

    /// The narrowest a squeezed chip gets: the mark, a short title and the padding. Below
    /// this the strip stops squeezing and scrolls instead, because a chip with no readable
    /// title is a dot nobody can tell apart from its neighbours.
    static let minChipWidth: CGFloat = 80
    /// Width of the edge fade that says "more tabs this way".
    static let fade: CGFloat = 24

    /// Every chip's width when the tabs do not fit at their natural size, or nil when they
    /// do. The Safari rule: all chips shrink EQUALLY, so no tab is singled out, until they
    /// hit `minChipWidth`, and from there the strip scrolls.
    static func squeeze(natural: CGFloat, room: CGFloat, count: Int) -> CGFloat? {
        guard count > 0, natural > room + 0.5 else { return nil }
        let share = (room - spacing * CGFloat(count - 1)) / CGFloat(count)
        return max(minChipWidth, share.rounded(.down))
    }

    /// `title` cut to `maxTitle` characters, keeping both ends: a path or a branch name is told
    /// apart by its tail as often as by its head.
    static func clip(_ title: String) -> String {
        guard title.count > maxTitle else { return title }
        let keep = maxTitle - 1
        return String(title.prefix(keep - keep / 2)) + "\u{2026}" + String(title.suffix(keep / 2))
    }

    /// Where the island goes inside the band. `leading` is the x just past the traffic
    /// lights; `ideal` is the island's own width. The island never runs past the right
    /// margin, never goes negative on a narrow window, and is centred vertically.
    static func islandFrame(band: NSRect, leading: CGFloat, ideal: CGFloat) -> NSRect {
        let x = min(band.minX + leading, band.maxX)
        let room = max(0, band.maxX - margin - x)
        return NSRect(
            x: x, y: band.minY + ((band.height - chipHeight) / 2).rounded(),
            width: min(max(0, ideal), room), height: chipHeight)
    }
}

/// A session's work state, drawn. SHAPE carries the state, not hue.
///
/// The dots used to be amber, red and emerald, and hue is the obvious way to separate
/// states at 8 points. It is also the thing the maintainer asked to remove (2026-08-25), and a
/// greyscale ramp on its own does not survive: three brightnesses of the same circle read
/// as one circle at three distances.
///
/// So each state gets its own SHAPE, and brightness reinforces rather than carries:
///
/// - **error**: a filled SQUARE, pure white. The only shape here with corners.
/// - **working**: a filled DISC, mid grey.
/// - **done**: a hollow RING, mid grey. "Finished and not yet looked at" is the state you
///   are meant to clear, and an outline reads as an empty box to tick.
/// - **attention**: a narrow BAR, pure white. A fifth round thing at a fifth brightness is
///   what this type refuses, and the bar is the session that has STOPPED and needs the
///   operator, so it gets the brightest ink.
/// - **idle**: nothing at all, which needs no ink.
enum StateDot {
    static let size: CGFloat = 8

    enum Shape: Equatable {
        case none, square, disc, ring, bar
    }

    /// The shape and the white level it is drawn in.
    static func mark(_ state: Session.WorkState) -> (shape: Shape, level: CGFloat) {
        switch state {
        case .error: return (.square, ChromeColor.accent)
        case .working: return (.disc, 0.62)
        case .done: return (.ring, 0.62)
        case .attention: return (.bar, ChromeColor.accent)
        case .idle: return (.none, 0)
        }
    }
}

struct StateDotView: View {
    let state: Session.WorkState
    var motion = true
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let (shape, level) = StateDot.mark(state)
        let ink = Color(nsColor: ChromeColor.over(level))
        let moving = motion && !reduce
        Group {
            switch shape {
            case .square: RoundedRectangle(cornerRadius: 1).fill(ink)
            case .disc: Circle().fill(ink)
            case .ring: Circle().strokeBorder(ink, lineWidth: 1.5)
            case .bar: Capsule().fill(ink).frame(width: 3)
            case .none: Color.clear
            }
        }
        .frame(width: StateDot.size, height: StateDot.size)
        // WORKING BREATHES. The disc alone said "busy" the way a stopped clock says the time;
        // a slow pulse says the work is happening now. Opacity only, so the chip never reflows.
        .phaseAnimator(moving && state == .working ? [1.0, 0.35] : [1.0]) { dot, alpha in
            dot.opacity(alpha)
        } animation: { _ in
            .easeInOut(duration: Motion.breath / 2)
        }
    }
}

/// ARRIVING PINGS: one ring outward from where the dot sits, the moment a session finishes,
/// needs the operator or fails. Lives on the chip, which keeps its identity, and plays each
/// time `trigger` moves.
struct PingRing: View {
    let trigger: Int
    let state: Session.WorkState

    /// At rest the ring is invisible; a trigger lights it at the dot's size and spreads it out
    /// to nothing. A keyframe animator was tried first and never drew a frame in a 10 fps
    /// capture although its trigger moved (logged), so this is the phase form.
    enum Phase: CaseIterable { case rest, lit, spread }

    var body: some View {
        Circle()
            .stroke(Color(nsColor: ChromeColor.over(StateDot.mark(state).level)), lineWidth: 1)
            .frame(width: StateDot.size, height: StateDot.size)
            .phaseAnimator(Phase.allCases, trigger: trigger) { ring, phase in
                ring.scaleEffect(phase == .spread ? 2.6 : 1).opacity(phase == .lit ? 0.9 : 0)
            } animation: { phase in
                phase == .spread ? .easeOut(duration: Motion.ping) : .linear(duration: 0.02)
            }
            .allowsHitTesting(false)
    }
}

struct TabIsland: View {
    @ObservedObject var model: TabModel
    @Namespace private var space
    /// The chips' natural width, measured off a hidden copy so a squeeze cannot feed back
    /// into its own measurement.
    @State private var natural: CGFloat = 0
    /// The width the scroll view actually has, the `+` excluded.
    @State private var room: CGFloat = 0
    /// Which edges have tabs beyond them, for the fade.
    @State private var more = Overflow()

    struct Overflow: Equatable {
        var offset: CGFloat = 0
        var leading = false
        var trailing = false
    }

    // OVERFLOW, the maintainer 2026-10-02 with fourteen tabs on screen: "Overcrowd של טאבים נחתך ואין
    // אפשרות לדפדף. צריך לעשות משהו אנטואטיבי ונוח". The first version only scrolled, and a
    // horizontal strip does not answer an ordinary mouse wheel, so the tail was simply gone,
    // the `+` with it. Now, in order:
    //
    // 1. The chips shrink equally until they fit (`TabMetrics.squeeze`), titles cut.
    // 2. Past `minChipWidth` the strip scrolls, and the vertical wheel scrolls it too
    //    (`TabWheel`, installed by the app delegate).
    // 3. An edge fades on whichever side has more tabs, so the overflow is visible.
    // 4. The active tab is always scrolled into view: cmd+9, a new tab, a click.
    // 5. The `+` is outside the scroll view and never leaves the band.
    var body: some View {
        HStack(spacing: TabMetrics.spacing) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // The glass container INSIDE the scroll view. Outside it, the container
                        // drew the chips' glass where the scroll view could not clip it, and an
                        // overflowing strip spilled across the traffic lights and under the `+`.
                        GlassEffectContainer(spacing: TabMetrics.spacing) {
                            HStack(spacing: TabMetrics.spacing) {
                                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                    chip(item, index: index, width: width).id(item.id)
                                        // A tab arrives and leaves; it does not blink in or out.
                                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                                }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .clipped()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
                    .onScrollGeometryChange(for: Overflow.self) { geometry in
                        let x = geometry.contentOffset.x
                        return Overflow(
                            offset: x, leading: x > 1,
                            trailing: x + geometry.containerSize.width < geometry.contentSize.width - 1)
                    } action: { _, seen in
                        model.scrollOffset = seen.offset
                        more = seen
                    }
                    .mask(fade)
                    .onChange(of: model.active, initial: true) { _, _ in reveal(proxy) }
                    .onChange(of: model.items.count) { _, _ in reveal(proxy) }
                }
                plus
        }
        .frame(height: TabMetrics.chipHeight)
        .background(measure)
    }

    private var width: CGFloat? {
        let room = model.settledRoom > 0 ? model.settledRoom : self.room
        return TabMetrics.squeeze(natural: natural, room: room, count: model.items.count)
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard model.active >= 0, model.active < model.items.count else { return }
        let id = model.items[model.active].id
        // After the layout that added or resized the chip, or there is nothing to scroll to.
        // CENTRED: the nearest edge is where the fade is, and the first version parked the
        // active tab half under it.
        //
        // With motion on, after the spring too: a scroll asked for while fourteen chips were
        // still arriving landed on the strip's start and left the active tab off screen (seen
        // in a capture against the motion-off build, which revealed it). Then it glides there.
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let delay = model.motion && !reduce ? Motion.response : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(Motion.spring(enabled: model.motion, reduce: reduce)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// The natural strip, laid out and never drawn. It reports two widths: the chips alone,
    /// for the squeeze, and chips plus `+`, which is what the host frames the island to.
    private var measure: some View {
        HStack(spacing: TabMetrics.spacing) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                label(item, on: index == model.active, width: nil)
            }
        }
        .fixedSize()
        .hidden()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chips in
            natural = chips
            model.report(idealWidth: chips + TabMetrics.spacing + TabMetrics.chipHeight)
        }
    }

    private var fade: some View {
        let f = TabMetrics.fade
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: more.leading ? f : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: more.trailing ? f : 0)
        }
    }

    private func chip(_ item: TabItem, index: Int, width: CGFloat?) -> some View {
        let on = index == model.active
        let button = Button {
            model.onSelect?(index)
        } label: {
            label(item, on: on, width: width).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(item.detail.isEmpty ? item.title : item.detail)
        return button
            .glassEffect(
                on ? .regular.tint(.white.opacity(0.22)).interactive() : .clear.interactive(),
                in: Capsule())
            .glassEffectID(item.id, in: space)
    }

    /// The chip's content. `width` nil is the natural size; a number is a squeezed chip, whose
    /// title truncates in the middle inside it.
    private func label(_ item: TabItem, on: Bool, width: CGFloat?) -> some View {
        let text = Text(TabMetrics.clip(item.title))
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(
                Color(nsColor: ChromeColor.over(on ? ChromeColor.text : ChromeColor.textMuted)))
            .lineLimit(1)
        return HStack(spacing: 7) {
            if item.state != .idle {
                StateDotView(state: item.state, motion: model.motion)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if width == nil {
                // Its own natural width, always. Without this a title measured on a
                // fractional width came back one pixel short at 1x and drew as "claud...",
                // seen in the --shot-tabs capture with the whole band free.
                text.fixedSize()
            } else {
                text.truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: TabMetrics.chipHeight)
        .overlay(alignment: .leading) {
            PingRing(trigger: model.pings[item.id] ?? 0, state: item.state).padding(.leading, 12)
        }
    }

    private var plus: some View {
        let button = Button {
            model.onNew?()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: ChromeColor.over(ChromeColor.text)))
                .frame(width: TabMetrics.chipHeight, height: TabMetrics.chipHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("New session, workspace or SSH host")
        return button.glassEffect(.clear.interactive(), in: Circle())
    }
}

/// The ordinary mouse wheel, turned sideways over the tab strip.
///
/// A horizontal scroll view answers a trackpad's sideways swipe and ignores a wheel, which
/// only has a vertical axis. So over the island a mostly-vertical scroll is rewritten as the
/// same distance sideways, every delta field the event carries, before AppKit routes it.
enum TabWheel {
    static func sideways(_ event: NSEvent) -> NSEvent {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
            let cg = event.cgEvent?.copy()
        else { return event }
        // Every value READ before any is written, and the point delta written LAST. Setting
        // the line delta recomputes the point delta from it, so the first version, which
        // moved the fields pair by pair, read back a zero and produced a wheel that went
        // nowhere. The --smoke-chrome wheel gate caught it.
        let lines = cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixed = cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let points = cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        return NSEvent(cgEvent: cg) ?? event
    }
}

/// The island's host view.
final class TabIslandHost: NSHostingView<TabIsland> {
    /// A chip is a button, and the first click on an inactive window should switch the tab
    /// rather than only bring the window forward. Same reasoning as the pane's cmd+click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// The terminal's motion: one set of timings for everything that moves.
//
// The maintainer, 2026-10-02: "צריך קצת Motion Design לטרמינל הוא מרגיש חסר נשמה, אבל זה נעים לגלול".
// Until then the only thing in Termisu that moved was the bell's wash. He picked all four areas
// (tabs and status, interface transitions, a live caret, pixel scrolling); this file is the
// shared vocabulary they draw from, so the chrome moves as one thing rather than four.
//
// The rules every slice keeps: the terminal's TEXT never animates (output is read, not watched),
// nothing waits on an animation before taking input, and macOS Reduce Motion turns all of it
// off, as does the palette's "Motion: Off" (the in-app A/B).

import AppKit
import SwiftUI

enum Motion {
    /// The chrome's one spring: quick to settle, no visible overshoot on a 30pt chip.
    static let response = 0.32
    static let damping = 0.86
    /// A busy session's dot: one slow breath, in and out.
    static let breath = 1.4
    /// A finishing session's ping: one ring outward, then gone.
    static let ping = 0.7

    /// How long a panel takes to appear, and to leave. Leaving is quicker: the operator has
    /// already moved on, and the chrome should get out of the way faster than it arrived.
    static let appear = 0.16
    static let departure = 0.11
    /// How far a panel travels as it arrives, in points.
    static let travel: CGFloat = 8
    /// A tab switch: the outgoing pane cross-fades into the incoming one.
    static let crossfade = 0.12
    /// A trackpad gesture coming to rest on a whole row (M4): short, on the same landing curve.
    static let settle = 0.14
    /// AppKit's side of the spring: a fast start and a long soft landing, no overshoot.
    static let landing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)

    /// Whether the AppKit chrome may move: the palette switch and macOS Reduce Motion.
    static func on(_ enabled: Bool) -> Bool {
        enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A layer scaled by `scale` about its own centre. A view's layer anchors at its corner,
    /// so a plain scale would shrink a panel toward one corner instead of into itself.
    static func centred(scale: CGFloat, in bounds: CGRect, offset: CGPoint = .zero) -> CATransform3D {
        var t = CATransform3DMakeTranslation(bounds.midX + offset.x, bounds.midY + offset.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    }

    /// Where a panel starts: above its resting place, so it settles down into it. Layers here
    /// are bottom-up, so above is positive y.
    static let drop = CGPoint(x: 0, y: travel)

    /// Plays an arrival on `layer`: from transparent, `scale` and `offset` off, to rest.
    /// The model values are left at rest, so nothing waits on the animation and a missed
    /// frame cannot strand the layer half-shown.
    static func arrive(_ layer: CALayer, scale: CGFloat = 0.98, offset: CGPoint = drop, duration: Double = appear) {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = centred(scale: scale, in: layer.bounds, offset: offset)
        transform.toValue = CATransform3DIdentity
        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = duration
        group.timingFunction = landing
        layer.add(group, forKey: "termisu.arrive")
    }

    /// Plays a departure on `view` and removes it at the end. The caller has already let go of
    /// it (first responder, references), so input never waits for the fade.
    static func leave(_ view: NSView, scale: CGFloat = 0.98, offset: CGPoint = drop) {
        guard let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { view.removeFromSuperview() }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = CATransform3DIdentity
        transform.toValue = centred(scale: scale, in: layer.bounds, offset: offset)
        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = departure
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "termisu.leave")
        CATransaction.commit()
    }

    /// The caret's glide from one cell to the next: short enough that typing never trails it.
    static let glide = 0.07
    /// The caret's soft blink: one cycle, and how long it stays steady after the last key or
    /// move before it starts.
    static let blink = 1.1
    static let caretRest = 0.5

    /// The spring, or nil when motion is off: SwiftUI treats a nil animation as an instant
    /// change, so every call site reads the same whether motion is on or not.
    static func spring(enabled: Bool, reduce: Bool) -> Animation? {
        enabled && !reduce ? .spring(response: response, dampingFraction: damping) : nil
    }

    /// Whether a change of work state earns the ping: the session arrived at a state that asks
    /// to be looked at (finished, needs the operator, failed), the one moment worth turning the
    /// eye toward a background tab. Judged by where it arrived, not where it came from: a
    /// session can pass through idle on its way to done, and that must still ping.
    static func pings(from old: Session.WorkState, to new: Session.WorkState) -> Bool {
        old != new && (new == .done || new == .attention || new == .error)
    }
}

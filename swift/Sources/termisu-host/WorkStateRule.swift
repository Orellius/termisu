// What a program's TITLE says about whether it is working, as a pure decision.
//
// WHY THIS IS A TYPE AND NOT A METHOD. The rule used to live inside `Session.classify`,
// keyed on a private table, reachable only from a session with a live pty behind it. It was
// therefore never gated, and it was WRONG: two of the three spinner glyphs Claude Code
// actually puts in its title were missing from the table, so the dock announced "done" every
// time the spinner landed on one of them. Same shape as `LastPaneOutcome.decide` and
// `ChromeTransition.decide` -- the policy is a static a gate can read, and the view calls it.
//
// EXPLICIT SIGNALS ONLY. The maintainer's standing rule, and it is why this reads a marker the CLI
// PRINTS rather than guessing from silence. A CLI with no table entry never classifies at
// all, and OSC 9;4 progress still outranks everything here when a program emits it.

import Foundation

enum WorkStateRule {
    /// The busy markers, per CLI, MEASURED rather than recalled.
    ///
    /// Claude Code's title is `<spinner> <activity>`, and the spinner cycles through more
    /// than one family. The four `\u{2733}`-family glyphs came from reading the on-screen
    /// body; `\u{25D0}` and `\u{25D1}` came from the TITLE and were missing for as long as
    /// the table existed. Captured 2026-08-26 off a real pty running Claude Code v2.1.246:
    /// of the three distinct title glyphs in that capture, two were unknown here.
    ///
    /// STATED LIMIT: this is a list, so a new glyph in a future release breaks it silently
    /// again, in the same direction -- the dot says done while the agent works. The gate
    /// pins the glyphs that were measured; it cannot pin the ones that do not exist yet.
    /// A shape-based rule was considered and rejected: "the title starts with a symbol" is
    /// a guess about a category, and this file's whole contract is that it does not guess.
    static let busyMarkers: [String: [String]] = [
        "claude": [
            "\u{2733}",  // ✳ eight spoked asterisk
            "\u{2736}",  // ✶ six pointed black star
            "\u{273B}",  // ✻ teardrop spoked asterisk
            "\u{273D}",  // ✽ heavy teardrop spoked asterisk
            "\u{25D0}",  // ◐ circle with left half black, TITLE only
            "\u{25D1}",  // ◑ circle with right half black, TITLE only
        ]
    ]

    /// A BEL arrived, from any state.
    ///
    /// BEL is the oldest explicit "I need you" in the protocol and, measured 2026-08-26, the
    /// only one available: with Claude Code frozen on a permission prompt there is no title,
    /// no bell of its own and no `OSC 9;4` on the wire. The maintainer chose this over a hook the
    /// operator would have to wire, and over a quiet timer, which would have been a guess.
    ///
    /// It outranks everything, including `.error`, because both mean the same thing to the
    /// operator -- come and look -- and the louder of the two should win the 8 points of ink.
    static func rang(current: Session.WorkState) -> Session.WorkState {
        .attention
    }

    /// A tab's one dot, from the panes of its split: the one that most needs the operator.
    /// Attention outranks error (see `rang`), a failure outranks work still running, and work
    /// running outranks work finished, which says only that something is ready to read.
    static func loudest(_ states: [Session.WorkState]) -> Session.WorkState {
        let order: [Session.WorkState] = [.attention, .error, .working, .done]
        return order.first(where: states.contains) ?? .idle
    }

    /// `OSC 9;4` progress, and it CANNOT clear attention.
    static func afterProgress(_ state: UInt8, current: Session.WorkState) -> Session.WorkState {
        if current == .attention { return .attention }
        switch state {
        case 0: return current == .working ? .done : .idle
        case 2: return .error
        default: return .working
        }
    }

    /// The operator looked at the pane. The one thing that clears a badge, attention
    /// included, because a badge is a message TO the operator and looking is the delivery.
    static func afterSeen(_ current: Session.WorkState) -> Session.WorkState {
        switch current {
        case .done, .error, .attention: return .idle
        case .idle, .working: return current
        }
    }

    /// The next work state, or nil for "this title says nothing, leave the state alone".
    ///
    /// nil is not the same as `.idle` and the difference is the whole point: a CLI nobody
    /// has a table for must not have its OSC 9;4 progress overwritten by a title that was
    /// never a signal in the first place.
    static func decide(cli: String, title: String, current: Session.WorkState)
        -> Session.WorkState?
    {
        // STICKY. A bell means the session STOPPED. Everything that arrives after it is the
        // program repainting its screen, not the operator answering, so a spinner glyph
        // landing one frame later must not erase the one state that is a request.
        if current == .attention { return nil }
        guard let markers = busyMarkers[cli] else { return nil }
        if markers.contains(where: { title.contains($0) }) { return .working }
        return current == .working ? .done : nil
    }
}

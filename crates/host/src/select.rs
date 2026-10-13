//! Purpose: the ONE selection policy, for every host surface.
//! Public surface: `word_at`, `line_at`, `extend`, `all_visible`, `clear`, `text`, `set`.
//! Why this module exists: `Session` grew a full selection API and the C ABI grew none, so
//!   the macOS app -- which reaches the terminal only through `termisu_host_*` -- could not
//!   select text with a mouse at all. That is the FIFTH time one capability lived on one
//!   host path and not the other (`launch::dress` three times, then `launch::seat`), and
//!   every one of those was fixed by making a single function the only way to do the thing.
//!   `Session` and the C exports both call this and neither implements it.
//!
//! Coordinates are CELLS, viewport-relative, the same space `termisu_host_link_at` uses.
//! Pixel-to-cell conversion needs the renderer's metrics, which the two callers already have
//! and this module deliberately does not: a policy that took pixels would need a font.
//!
//! The text formatter is `termisu_vt_core::selection::format`, which the differential corpus
//! measures against the real `libghostty-vt`. A host that walked the grid itself would
//! produce text that looks right and pastes wrong.

use termisu_vt_core::selection;
use termisu_vt_frame::{Frame, FrameSelection};
use termisu_vt_snapshot::{Point, Row, Selection};

/// A core range in the frame's own coordinates.
///
/// Total, with no fallible branch, precisely because the rows that produced the range came
/// from this frame: the conversion is an unwrap of two `Point`s, and the seam that used to be
/// dangerous, absolute scrollback rows against viewport rows, does not exist on this path
/// because the probe was fed viewport rows to begin with.
fn into_frame(found: &Selection) -> FrameSelection {
    FrameSelection { start: (found.start.x, found.start.y), end: (found.end.x, found.end.y) }
}

/// Whether a cell is inside the frame's visible grid.
///
/// Out of range is refused rather than answered empty, and the difference matters to a caller:
/// "there is no word here" is an ordinary click on blank space, while "that cell does not
/// exist" is the host having computed a bad coordinate and needing to hear about it.
pub fn in_grid(frame: &Frame, col: u16, row: u16) -> bool {
    frame.is_valid() && col < frame.cols && row < frame.rows
}

/// Sets or clears the highlight, and makes the next poll repaint.
///
/// The repaint is NOT incidental. A selection changes no terminal state, so the frame's
/// generation does not move, so `poll` would return `false` and the highlight would appear
/// only the next time the child happened to write something -- a selection that shows up when
/// you press a key. Resetting the drawn generation forces the full-frame path, which is also
/// what ERASING the previous highlight needs: a partial repaint touches only rows the child
/// dirtied, and the row the operator just deselected is not one of them.
pub fn set(frame: &mut Frame, drawn_generation: &mut u64, selection: Option<FrameSelection>) {
    if frame.selection == selection {
        return;
    }
    frame.selection = selection;
    *drawn_generation = 0;
}

/// Drops the highlight.
pub fn clear(frame: &mut Frame, drawn_generation: &mut u64) {
    set(frame, drawn_generation, None);
}

/// Extends a drag: a range anchored at `anchor`, held at `head`.
///
/// Endpoint order is the GESTURE's, not reading order -- a drag upward leaves `start` after
/// `end` -- because that is what tells the host which end the pointer holds. Every reader goes
/// through `FrameSelection::ordered`.
pub fn extend(
    frame: &mut Frame,
    drawn_generation: &mut u64,
    anchor: (u16, u16),
    head: (u16, u16),
) -> bool {
    if !in_grid(frame, anchor.0, anchor.1) || !in_grid(frame, head.0, head.1) {
        return false;
    }
    set(frame, drawn_generation, Some(FrameSelection { start: anchor, end: head }));
    true
}

/// Selects the word under a cell. `false` means there is nothing selectable there, which is a
/// real answer: a double-click on a blank cell selects nothing.
pub fn word_at(frame: &mut Frame, drawn_generation: &mut u64, col: u16, row: u16) -> bool {
    probe(frame, drawn_generation, col, row, selection::select_word)
}

/// Selects the line under a cell, trailing whitespace trimmed by the same rule the oracle uses.
pub fn line_at(frame: &mut Frame, drawn_generation: &mut u64, col: u16, row: u16) -> bool {
    probe(frame, drawn_generation, col, row, selection::select_line)
}

/// Selects the whole visible grid.
///
/// Visible, not the whole scrollback: a frame is a viewport and history is not in it. Said out
/// loud because `Terminal::select`'s `All` DOES reach into history, and the two answering
/// differently is a difference a person can see.
pub fn all_visible(frame: &mut Frame, drawn_generation: &mut u64) -> bool {
    if !frame.is_valid() {
        return false;
    }
    let rows = frame.viewport_rows();
    match selection::select_all(&rows, frame.cols) {
        Some(found) => {
            set(frame, drawn_generation, Some(into_frame(&found)));
            true
        }
        None => false,
    }
}

/// The clipboard text for the current highlight, or `None` when nothing is selected.
pub fn text(frame: &Frame) -> Option<String> {
    let selection = frame.selection?;
    if !frame.is_valid() {
        return None;
    }
    let rows = frame.viewport_rows();
    let ((sx, sy), (ex, ey)) = selection.ordered();
    Some(selection::format(
        &rows,
        frame.cols,
        &Selection {
            start: Point { x: sx, y: sy },
            end: Point { x: ex, y: ey },
            rectangle: false,
        },
    ))
}

/// Shared body of the word and line probes: viewport rows in, frame-space highlight out.
fn probe(
    frame: &mut Frame,
    drawn_generation: &mut u64,
    col: u16,
    row: u16,
    found_by: fn(&[Row], u16, Point) -> Option<Selection>,
) -> bool {
    if !in_grid(frame, col, row) {
        return false;
    }
    let rows = frame.viewport_rows();
    match found_by(&rows, frame.cols, Point { x: col, y: row }) {
        Some(found) => {
            set(frame, drawn_generation, Some(into_frame(&found)));
            true
        }
        None => false,
    }
}

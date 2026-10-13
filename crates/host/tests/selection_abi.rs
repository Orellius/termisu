//! Can an embedder select text at all?
//!
//! `Session` has had `select_to`, `select_word_at`, `select_line_at`, `select_all_visible`
//! and `selection_text` since the renderer learned to draw a highlight. Measured 2026-08-26:
//! **nothing in this repository called any of them**, no test exercised one, and not one
//! crossed the C ABI -- so the macOS app, which reaches the terminal only through
//! `termisu_host_*`, could not select text with a mouse. The operator reported it as
//! "you cannot select text like in any sane terminal", which is exactly right.
//!
//! This is the fifth time one capability has existed on one host path and not the other
//! (`launch::dress` three times, then `launch::seat`), so the fix is a shared policy both
//! call, and the gate asks the C surface, which is the path the product takes.
//!
//! The oracle is `termisu_vt_core::selection::format`, the same function the differential
//! corpus measures against the real `libghostty-vt`. A host that walked the grid itself
//! would produce text that looks right and pastes wrong.

use std::ffi::CString;
use std::ptr;
use std::time::{Duration, Instant};

use termisu_vt_host::{
    DEFAULT_FONT_SIZE, TERMISU_TEXT_ALL, TermisuHost, TermisuHostFrame, TermisuHostOptions,
    TermisuHostResult,
    termisu_host_free, termisu_host_poll, termisu_host_row_text, termisu_host_select_all,
    termisu_host_select_clear, termisu_host_select_line_at, termisu_host_select_to,
    termisu_host_select_word_at, termisu_host_selection_text, termisu_host_spawn,
};

const COLS: u16 = 40;
const ROWS: u16 = 6;
const PATIENCE: Duration = Duration::from_secs(10);
const LINE: &str = "alpha bravo charlie";
/// A SECOND written row, so select-all has two to join and the joining rule is observable.
const SECOND: &str = "delta echo";

/// Spawns a child through the C surface and pumps until its output is on the grid.
///
/// The wait is on the OBSERVABLE, the text appearing, rather than on a fixed deadline, so a
/// loaded machine makes this slower instead of red.
fn spawn_showing() -> *mut TermisuHost {
    let command = CString::new(format!("printf '{LINE}\\n{SECOND}'; sleep 30")).expect("command");
    let options = TermisuHostOptions {
        cols: COLS,
        rows: ROWS,
        font_size: DEFAULT_FONT_SIZE,
        command: command.as_ptr(),
        auto_direction: false,
        config: ptr::null(),
        cwd: ptr::null(),
    };
    let mut host: *mut TermisuHost = ptr::null_mut();
    assert_eq!(
        unsafe { termisu_host_spawn(&options, &mut host) },
        TermisuHostResult::Success,
        "spawn through the C surface"
    );
    assert!(!host.is_null());

    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        let mut frame = empty_frame();
        assert_eq!(
            unsafe { termisu_host_poll(host, &mut frame) },
            TermisuHostResult::Success,
            "poll"
        );
        // `row_text` refuses a host that has never polled a valid frame, which is the
        // ordinary state of the first few passes here, so an early miss is "not yet".
        if frame.generation > 0 && row_text(host, 0).contains(LINE) {
            return host;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("the child never printed {LINE:?} within {PATIENCE:?}");
}

/// A zeroed out-param for polls, matching the C caller's `TermisuHostFrame frame = {0}`.
fn empty_frame() -> TermisuHostFrame {
    TermisuHostFrame {
        pixels: ptr::null(),
        width: 0,
        height: 0,
        generation: 0,
        drew: false,
        child_exited: false,
        background: [0; 4],
        row_semantics: ptr::null(),
        row_count: 0,
        viewport_offset: 0,
        cursor_col: 0,
        cursor_row: 0,
        cursor_visible: false,
    }
}

fn row_text(host: *mut TermisuHost, row: u16) -> String {
    let mut len = 0usize;
    assert_eq!(
        unsafe { termisu_host_row_text(host, row, TERMISU_TEXT_ALL, ptr::null_mut(), 0, &mut len) },
        TermisuHostResult::Success,
        "row_text sizing"
    );
    let mut buffer = vec![0u8; len];
    assert_eq!(
        unsafe {
            termisu_host_row_text(host, row, TERMISU_TEXT_ALL, buffer.as_mut_ptr(), len, &mut len)
        },
        TermisuHostResult::Success,
        "row_text fetch"
    );
    buffer.truncate(len);
    String::from_utf8(buffer).expect("row text is utf-8")
}

/// The two-call contract every string getter on this surface uses: size, then fetch.
fn selection_text(host: *mut TermisuHost) -> Option<String> {
    let mut len = 0usize;
    assert_eq!(
        unsafe { termisu_host_selection_text(host, ptr::null_mut(), 0, &mut len) },
        TermisuHostResult::Success,
        "selection_text sizing"
    );
    if len == 0 {
        return None;
    }
    let mut buffer = vec![0u8; len];
    assert_eq!(
        unsafe { termisu_host_selection_text(host, buffer.as_mut_ptr(), len, &mut len) },
        TermisuHostResult::Success,
        "selection_text fetch"
    );
    buffer.truncate(len);
    Some(String::from_utf8(buffer).expect("selection text is utf-8"))
}

#[test]
fn a_word_can_be_selected_through_the_c_surface() {
    let host = spawn_showing();

    // Column 8 is inside "bravo" (a l p h a _ b r), so this is the double-click case.
    let mut found = false;
    assert_eq!(
        unsafe { termisu_host_select_word_at(host, 8, 0, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found, "column 8 of row 0 is inside a word and nothing was selected");
    let text = selection_text(host);
    assert_eq!(
        text.as_deref(),
        Some("bravo"),
        "the C surface selected a word and reported {text:?}"
    );

    unsafe { termisu_host_free(host) };
}

#[test]
fn a_drag_selects_the_cells_between_its_ends() {
    let host = spawn_showing();

    // Anchor at the 'a' of alpha, head at the 'o' of bravo: a drag ACROSS a word boundary,
    // which is what separates an extend from a word probe.
    let mut found = false;
    assert_eq!(
        unsafe { termisu_host_select_to(host, 0, 0, 10, 0, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found, "a drag inside the grid selected nothing");
    assert_eq!(selection_text(host).as_deref(), Some("alpha bravo"));

    unsafe { termisu_host_free(host) };
}

#[test]
fn a_drag_across_two_rows_keeps_both_ends_where_they_were_put() {
    let host = spawn_showing();

    // Row 0 column 6 is the 'b' of bravo; row 1 column 4 is the 'a' of delta's neighbour.
    // A MULTI-ROW drag, which the single-row case above cannot see: a row-major comparison
    // written the wrong way round, or an anchor overwritten by the head, both produce a
    // perfectly plausible single-row selection and only diverge once two rows are involved.
    let mut found = false;
    assert_eq!(
        unsafe { termisu_host_select_to(host, 6, 0, 4, 1, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found, "a two-row drag selected nothing");
    let text = selection_text(host).expect("a two-row drag selected something");
    assert_eq!(
        text, "bravo charlie\ndelta",
        "the drag ran from row 0 column 6 to row 1 column 4 and copied {text:?}"
    );

    // Backwards, and the answer must be identical: endpoint order is the GESTURE's, so a
    // drag upward stores start after end and every reader goes through `ordered`. Without
    // this row an implementation that only ever looked at `start` passes above and selects
    // nothing at all when the hand moves up the screen.
    assert_eq!(
        unsafe { termisu_host_select_to(host, 4, 1, 6, 0, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found, "the same drag upward selected nothing");
    assert_eq!(
        selection_text(host).as_deref(),
        Some("bravo charlie\ndelta"),
        "dragging up gave a different answer from dragging down over the same two cells"
    );

    unsafe { termisu_host_free(host) };
}

#[test]
fn a_line_selection_trims_its_trailing_blanks() {
    let host = spawn_showing();

    let mut found = false;
    assert_eq!(
        unsafe { termisu_host_select_line_at(host, 3, 0, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found, "a triple-click on a written row selected nothing");
    let text = selection_text(host).expect("a line was selected");
    assert_eq!(
        text, LINE,
        "the row is {COLS} columns wide and the selection kept its padding: {text:?}"
    );

    unsafe { termisu_host_free(host) };
}

#[test]
fn select_all_takes_the_visible_grid_and_clear_puts_it_back() {
    let host = spawn_showing();

    let mut found = false;
    assert_eq!(
        unsafe { termisu_host_select_all(host, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found, "select-all on a grid with text on it selected nothing");
    let all = selection_text(host).expect("select-all selected something");
    // Both rows AND the break between them. `contains(LINE)` alone was the assertion here
    // until a live tap showed what it could not see: two rows that do not soft-wrap must
    // copy with a newline between them, and a formatter that joined everything into one
    // line satisfied `contains` perfectly. The rows here end at column 19 and 10 of a
    // 40-column grid, so neither wraps and the break is not optional.
    assert!(
        all.contains(&format!("{LINE}\n{SECOND}")),
        "select-all reported {all:?}; the two written rows do not soft-wrap, so they must be \
         separated by a newline rather than run together"
    );

    // The control, and half a highlight that never goes away would pass without it: clearing
    // must actually clear, or every later copy returns a stale range.
    assert_eq!(unsafe { termisu_host_select_clear(host) }, TermisuHostResult::Success);
    assert_eq!(
        selection_text(host),
        None,
        "the selection was cleared and text still came back"
    );

    unsafe { termisu_host_free(host) };
}

#[test]
fn selecting_makes_the_next_poll_repaint() {
    let host = spawn_showing();

    // Drain to a quiet frame first: the child is `sleep 30` now, so nothing else can dirty
    // the grid and a later `drew` can only come from the selection.
    let mut quiet = 0;
    let deadline = Instant::now() + PATIENCE;
    while quiet < 3 && Instant::now() < deadline {
        let mut frame = empty_frame();
        assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
        quiet = if frame.drew { 0 } else { quiet + 1 };
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(quiet >= 3, "the grid never went quiet, so this test cannot measure a repaint");

    let mut found = false;
    assert_eq!(
        unsafe { termisu_host_select_word_at(host, 8, 0, &mut found) },
        TermisuHostResult::Success,
    );
    assert!(found);

    // A selection changes NO terminal state, so the frame's generation does not move and a
    // host that only redraws on new output would show the highlight the next time the child
    // happened to write something -- a selection that appears when you press a key. Without
    // this assertion every other test here passes on a highlight nobody can see.
    let mut frame = empty_frame();
    assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
    assert!(
        frame.drew,
        "a word was selected on a quiet grid and the next poll drew nothing; the highlight \
         would appear only when the child next writes"
    );

    // And the same for erasing it: a partial repaint touches only rows the child dirtied,
    // and the row just deselected is not one of them.
    assert_eq!(unsafe { termisu_host_select_clear(host) }, TermisuHostResult::Success);
    let mut frame = empty_frame();
    assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
    assert!(frame.drew, "the selection was cleared and the next poll left it on screen");

    unsafe { termisu_host_free(host) };
}

#[test]
fn a_probe_on_a_blank_cell_selects_nothing_rather_than_erroring() {
    let host = spawn_showing();

    // Row 2 is below everything the child wrote. A double-click there is not an error, it is
    // a double-click that selects nothing, and reporting InvalidValue would make the host
    // treat an ordinary click as a failure.
    let mut found = true;
    assert_eq!(
        unsafe { termisu_host_select_word_at(host, 5, 2, &mut found) },
        TermisuHostResult::Success,
        "a probe on an empty row is a real answer, not an error"
    );
    assert!(!found, "a blank cell reported a word");
    assert_eq!(selection_text(host), None);

    unsafe { termisu_host_free(host) };
}

#[test]
fn a_probe_outside_the_grid_is_refused() {
    let host = spawn_showing();

    let mut found = true;
    assert_eq!(
        unsafe { termisu_host_select_word_at(host, COLS, 0, &mut found) },
        TermisuHostResult::InvalidValue,
        "a column past the last one is out of range, not an empty answer"
    );
    assert_eq!(
        unsafe { termisu_host_select_word_at(host, 0, ROWS, &mut found) },
        TermisuHostResult::InvalidValue,
    );

    unsafe { termisu_host_free(host) };
}

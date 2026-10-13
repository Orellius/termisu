//! What pixel scrolling (motion slice M4, the maintainer 2026-10-02) needs from the host, through the C
//! surface: the history rows directly above the viewport drawn SHARP, in order, with a count of
//! how many are real and the offset they sit above; and a way to ask whether the wheel is the
//! viewport's before the GUI slides the view.
//!
//! The child prints blocks on even lines and nothing on odd ones, so every check names one
//! row: a lead image that drew the viewport's own top row, or stood one row off, or ignored the
//! scroll, lands its ink on the wrong row and fails.

use std::ffi::CString;
use std::ptr;
use std::time::{Duration, Instant};

use termisu_vt_host::lead::{TermisuHostLead, termisu_host_lead};
use termisu_vt_host::{
    TermisuHost, TermisuHostFrame, TermisuHostOptions, TermisuHostResult, termisu_host_free,
    termisu_host_mouse_geometry, termisu_host_poll, termisu_host_scroll, termisu_host_spawn,
    termisu_host_wheel_scrolls_viewport,
};

const COLS: u16 = 40;
const ROWS: u16 = 10;
const PATIENCE: Duration = Duration::from_secs(10);
/// Shift in the C surface's mouse mods.
const SHIFT: u32 = 1;

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

fn spawn_child(script: &str) -> *mut TermisuHost {
    let command = CString::new(script).expect("command");
    let options = TermisuHostOptions {
        cols: COLS,
        rows: ROWS,
        font_size: 0.0,
        command: command.as_ptr(),
        auto_direction: false,
        config: ptr::null(),
        cwd: ptr::null(),
    };
    let mut host: *mut TermisuHost = ptr::null_mut();
    assert_eq!(unsafe { termisu_host_spawn(&options, &mut host) }, TermisuHostResult::Success);
    host
}

/// `lines` lines, blocks on the even ones, then the child idles with its cursor on a fresh row.
fn striped(lines: usize) -> String {
    format!(
        "i=0; while [ $i -lt {lines} ]; do if [ $((i % 2)) -eq 0 ]; then printf '\\342\\226\\210\\342\\226\\210\\342\\226\\210\\342\\226\\210'; fi; printf '\\n'; i=$((i+1)); done; exec sleep 30"
    )
}

/// Polls the frame and then the lead, as the GUI does, until `done` holds.
fn lead_until(
    host: *mut TermisuHost,
    done: impl Fn(&TermisuHostFrame, &TermisuHostLead, &[u8]) -> bool,
) -> Option<(TermisuHostLead, Vec<u8>)> {
    let deadline = Instant::now() + PATIENCE;
    let mut frame = empty_frame();
    while Instant::now() < deadline {
        let mut lead = TermisuHostLead {
            pixels: ptr::null(),
            width: 0,
            height: 0,
            rows: 0,
            above: 0,
            viewport: 0,
            generation: 0,
        };
        let mut polled = empty_frame();
        assert_eq!(unsafe { termisu_host_poll(host, &mut polled) }, TermisuHostResult::Success);
        if polled.drew || frame.generation == 0 {
            frame = polled;
        }
        frame.viewport_offset = polled.viewport_offset;
        assert_eq!(unsafe { termisu_host_lead(host, &mut lead) }, TermisuHostResult::Success);
        if !lead.pixels.is_null() {
            let len = (lead.width * lead.height * 4) as usize;
            let pixels = unsafe { std::slice::from_raw_parts(lead.pixels, len) }.to_vec();
            if done(&frame, &lead, &pixels) {
                return Some((lead, pixels));
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    None
}

/// The brightest ink above the image's darkest pixel in row `row` (0 is the top row), and the
/// largest step between horizontal neighbours there. Text drawn sharp steps from ground to full
/// ink inside a pixel; a blurred row cannot.
fn ink_in_row(lead: &TermisuHostLead, pixels: &[u8], row: u16) -> (u8, u8) {
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    let row_height = (lead.height / u32::from(lead.rows)) as usize;
    let width = lead.width as usize;
    let start = usize::from(row) * row_height * width * 4;
    let band = &pixels[start..start + row_height * width * 4];
    let ink = band.chunks(4).map(|p| p[0] - floor).max().unwrap_or(0);
    let mut step = 0u8;
    for line in band.chunks(width * 4) {
        for pair in line.chunks(4).collect::<Vec<_>>().windows(2) {
            step = step.max(pair[0][0].abs_diff(pair[1][0]));
        }
    }
    (ink, step)
}

#[test]
fn the_row_above_the_viewport_arrives_sharp_at_the_bottom() {
    // 30 lines through a 10-row screen leave line-0..20 in history; the viewport's top is
    // line-21 (blank), so the row directly above it is line-20 (blocks).
    let host = spawn_child(&striped(30));
    let found = lead_until(host, |_, lead, pixels| {
        lead.above == lead.rows && ink_in_row(lead, pixels, lead.rows - 1).0 > 100
    });
    unsafe { termisu_host_free(host) };
    let (lead, pixels) = found.expect("the row above the viewport never arrived");
    assert_eq!(lead.viewport, 0);
    let (ink, step) = ink_in_row(&lead, &pixels, lead.rows - 1);
    assert!(step > 100, "a {step}-level step: the lead row is soft, not sharp (ink {ink})");
    assert_eq!(ink_in_row(&lead, &pixels, lead.rows - 2).0, 0, "line-19 is blank and must stay blank");
}

#[test]
fn the_rows_follow_the_viewport_when_it_scrolls() {
    let host = spawn_child(&striped(30));
    let settled = lead_until(host, |_, lead, pixels| ink_in_row(lead, pixels, lead.rows - 1).0 > 100);
    assert!(settled.is_some(), "the first lead never arrived");
    assert_eq!(unsafe { termisu_host_scroll(host, 1) }, TermisuHostResult::Success);
    // One row up: the viewport's top is line-20, so the row above it is line-19, blank.
    let found = lead_until(host, |frame, lead, _| frame.viewport_offset == 1 && lead.viewport == 1);
    unsafe { termisu_host_free(host) };
    let (lead, pixels) = found.expect("the lead never followed the scroll");
    assert_eq!(ink_in_row(&lead, &pixels, lead.rows - 1).0, 0, "line-19 is blank");
    assert!(ink_in_row(&lead, &pixels, lead.rows - 2).0 > 100, "line-18 has blocks");
}

#[test]
fn a_short_history_reports_only_its_real_rows() {
    // 12 lines and a fresh row through 10 rows: line-0..2 left the top, three real rows.
    let host = spawn_child(&striped(12));
    let found = lead_until(host, |_, lead, _| lead.above == 3);
    unsafe { termisu_host_free(host) };
    let (lead, _) = found.expect("three real rows were never reported");
    assert!(lead.rows > 3, "the image has padding rows above the real ones");
}

/// Polls until the frame carries the child's modes, then asks the wheel question.
fn wheel_answer(script: &str, mods: u32) -> bool {
    let host = spawn_child(script);
    assert_eq!(
        unsafe { termisu_host_mouse_geometry(host, 10_000, 10_000, 0, 0, 0, 0) },
        TermisuHostResult::Success
    );
    // READY is the last thing printed, after every mode switch: once its row drew, the frame
    // carries the modes.
    let deadline = Instant::now() + PATIENCE;
    let mut drew = false;
    while Instant::now() < deadline && !drew {
        let mut frame = empty_frame();
        assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
        drew = frame.drew && frame.cursor_col == 5;
        std::thread::sleep(Duration::from_millis(10));
    }
    let answer = unsafe { termisu_host_wheel_scrolls_viewport(host, mods) };
    unsafe { termisu_host_free(host) };
    assert!(drew, "the child never printed READY");
    answer
}

#[test]
fn the_wheel_is_the_viewport_s_only_when_no_program_owns_it() {
    assert!(wheel_answer("printf 'READY'; exec sleep 30", 0), "a plain shell's wheel is the viewport's");
    assert!(
        !wheel_answer("printf '\\033[?1000h\\033[?1006hREADY'; exec sleep 30", 0),
        "a program reporting the mouse owns the wheel"
    );
    assert!(
        wheel_answer("printf '\\033[?1000h\\033[?1006hREADY'; exec sleep 30", SHIFT),
        "shift is the operator's escape hatch"
    );
    assert!(
        !wheel_answer("printf '\\033[?1049hREADY'; exec sleep 30", 0),
        "the alternate screen turns the wheel into arrows"
    );
}

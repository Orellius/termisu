//! Does the strip behind the tab band show the rows that scrolled off the top, blurred, and
//! the viewport's first rows under them?
//!
//! The maintainer's option 2 of the top blur (2026-10-02). Measured through the C surface, because the
//! strip is only worth anything if its pixels reach the GUI: a child prints solid blocks past
//! the bottom of the screen so whole rows leave the top, and the strip must then carry ink
//! (rows above the viewport were drawn) that is soft (they were blurred). The overlap at the
//! bottom must hold the viewport's own first row, which is what the GUI fades out over the
//! sharp original (Nodee's veil, his reference). An alternate-screen child with nothing on its
//! screen is the control: no history and no text, so the same strip must be flat.

use std::ffi::CString;
use std::ptr;
use std::time::{Duration, Instant};

use termisu_vt_host::strip::{TermisuHostStrip, termisu_host_strip};
use termisu_vt_host::{
    TermisuHost, TermisuHostFrame, TermisuHostOptions, TermisuHostResult, termisu_host_free, termisu_host_poll,
    termisu_host_spawn,
};

const COLS: u16 = 40;
const ROWS: u16 = 10;
const PATIENCE: Duration = Duration::from_secs(10);
const RADIUS: u32 = 8;

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

/// Polls the strip until `done` holds for its pixels, returning them with the strip.
fn strip_until(host: *mut TermisuHost, done: impl Fn(&TermisuHostStrip, &[u8]) -> bool) -> Option<(TermisuHostStrip, Vec<u8>)> {
    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        let mut strip = TermisuHostStrip {
            pixels: ptr::null(),
            width: 0,
            height: 0,
            overlap: 0,
            generation: 0,
            alternate_screen: false,
        };
        // The strip reads the main frame's top rows, so the frame has to be polled first,
        // exactly as the GUI does it.
        let mut frame = empty_frame();
        assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
        assert_eq!(unsafe { termisu_host_strip(host, RADIUS, &mut strip) }, TermisuHostResult::Success);
        if !strip.pixels.is_null() {
            let len = (strip.width * strip.height * 4) as usize;
            let pixels = unsafe { std::slice::from_raw_parts(strip.pixels, len) }.to_vec();
            if done(&strip, &pixels) {
                return Some((strip, pixels));
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    None
}

/// The brightest ink in the pixel rows `rows`, above the darkest pixel of the whole strip.
fn ink_in(strip: &TermisuHostStrip, pixels: &[u8], rows: std::ops::Range<u32>) -> u8 {
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    let width = (strip.width * 4) as usize;
    pixels[rows.start as usize * width..rows.end as usize * width].chunks(4).map(|p| p[0] - floor).max().unwrap_or(0)
}

/// The brightest red channel, and the largest step between horizontal neighbours. Text drawn
/// sharp steps from ground to full ink inside a pixel; a blurred strip cannot.
fn ink_and_sharpness(strip: &TermisuHostStrip, pixels: &[u8]) -> (u8, u8) {
    let floor = pixels.chunks(4).map(|p| p[0]).min().unwrap_or(0);
    let ink = pixels.chunks(4).map(|p| p[0] - floor).max().unwrap_or(0);
    let width = strip.width as usize;
    let mut step = 0u8;
    for row in pixels.chunks(width * 4) {
        for pair in row.chunks(4).collect::<Vec<_>>().windows(2) {
            step = step.max(pair[0][0].abs_diff(pair[1][0]));
        }
    }
    (ink, step)
}

#[test]
fn rows_that_left_the_top_show_in_the_strip_softened() {
    // Thirty rows of a dashed block line through a ten-row screen: twenty leave the top.
    let host = spawn_child("i=0; while [ $i -lt 30 ]; do printf '\\342\\226\\210 \\342\\226\\210 \\342\\226\\210 \\342\\226\\210 \\342\\226\\210\\n'; i=$((i+1)); done; exec sleep 30");
    let found = strip_until(host, |strip, pixels| strip.height > 0 && ink_and_sharpness(strip, pixels).0 > 40);
    unsafe { termisu_host_free(host) };
    let (strip, pixels) = found.expect("the strip never showed the rows that scrolled off");
    let (ink, step) = ink_and_sharpness(&strip, &pixels);
    assert!(!strip.alternate_screen);
    assert!(strip.overlap > 0 && strip.overlap < strip.height, "overlap {} of {}", strip.overlap, strip.height);
    assert!(step < 64, "a {step}-level step between neighbours: the strip is sharp, not blurred (ink {ink})");
}

#[test]
fn the_viewport_s_first_row_is_in_the_overlap() {
    // Nothing has scrolled off, so the history part is empty: any ink in the overlap can only
    // be the viewport's own first row, and none may appear above it.
    let host = spawn_child("printf '\\033[?25l\\342\\226\\210\\342\\226\\210\\342\\226\\210\\342\\226\\210'; exec sleep 30");
    let found = strip_until(host, |strip, pixels| {
        strip.overlap > 0 && ink_in(strip, pixels, strip.height - strip.overlap..strip.height) > 40
    });
    unsafe { termisu_host_free(host) };
    let (strip, pixels) = found.expect("the viewport's first row never reached the strip's overlap");
    let above = strip.height - strip.overlap;
    // The blur reaches a little way up across the seam; past one overlap height it must not.
    let clear = above.saturating_sub(strip.overlap);
    assert_eq!(ink_in(&strip, &pixels, 0..clear), 0, "ink above the viewport with no history");
}

#[test]
fn the_alternate_screen_leaves_the_strip_flat() {
    // The same history, then an empty alternate screen with the caret hidden: there is
    // nothing above its viewport and nothing on its first rows.
    let host = spawn_child("i=0; while [ $i -lt 30 ]; do printf '\\342\\226\\210 \\342\\226\\210 \\342\\226\\210\\n'; i=$((i+1)); done; printf '\\033[?1049h\\033[?25l'; exec sleep 30");
    let found = strip_until(host, |strip, _| strip.alternate_screen);
    unsafe { termisu_host_free(host) };
    let (strip, pixels) = found.expect("the strip never reported the alternate screen");
    let (ink, _) = ink_and_sharpness(&strip, &pixels);
    assert_eq!(ink, 0, "the alternate screen keeps no history, yet the strip has ink");
}

#[test]
fn history_that_lands_after_the_main_frame_still_reaches_the_strip() {
    // The pump publishes the main frame and the rows above it one after the other, so a tick
    // can read the new main frame and still the old history. The next tick finds the main
    // frame unchanged and must redraw for the history alone. Modelled by freezing the main
    // frame on the empty screen: after the first strip the main frame is never polled again.
    let host = spawn_child("printf '\\033[?25l'; sleep 1; i=0; while [ $i -lt 30 ]; do printf '\\342\\226\\210 \\342\\226\\210 \\342\\226\\210\\n'; i=$((i+1)); done; exec sleep 30");
    let first = strip_until(host, |strip, _| strip.height > 0);
    let Some((strip, pixels)) = first else {
        unsafe { termisu_host_free(host) };
        panic!("the strip never drew the empty screen");
    };
    // The caret is hidden, and the blur reaches a little way up across the seam; past one
    // overlap height only history can put ink.
    let history = 0..(strip.height - strip.overlap).saturating_sub(strip.overlap);
    assert_eq!(ink_in(&strip, &pixels, history.clone()), 0, "the child printed before the first strip; the test proves nothing");

    let deadline = Instant::now() + PATIENCE;
    let mut ink = 0;
    while Instant::now() < deadline && ink <= 40 {
        let mut strip = TermisuHostStrip {
            pixels: ptr::null(),
            width: 0,
            height: 0,
            overlap: 0,
            generation: 0,
            alternate_screen: false,
        };
        assert_eq!(unsafe { termisu_host_strip(host, RADIUS, &mut strip) }, TermisuHostResult::Success);
        let len = (strip.width * strip.height * 4) as usize;
        let pixels = unsafe { std::slice::from_raw_parts(strip.pixels, len) };
        ink = ink_in(&strip, pixels, 0..(strip.height - strip.overlap).saturating_sub(strip.overlap));
        std::thread::sleep(Duration::from_millis(10));
    }
    unsafe { termisu_host_free(host) };
    assert!(ink > 40, "history arrived without a new main frame and never reached the strip");
}

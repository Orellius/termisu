//! Does the caret layer get the caret the grid used to paint, in the right cell?
//!
//! The maintainer's motion slice M3 (2026-10-02): a caret that glides and blinks lives on a layer of its
//! own, so the host hands the GUI a one-cell image of it and stops painting it into the grid.
//! Measured through the C surface. The sprite must sit on the cursor's cell and carry that
//! cell's glyph inverted (a caret on a space is the control: one flat block), follow the
//! cursor, and report hidden when the child hides it. With the grid's caret switched off, the
//! cursor's cell in the polled pixels must be the plain background; switched on, the block.

use std::ffi::CString;
use std::ptr;
use std::time::{Duration, Instant};

use termisu_vt_host::caret::{TermisuHostCaret, termisu_host_caret, termisu_host_set_caret};
use termisu_vt_host::{
    TermisuHost, TermisuHostFrame, TermisuHostOptions, TermisuHostResult, termisu_host_free, termisu_host_poll,
    termisu_host_spawn,
};

const COLS: u16 = 40;
const ROWS: u16 = 10;
const PATIENCE: Duration = Duration::from_secs(10);

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

/// Polls frame and caret, as the GUI does, until `done` holds; returns the caret and its pixels.
fn caret_until(host: *mut TermisuHost, done: impl Fn(&TermisuHostCaret) -> bool) -> Option<(TermisuHostCaret, Vec<u8>)> {
    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        let mut frame = empty_frame();
        assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
        let mut caret = TermisuHostCaret {
            pixels: ptr::null(),
            width: 0,
            height: 0,
            column: 0,
            row: 0,
            visible: false,
            generation: 0,
        };
        assert_eq!(unsafe { termisu_host_caret(host, &mut caret) }, TermisuHostResult::Success);
        if !caret.pixels.is_null() && done(&caret) {
            let len = (caret.width * caret.height * 4) as usize;
            let pixels = unsafe { std::slice::from_raw_parts(caret.pixels, len) }.to_vec();
            return Some((caret, pixels));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    None
}

/// How many distinct red levels the image holds. A flat block is one; a block with a glyph
/// cut into it is many (the glyph's edges are antialiased).
fn levels(pixels: &[u8]) -> usize {
    let mut seen = [false; 256];
    for pixel in pixels.chunks(4) {
        seen[usize::from(pixel[0])] = true;
    }
    seen.iter().filter(|s| **s).count()
}

#[test]
fn the_sprite_is_the_cursor_cell_with_its_glyph_inverted() {
    // "ab", then the cursor back onto the b.
    let host = spawn_child("printf 'ab\\033[1;2H'; exec sleep 30");
    let found = caret_until(host, |c| c.visible && c.column == 1 && c.row == 0);
    unsafe { termisu_host_free(host) };
    let (caret, pixels) = found.expect("the caret never reported the cell of the b");
    assert!(caret.width > 0 && caret.height > caret.width / 2, "a cell, not {}x{}", caret.width, caret.height);
    assert!(pixels.chunks(4).all(|p| p[3] == 255), "the caret block is opaque");
    assert!(levels(&pixels) > 4, "no glyph in the caret: {} levels", levels(&pixels));
}

#[test]
fn a_caret_on_a_space_is_one_flat_block() {
    // The control for the test above: the same caret on an empty cell has nothing cut into it.
    let host = spawn_child("printf 'ab\\033[1;6H'; exec sleep 30");
    let found = caret_until(host, |c| c.visible && c.column == 5);
    unsafe { termisu_host_free(host) };
    let (_, pixels) = found.expect("the caret never reported the empty cell");
    assert_eq!(levels(&pixels), 1, "a caret on a space should be flat");
}

#[test]
fn the_sprite_follows_the_cursor_and_hides_with_it() {
    let host = spawn_child("printf 'x'; sleep 0.4; printf '\\033[3;7H'; sleep 0.4; printf '\\033[?25l'; exec sleep 30");
    let first = caret_until(host, |c| c.visible && c.column == 1 && c.row == 0).expect("the first position");
    let moved = caret_until(host, |c| c.visible && c.column == 6 && c.row == 2).expect("the caret did not follow");
    let hidden = caret_until(host, |c| !c.visible).expect("the caret did not hide with the cursor");
    unsafe { termisu_host_free(host) };
    assert!(first.0.generation < moved.0.generation && moved.0.generation < hidden.0.generation);
}

/// The polled grid's pixels over the cursor's cell, with the grid's caret on or off.
fn grid_cell(painted: bool) -> (Vec<u8>, [u8; 4]) {
    let host = spawn_child("printf '\\033[1;4H'; exec sleep 30");
    assert_eq!(unsafe { termisu_host_set_caret(host, painted) }, TermisuHostResult::Success);
    let (caret, _) = caret_until(host, |c| c.visible && c.column == 3).expect("cursor at column 3");
    // Settle: the caret switch repaints on the next poll.
    let mut frame = empty_frame();
    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
        if !frame.pixels.is_null() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let len = (frame.width * frame.height * 4) as usize;
    let pixels = unsafe { std::slice::from_raw_parts(frame.pixels, len) }.to_vec();
    let background = frame.background;
    unsafe { termisu_host_free(host) };
    let mut cell = Vec::new();
    for y in 0..caret.height {
        let start = ((y * frame.width + 3 * caret.width) * 4) as usize;
        cell.extend_from_slice(&pixels[start..start + (caret.width * 4) as usize]);
    }
    (cell, background)
}

#[test]
fn the_grid_paints_no_caret_when_the_layer_has_it() {
    let (off, background) = grid_cell(false);
    assert!(
        off.chunks(4).all(|p| p[..3] == background[..3]),
        "the grid painted something on the cursor's cell with its caret off"
    );
    // Control: switched on, the same cell is the block.
    let (on, background) = grid_cell(true);
    assert!(
        on.chunks(4).all(|p| p[..3] != background[..3]),
        "with its caret on, the grid did not paint the block"
    );
}

//! Can an embedder turn a cmd+click on a printed path into the file it names?
//!
//! `paths.rs` has the policy and its truth table over hand-built rows. This asks the C surface
//! the macOS app actually calls, over a grid a real child printed through a pty: a relative
//! path with a line, a path long enough to soft-wrap, an OSC 8 `file://` link and an OSC 8
//! web link. Hand-built rows cannot tell whether the frame's wrap flags, the link table or the
//! OSC 7 decoding reach the policy; only the real grid can.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

use termisu_vt_host::{
    DEFAULT_FONT_SIZE, TERMISU_TEXT_ALL, TermisuHost, TermisuHostCellRun, TermisuHostFrame,
    TermisuHostOptions, TermisuHostResult, termisu_host_free, termisu_host_link_span_at,
    termisu_host_path_at, termisu_host_poll,
    termisu_host_row_text, termisu_host_spawn,
};

const COLS: u16 = 40;
const ROWS: u16 = 8;
const PATIENCE: Duration = Duration::from_secs(10);
/// 45 characters, so printed from column 0 of a 40-column grid it soft-wraps once.
const LONG: &str = "deep/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/long.rs";

fn fixture() -> PathBuf {
    let root = std::env::temp_dir().join(format!("termisu-path-abi-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("src")).expect("src");
    std::fs::create_dir_all(root.join(Path::new(LONG).parent().expect("parent"))).expect("deep");
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").expect("main.rs");
    std::fs::write(root.join(LONG), "\n").expect("long.rs");
    root.canonicalize().expect("canonical fixture")
}

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
    if unsafe { termisu_host_row_text(host, row, TERMISU_TEXT_ALL, ptr::null_mut(), 0, &mut len) }
        != TermisuHostResult::Success
    {
        return String::new();
    }
    let mut buffer = vec![0u8; len];
    unsafe { termisu_host_row_text(host, row, TERMISU_TEXT_ALL, buffer.as_mut_ptr(), len, &mut len) };
    buffer.truncate(len);
    String::from_utf8(buffer).unwrap_or_default()
}

/// Spawns a child that prints the four cases and waits until the last one is on the grid.
fn spawn_printing(root: &Path) -> *mut TermisuHost {
    let main = root.join("src/main.rs");
    let script = format!(
        "printf 'see src/main.rs:3 now\\n{LONG}\\n\\033]8;;file://any-host{}\\033\\\\linked\\033]8;;\\033\\\\\\n\\033]8;;https://example.com/src/main.rs\\033\\\\web\\033]8;;\\033\\\\\\nEND\\n'; sleep 30",
        main.display()
    );
    let command = CString::new(script).expect("command");
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
    assert_eq!(unsafe { termisu_host_spawn(&options, &mut host) }, TermisuHostResult::Success);
    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        let mut frame = empty_frame();
        assert_eq!(unsafe { termisu_host_poll(host, &mut frame) }, TermisuHostResult::Success);
        if frame.generation > 0 && (0..ROWS).any(|row| row_text(host, row).starts_with("END")) {
            return host;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let screen: Vec<String> = (0..ROWS).map(|row| row_text(host, row)).collect();
    panic!("the child never finished printing. The screen held:\n{}", screen.join("\n"));
}

/// The two-call contract: size, then fetch. `None` when no file is there.
fn path_at(host: *mut TermisuHost, col: u16, row: u16, cwd: &str) -> Option<(PathBuf, u32, u32)> {
    let (mut len, mut line, mut column) = (0usize, 0u32, 0u32);
    let raw = cwd.as_bytes();
    let (raw_ptr, raw_len) = if raw.is_empty() { (ptr::null(), 0) } else { (raw.as_ptr(), raw.len()) };
    assert_eq!(
        unsafe {
            termisu_host_path_at(
                host, col, row, raw_ptr, raw_len, ptr::null_mut(), 0, &mut len, &mut line, &mut column,
            )
        },
        TermisuHostResult::Success
    );
    if len == 0 {
        return None;
    }
    let mut buffer = vec![0u8; len];
    assert_eq!(
        unsafe {
            termisu_host_path_at(
                host, col, row, raw_ptr, raw_len, buffer.as_mut_ptr(), len, &mut len, &mut line,
                &mut column,
            )
        },
        TermisuHostResult::Success
    );
    Some((PathBuf::from(String::from_utf8(buffer).expect("utf-8 path")), line, column))
}

#[test]
fn a_click_on_printed_paths_names_the_files_they_are() {
    let root = fixture();
    let host = spawn_printing(&root);
    // The pane's OSC 7 report, raw, exactly as a shell sends it.
    let cwd = format!("file://any-host{}", root.display());
    let main = root.join("src/main.rs");

    // Row 0: "see src/main.rs:3 now", clicked on the 'm' of main.
    assert_eq!(path_at(host, 8, 0, &cwd), Some((main.clone(), 3, 0)));
    // With no OSC 7 report a relative path names nothing, rather than something relative
    // to wherever the app was launched.
    assert_eq!(path_at(host, 8, 0, ""), None);
    // Rows 1 and 2: one path, soft-wrapped; either half is the whole file.
    assert_eq!(path_at(host, 2, 1, &cwd).map(|t| t.0), Some(root.join(LONG)));
    assert_eq!(path_at(host, 2, 2, &cwd).map(|t| t.0), Some(root.join(LONG)));
    // Row 3: an OSC 8 file:// link, whatever its text says and whatever host it names.
    assert_eq!(path_at(host, 2, 3, &cwd), Some((main.clone(), 0, 0)));
    // Row 4: an OSC 8 web link is the embedder's to open as a URL, never a file.
    assert_eq!(path_at(host, 1, 4, &cwd), None);
    // Plain words beside a path are nothing.
    assert_eq!(path_at(host, 1, 0, &cwd), None);

    unsafe { termisu_host_free(host) };
    let _ = std::fs::remove_dir_all(&root);
}

/// The two-call contract for the hover mark: count, then fetch. Runs as (row, start, end).
fn span_at(host: *mut TermisuHost, col: u16, row: u16, cwd: &str) -> Vec<(u16, u16, u16)> {
    let raw = cwd.as_bytes();
    let (raw_ptr, raw_len) = if raw.is_empty() { (ptr::null(), 0) } else { (raw.as_ptr(), raw.len()) };
    let mut count = 0usize;
    assert_eq!(
        unsafe { termisu_host_link_span_at(host, col, row, raw_ptr, raw_len, ptr::null_mut(), 0, &mut count) },
        TermisuHostResult::Success
    );
    let mut runs = vec![TermisuHostCellRun::default(); count];
    assert_eq!(
        unsafe {
            termisu_host_link_span_at(host, col, row, raw_ptr, raw_len, runs.as_mut_ptr(), count, &mut count)
        },
        TermisuHostResult::Success
    );
    runs.iter().map(|r| (r.row, r.start, r.end)).collect()
}

#[test]
fn a_hover_marks_exactly_what_a_click_would_open() {
    let root = fixture();
    let host = spawn_printing(&root);
    let cwd = format!("file://any-host{}", root.display());

    // Row 0: "see src/main.rs:3 now" marks `src/main.rs:3`, not the words around it.
    assert_eq!(span_at(host, 8, 0, &cwd), vec![(0, 4, 17)]);
    // The word beside it is a token that names no file, so it is not marked.
    assert_eq!(span_at(host, 1, 0, &cwd), vec![]);
    // Without OSC 7 the relative path opens nothing, so it is not marked either.
    assert_eq!(span_at(host, 8, 0, ""), vec![]);
    // Rows 1 and 2: the soft-wrapped path is one mark over both rows, from either half.
    let long = vec![(1, 0, COLS), (2, 0, LONG.len() as u16 - COLS)];
    assert_eq!(span_at(host, 2, 1, &cwd), long);
    assert_eq!(span_at(host, 2, 2, &cwd), long);
    // Row 3: the OSC 8 file:// link marks its own text, `linked`.
    assert_eq!(span_at(host, 2, 3, &cwd), vec![(3, 0, 6)]);
    // Row 4: an OSC 8 web link opens as a URL, so it is marked too: `web`.
    assert_eq!(span_at(host, 1, 4, &cwd), vec![(4, 0, 3)]);

    unsafe { termisu_host_free(host) };
    let _ = std::fs::remove_dir_all(&root);
}

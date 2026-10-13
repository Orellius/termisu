//! Tab, end to end: the key event in, the shell's completion out.
//!
//! The maintainer, 2026-08-26: "why doesn't TAB do auto completion?" A terminal does not complete
//! anything -- the SHELL does, and it needs the byte `0x09` to arrive. So the only question a
//! gate can answer is whether the byte gets there, and the only honest way to ask it is to let
//! a real zsh answer: press Tab on a half-typed filename and see the name finish itself.
//!
//! Same chain and same reason as `key_backspace.rs`: `termisu_host_key` -> the encoder -> a
//! real pty -> a real zsh's line editor -> the core -> the grid. Every layer under it has unit
//! tests that pass, which is exactly how a key can go missing and nothing turn red.
//!
//! `KeyMap.swift` maps macOS keyCode 48 to key id 64, so this covers the Swift host's Tab by
//! construction, the way the backspace gate covers keyCode 51.
//!
//! **What the mutants found, and it is a fact about the product rather than about the test.**
//! Tab reaches the child by TWO independent routes and either one alone is enough: the key
//! IDENTITY (`Key::Tab`, which the encoder turns into `0x09` on its own) and the ASSOCIATED
//! TEXT (`\t`, which macOS puts in `NSEvent.characters`). Breaking one leaves the other, so
//! the wrong-key-id mutant passes and the empty-text mutant passes, and neither is a hole in
//! this gate. Breaking BOTH is red, which is what proves the assertion can see anything at
//! all. A gate that demanded one specific route would be asserting an implementation detail
//! the encoder is free to change.

use std::ffi::CString;
use std::path::PathBuf;
use std::ptr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use termisu_vt_host::{
    TermisuHost, TermisuHostFrame, TermisuHostOptions, TermisuHostResult, termisu_host_free,
    termisu_host_key, termisu_host_poll, termisu_host_row_text, termisu_host_send,
    termisu_host_spawn,
};

const COLS: u16 = 80;
const ROWS: u16 = 24;
const PATIENCE: Duration = Duration::from_secs(20);

/// `Key::ALL` is in C declaration order and `termisu_host_key` indexes it, so this is `Key::Tab`.
/// It is also what `KeyMap.swift` maps macOS keyCode 48 onto.
const KEY_TAB: u32 = 64;
const ACTION_PRESS: u32 = 1;

/// The unique stem the shell has to finish. Long and odd on purpose: a short one could be
/// completed by something already in the test's temporary home.
const TARGET: &str = "termisu-tab-target-alpha";

static ENV_LOCK: Mutex<()> = Mutex::new(());

fn quiet_home(tag: &str) -> PathBuf {
    let home = std::env::temp_dir().join(format!("termisu-tab-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&home).expect("temp home");
    std::fs::write(home.join(".zshrc"), "PROMPT='%% '\n").expect("quiet zshrc");
    std::fs::write(home.join(".zprofile"), "").expect("quiet zprofile");
    std::fs::write(home.join(TARGET), "").expect("the completion target");
    home.canonicalize().expect("canonical home")
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

fn row0(host: *mut TermisuHost) -> String {
    let mut polled = empty_frame();
    if unsafe { termisu_host_poll(host, &mut polled) } != TermisuHostResult::Success {
        return String::new();
    }
    let mut len = 0usize;
    if unsafe { termisu_host_row_text(host, 0, 255, ptr::null_mut(), 0, &mut len) }
        != TermisuHostResult::Success
    {
        return String::new();
    }
    let mut buffer = vec![0u8; len];
    if unsafe { termisu_host_row_text(host, 0, 255, buffer.as_mut_ptr(), len, &mut len) }
        != TermisuHostResult::Success
    {
        return String::new();
    }
    String::from_utf8(buffer).unwrap_or_default()
}

fn spawn_quiet_shell(home: &PathBuf) -> *mut TermisuHost {
    let _guard = ENV_LOCK.lock().expect("env lock");
    unsafe {
        std::env::set_var("HOME", home);
        std::env::set_var("ZDOTDIR", home);
        std::env::remove_var("TERMISU_INTEGRATION");
        std::env::remove_var("TERM_PROGRAM");
        std::env::set_var("LC_ALL", "en_US.UTF-8");
        std::env::set_var("LANG", "en_US.UTF-8");
    }
    let command = CString::new(format!("cd {} && exec zsh -i", home.display())).expect("command");
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
    assert_eq!(
        unsafe { termisu_host_spawn(&options, &mut host) },
        TermisuHostResult::Success
    );
    host
}

fn wait_until<F: FnMut(&str) -> bool>(host: *mut TermisuHost, mut done: F, what: &str) -> String {
    let deadline = Instant::now() + PATIENCE;
    let mut seen = String::new();
    while Instant::now() < deadline {
        seen = row0(host);
        if done(&seen) {
            return seen;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("timed out waiting for {what}. Row 0 held: {seen:?}");
}

/// A real Tab PRESS, shaped the way the macOS host sends one: `NSEvent.characters` for this key
/// is `\t`, so the text and the unshifted codepoint are both `0x09`. Passing an empty text would
/// test a key event no host produces.
fn press_tab(host: *mut TermisuHost) {
    let text = [0x09u8];
    assert_eq!(
        unsafe {
            termisu_host_key(
                host,
                ACTION_PRESS,
                KEY_TAB,
                0,
                0,
                text.as_ptr(),
                text.len(),
                0x09,
            )
        },
        TermisuHostResult::Success
    );
}

/// THE GATE. Tab reaches the shell, and the shell completes the name.
#[test]
fn tab_completes_a_filename_in_a_real_shell() {
    let home = quiet_home("complete");
    let host = spawn_quiet_shell(&home);

    wait_until(host, |row| row.starts_with('%'), "the first prompt");
    let stem = b"ls termisu-tab-tar";
    unsafe {
        assert_eq!(
            termisu_host_send(host, stem.as_ptr(), stem.len()),
            TermisuHostResult::Success
        );
    }
    wait_until(
        host,
        |row| row.contains("termisu-tab-tar"),
        "the half-typed name",
    );
    // The stem alone must NOT already read as the target, or the assertion below would pass
    // without Tab having done anything at all.
    assert!(
        !row0(host).contains(TARGET),
        "the stem completed itself before Tab was pressed"
    );

    press_tab(host);
    let settled = wait_until(host, |row| row.contains(TARGET), "the completed name");

    unsafe { termisu_host_free(host) };
    assert!(
        settled.contains(TARGET),
        "Tab did not complete the name. Row 0 held: {settled:?}"
    );
}

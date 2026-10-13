//! The gate for a defect that has now come back three times: a pane that opens at `/`.
//!
//! History, from the repo's own record. Fixed in the C ABI host 2026-07-30 after the operator
//! reported "cannot cd into Desktop" and a pane opening on the sealed read-only root, which
//! starship dresses in a padlock and which reads as a permission block. Never carried across to
//! the second host. Hit again 2026-08-08. Live again 2026-08-11.
//!
//! Three point fixes and no gate is why. `CLAUDE.md` says it outright: "the durable fix is a gate
//! asserting a spawned pane's cwd, not a fourth point fix." This is that gate, and it lives in
//! `crates/host` rather than in either host's own suite BECAUSE the defect's whole shape is that
//! one host was fixed and the other was not. Every host reaches the pty through
//! `termisu_host_spawn`, so an assertion here covers the Swift host, the Tauri host, and whatever
//! replaces them.
//!
//! It asks the child, rather than reading the parent's intent. `Command::current_dir` is what the
//! three point fixes each set correctly at some call site while the live pane still opened
//! somewhere else, so asserting on the `Command` would have passed every time the bug shipped.
//! `pwd` down a real pty is the only answer that cannot be wrong.

use std::ffi::CString;
use std::path::PathBuf;
use std::ptr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use termisu_vt_host::{
    TermisuHost, TermisuHostFrame, TermisuHostOptions, TermisuHostResult, termisu_host_free,
    termisu_host_poll, termisu_host_row_text, termisu_host_send, termisu_host_spawn,
};

const COLS: u16 = 80;
const ROWS: u16 = 24;
const PATIENCE: Duration = Duration::from_secs(20);

/// Child env is process-global at spawn time, so tests that set it serialize here.
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// A quiet HOME: an empty rc, so the prompt is ours and `pwd` output is not buried in a
/// theme. The point of the test is a directory, not a shell configuration.
fn quiet_home(tag: &str) -> PathBuf {
    let home = std::env::temp_dir().join(format!("termisu-cwd-gate-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&home).expect("temp home");
    std::fs::write(home.join(".zshrc"), "PROMPT='> '\n").expect("quiet zshrc");
    std::fs::write(home.join(".zprofile"), "").expect("quiet zprofile");
    // Canonicalised because macOS hands out `/var/...` while the real path is `/private/var/...`,
    // and `pwd` prints the resolved one. Comparing the two forms is a false red that costs an
    // hour the first time and every time somebody forgets.
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

/// Every row of the last polled frame, joined. `row_text` answers from the POLLED frame, so
/// this polls first; before the pump publishes anything it yields an empty string, which reads
/// as "not yet" to the waiter rather than as a wrong answer.
fn screen(host: *mut TermisuHost) -> String {
    let mut polled = empty_frame();
    if unsafe { termisu_host_poll(host, &mut polled) } != TermisuHostResult::Success {
        return String::new();
    }
    let mut out = String::new();
    for row in 0..ROWS {
        let mut len = 0usize;
        if unsafe { termisu_host_row_text(host, row, 255, ptr::null_mut(), 0, &mut len) }
            != TermisuHostResult::Success
        {
            continue;
        }
        let mut buffer = vec![0u8; len];
        if unsafe { termisu_host_row_text(host, row, 255, buffer.as_mut_ptr(), len, &mut len) }
            == TermisuHostResult::Success
            && let Ok(text) = String::from_utf8(buffer)
        {
            out.push_str(&text);
            out.push('\n');
        }
    }
    out
}

/// Spawns the DEFAULT pane - `command: null` - which is the branch every host takes when the
/// operator opens a window and the one all three recurrences were in. An explicit command takes
/// the other branch and keeps the caller's cwd on purpose, so testing that branch here would
/// assert the opposite of the property under test.
fn spawn_default_pane(home: &PathBuf, explicit_cwd: Option<&PathBuf>) -> *mut TermisuHost {
    let _guard = ENV_LOCK.lock().expect("env lock");
    let cwd_string = explicit_cwd.map(|path| CString::new(path.to_str().expect("utf-8 cwd")).expect("cwd"));
    unsafe {
        std::env::set_var("HOME", home);
        std::env::set_var("ZDOTDIR", home);
        std::env::set_var("SHELL", "/bin/zsh");
        std::env::remove_var("TERMISU_INTEGRATION");
        std::env::remove_var("TERMISU_USER_ZDOTDIR");
        // Same reason `shell_integration.rs` scrubs it, measured the same day: `/etc/zshrc:74`
        // sources `/etc/zshrc_$TERM_PROGRAM`, so a suite run from Terminal.app loads Apple's own
        // integration into a shell this test believes it configured alone.
        std::env::remove_var("TERM_PROGRAM");
        // POISONED ON PURPOSE. Every variable the host is supposed to DECLARE is wiped from
        // the parent first, so the only way a child can report one is that `launch::dress`
        // set it. Without this the env gate passes by inheritance whenever the suite happens
        // to run from a terminal that already had the value, which is most of them.
        std::env::remove_var("COLORTERM");
        std::env::remove_var("FORCE_HYPERLINK");
        std::env::set_var("TERM", "dumb");
    }
    let options = TermisuHostOptions {
        cols: COLS,
        rows: ROWS,
        font_size: 0.0,
        command: ptr::null(),
        auto_direction: false,
        config: ptr::null(),
        cwd: cwd_string.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
    };
    let mut host: *mut TermisuHost = ptr::null_mut();
    assert_eq!(
        unsafe { termisu_host_spawn(&options, &mut host) },
        TermisuHostResult::Success
    );
    host
}

/// The same rows with the row breaks removed, for matching rather than for reading.
///
/// A pty WRAPS: at 80 columns a temp-directory path lands as `...termisu-cwd-gate` on one row and
/// `-home-65607]` on the next, and a substring search against the row-broken form finds neither
/// half. Measured on this test's first run, which reported a timeout while the terminal was
/// holding the correct answer in two pieces. Widening the grid would hide the wrap rather than
/// handle it, and a terminal test that only works when nothing wraps is not much of one.
fn joined(host: *mut TermisuHost) -> String {
    screen(host).replace('\n', "")
}

/// Asks the child where it is and waits for the answer to appear on screen.
fn child_reports_cwd(host: *mut TermisuHost, expected: &PathBuf) -> bool {
    let needle = expected.to_str().expect("utf-8 path").to_string();
    // A marker around the answer, because the EXPECTED PATH IS ALSO IN THE PROMPT for most
    // themes and in the shell's own startup noise. Without it this test passes on a pane that
    // opened somewhere else entirely and merely printed the string once.
    unsafe {
        let line = b"printf 'CWDGATE[%s]\\n' \"$PWD\"\r";
        assert_eq!(
            termisu_host_send(host, line.as_ptr(), line.len()),
            TermisuHostResult::Success
        );
    }
    // Not `wait_for`: a bare timeout here says only "nothing appeared", and the four things that
    // can cause that (no shell, no prompt, no echo, wrong row filter) are indistinguishable
    // without the screen. The deadline PRINTS what the terminal actually held.
    // `CWDGATE[/`, not `CWDGATE[`. The command line is ECHOED by the pty, so the literal
    // `CWDGATE[%s]` is on screen before the child has run anything at all - the first version of
    // this waited on the bare marker, matched its own echo, and then declared a timeout while the
    // right answer sat two rows below. Only the expansion begins with a slash.
    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        let seen = joined(host);
        if seen.contains("CWDGATE[/") {
            return seen.contains(&format!("CWDGATE[{needle}]"));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!(
        "the child never reported $PWD. The screen held:\n{}\n(end of screen)",
        screen(host)
    );
}

/// Asks the child what an environment variable HOLDS, and waits for the answer.
///
/// `tests/child_env.rs` asserts the mutations a built `Command` carries and says in its own
/// header that it cannot see what the child ends up with. That limit was covered by
/// `smoke-termisu.sh`, which died with the Tauri crate on 2026-08-11 and whose env half was
/// never rehomed. In the fourteen days after, `build_command` -- the path EVERY ordinary pane
/// takes -- kept hand-rolling `TERM` and never calling `dress`, so every child was told it had
/// no truecolor and `child_env.rs` stayed green throughout. This is the half that died.
///
/// The marker is assembled BY THE SHELL, `ENV%s[%s]` with `GATE` as the first argument, because
/// the pty ECHOES the command line: a literal `ENVGATE[` in the format string would be on
/// screen before the child had run anything, and the first version of the cwd gate below matched
/// exactly that and then declared a timeout.
fn child_reports_env(host: *mut TermisuHost, name: &str, expected: &str) -> bool {
    // COUNT THE MARKERS ALREADY ON SCREEN FIRST, and wait for one MORE.
    //
    // This helper read the first marker it could find until 2026-08-26, which made it
    // single-use per host: ask a second question and the previous answer is still on screen,
    // so it returns that instead. It failed loudly on one new test and, far worse, passed
    // VACUOUSLY on another, where an assertion that a stale value was NOT reported was
    // satisfied by re-reading the very value it was comparing against. Reading the LAST
    // marker instead is not enough either -- the last one is still the previous answer until
    // the new one has actually rendered.
    let already = joined(host).matches("ENVGATE[").count();
    let line = format!("printf 'ENV%s[%s]\\n' GATE \"${name}\"\r");
    unsafe {
        assert_eq!(
            termisu_host_send(host, line.as_ptr(), line.len()),
            TermisuHostResult::Success
        );
    }
    let deadline = Instant::now() + PATIENCE;
    while Instant::now() < deadline {
        let seen = joined(host);
        if seen.matches("ENVGATE[").count() > already
            && let Some((_, after)) = seen.rsplit_once("ENVGATE[")
            && let Some((value, _)) = after.split_once(']')
        {
            return value == expected;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!(
        "the child never reported ${name}. The screen held:\n{}\n(end of screen)",
        screen(host)
    );
}

/// THE ENV GATE. A pane declares truecolor, and it is asked of the CHILD.
///
/// Seen red before it was believed, on 2026-08-26, and it was red for the live reason rather
/// than a contrived one: `claude` in a real pane drew its mascot at 256-colour index 174
/// (`#D78787`, a dusty pink) instead of its own 24-bit coral, because `supports-color` reads
/// `COLORTERM` and there was none. The renderer was never at fault: measured the same hour,
/// `38;2;217;119;87` came back byte-exact and so did every 256-colour index.
#[test]
fn a_pane_tells_its_child_the_terminal_has_truecolor() {
    let home = quiet_home("colorterm");
    let host = spawn_default_pane(&home, None);
    let declared = child_reports_env(host, "COLORTERM", "truecolor");
    unsafe { termisu_host_free(host) };
    assert!(
        declared,
        "a pane must hand its child COLORTERM=truecolor; without it every program that asks \
         falls back to 256 colours in a terminal that has had 24-bit colour since slice 1"
    );
}

/// Hyperlinks, asked the same way. Added 2026-09-29 with the variable itself: the P0
/// measurement had `claude` in a Termisu pane print 0 OSC 8 links without `FORCE_HYPERLINK`
/// and 1 with it, because `supports-hyperlinks` does not recognise this terminal's name.
#[test]
fn a_pane_tells_its_child_the_terminal_renders_hyperlinks() {
    let home = quiet_home("hyperlink");
    let host = spawn_default_pane(&home, None);
    let declared = child_reports_env(host, "FORCE_HYPERLINK", "1");
    unsafe { termisu_host_free(host) };
    assert!(
        declared,
        "a pane must hand its child FORCE_HYPERLINK=1; without it an agent prints every URL as \
         plain text in a terminal that renders OSC 8"
    );
}

/// The terminal type, asked the same way. Set beside `COLORTERM` in `dress` and, until today,
/// the only one of the pair the main spawn path bothered to copy.
#[test]
fn a_pane_tells_its_child_the_terminal_type() {
    let home = quiet_home("term");
    let host = spawn_default_pane(&home, None);
    let declared = child_reports_env(host, "TERM", termisu_vt_host::launch::CHILD_TERM);
    unsafe { termisu_host_free(host) };
    assert!(declared, "a pane must declare TERM={}", termisu_vt_host::launch::CHILD_TERM);
}

/// THE CONTROL for the two above, and it is what stops them being a pair of tests that cannot
/// fail. It proves the reader reports what the child ACTUALLY holds rather than always finding
/// the string it was handed: a name nothing sets must come back EMPTY.
#[test]
fn the_env_reader_can_see_a_variable_that_is_not_set() {
    let home = quiet_home("unset");
    let host = spawn_default_pane(&home, None);
    let empty = child_reports_env(host, "TERMISU_SET_BY_NOBODY", "");
    unsafe { termisu_host_free(host) };
    assert!(
        empty,
        "the reader answered something for a variable nothing sets; it is not reading the child"
    );
}

/// THE GATE. A default pane opens at HOME.
///
/// Seen red before it was believed, on 2026-08-11, by removing the `current_dir(home)` branch
/// from `build_command`: the child then reported `CWDGATE[/]` - the sealed read-only root, which
/// is the exact live symptom, reproduced from a test rather than from an operator's screenshot.
#[test]
fn a_default_pane_opens_at_home() {
    let home = quiet_home("home");
    let host = spawn_default_pane(&home, None);
    let landed = child_reports_cwd(host, &home);
    unsafe { termisu_host_free(host) };
    assert!(
        landed,
        "a default pane must open at $HOME ({}), and this is the fourth time it did not",
        home.display()
    );
}

/// THE CONTROL, and it is the half that makes the gate above mean anything.
///
/// It proves the test observes the CHILD's directory rather than always finding HOME: given an
/// explicit `cwd`, the child must report THAT instead. Without this, `a_default_pane_opens_at_home`
/// would still pass if `child_reports_cwd` were broken into always answering true, and a gate
/// that cannot fail is indistinguishable from one that passes.
#[test]
fn an_explicit_cwd_outranks_the_home_default() {
    let home = quiet_home("override");
    let elsewhere = std::env::temp_dir()
        .join(format!("termisu-cwd-gate-elsewhere-{}", std::process::id()))
        .canonicalize()
        .unwrap_or_else(|_| {
            let path = std::env::temp_dir()
                .join(format!("termisu-cwd-gate-elsewhere-{}", std::process::id()));
            std::fs::create_dir_all(&path).expect("elsewhere");
            path.canonicalize().expect("canonical elsewhere")
        });
    let host = spawn_default_pane(&home, Some(&elsewhere));
    let landed = child_reports_cwd(host, &elsewhere);
    unsafe { termisu_host_free(host) };
    assert!(
        landed,
        "an explicit cwd ({}) must outrank the HOME default ({})",
        elsewhere.display(),
        home.display()
    );
}

/// THE PORT BLOCK GATE. A pane's child is told which ports belong to its workspace.
///
/// Four to eight agents in four to eight worktrees all reach for 3000, and the one that loses
/// dies on `EADDRINUSE` and reports a broken build that is not broken. `launch::seat` hands
/// the block down; this asks the CHILD whether it arrived, for the same reason the cwd gate
/// does. `tests/port_base.rs` proves the arithmetic and says in its own header that it cannot
/// see whether anything reaches a process.
#[test]
fn a_pane_tells_its_child_which_ports_belong_to_its_workspace() {
    let home = quiet_home("ports");
    let expected = termisu_vt_host::launch::port_base(&home).to_string();
    let host = spawn_default_pane(&home, None);
    let carried = child_reports_env(host, "TERMISU_PORT_BASE", &expected);
    let span = child_reports_env(
        host,
        "TERMISU_PORT_SPAN",
        &termisu_vt_host::launch::PORT_SPAN.to_string(),
    );
    unsafe { termisu_host_free(host) };
    assert!(carried, "the child never saw TERMISU_PORT_BASE={expected}");
    assert!(span, "the child never saw TERMISU_PORT_SPAN");
}

/// THE CONTROL that makes the gate above about WORKSPACES rather than about a constant.
///
/// A pane seated somewhere else must report a DIFFERENT block. Without this, hardcoding one
/// number would pass, and one number for every worktree is precisely the collision the whole
/// feature exists to remove.
#[test]
fn a_pane_in_another_workspace_gets_another_block() {
    let home = quiet_home("ports-home");
    let elsewhere = std::env::temp_dir()
        .join(format!("termisu-portgate-{}", std::process::id()));
    std::fs::create_dir_all(&elsewhere).expect("elsewhere");
    let elsewhere = elsewhere.canonicalize().expect("canonical elsewhere");

    let home_base = termisu_vt_host::launch::port_base(&home);
    let other_base = termisu_vt_host::launch::port_base(&elsewhere);
    assert_ne!(
        home_base, other_base,
        "the two fixture directories happen to share a block; pick different ones"
    );

    let host = spawn_default_pane(&home, Some(&elsewhere));
    let carried = child_reports_env(host, "TERMISU_PORT_BASE", &other_base.to_string());
    let stale = child_reports_env(host, "TERMISU_PORT_BASE", &home_base.to_string());
    unsafe { termisu_host_free(host) };
    let _ = std::fs::remove_dir_all(&elsewhere);

    assert!(
        carried,
        "a pane seated in {} did not report its own block {other_base}",
        elsewhere.display()
    );
    assert!(
        !stale,
        "the pane reported the HOME block {home_base} from another workspace; the block is \
         being set before the directory is, so every worktree shares one"
    );
}

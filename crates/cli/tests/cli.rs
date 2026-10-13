//! Runs the built `termisu` binary with pipes on every stream, so it never sees a terminal
//! and falls back to 80 columns unless `-w` is given.

use std::io::Write;
use std::process::{Command, Output, Stdio};

fn termisu(args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_termisu"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn termisu");
    child.stdin.take().expect("stdin").write_all(stdin.as_bytes()).expect("write stdin");
    child.wait_with_output().expect("wait for termisu")
}

fn stdout(out: &Output) -> &str {
    std::str::from_utf8(&out.stdout).expect("utf-8 stdout")
}

const DOC: &str = "# Hi\n\none two three\n";
const DOC_AT_7: &str = "\x1b[1;4;95mHi\x1b[0m\n\none two\nthree\n";

#[test]
fn md_renders_standard_input_at_the_given_width() {
    let out = termisu(&["md", "-w", "7"], DOC);
    assert!(out.status.success(), "{out:?}");
    assert_eq!(stdout(&out), DOC_AT_7);
    assert!(out.stderr.is_empty());
}

#[test]
fn md_renders_a_file_and_a_dash_means_standard_input() {
    let path = std::env::temp_dir().join(format!("termisu-cli-{}.md", std::process::id()));
    std::fs::write(&path, DOC).expect("write doc");
    let from_file = termisu(&["md", "-w", "7", path.to_str().expect("utf-8 path")], "");
    std::fs::remove_file(&path).expect("remove doc");
    assert_eq!(stdout(&from_file), DOC_AT_7);
    assert_eq!(stdout(&termisu(&["md", "--width", "7", "-"], DOC)), DOC_AT_7);
}

#[test]
fn md_without_a_terminal_or_width_wraps_at_80() {
    let words = vec!["word"; 30].join(" ");
    let out = termisu(&["md"], &words);
    let first = stdout(&out).lines().next().expect("a line");
    // Sixteen words are 79 columns; a seventeenth would make 84.
    assert_eq!(first, vec!["word"; 16].join(" "));
}

#[test]
fn a_missing_file_fails_with_its_name() {
    let out = termisu(&["md", "/nonexistent/termisu.md"], "");
    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.starts_with("termisu md: /nonexistent/termisu.md: "), "{err}");
}

#[test]
fn bad_usage_exits_2_with_the_usage() {
    for args in [&[][..], &["mdx"], &["md", "-w", "0"], &["md", "-w"], &["md", "-x"], &["md", "a", "b"]] {
        let out = termisu(args, "");
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(String::from_utf8_lossy(&out.stderr).contains("usage: termisu md"), "{args:?}");
        assert!(out.stdout.is_empty(), "{args:?}");
    }
    let help = termisu(&["md", "--help"], "");
    assert!(help.status.success());
    assert!(stdout(&help).starts_with("usage: termisu md"));
}

#[test]
fn a_reader_that_quits_early_is_not_an_error() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_termisu"))
        .args(["md", "-w", "80"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn termisu");
    // Close the reading end first, then send far more than a pipe buffer holds.
    drop(child.stdout.take());
    let doc = "some words in a paragraph\n\n".repeat(40_000);
    child.stdin.take().expect("stdin").write_all(doc.as_bytes()).expect("write stdin");
    let out = child.wait_with_output().expect("wait for termisu");
    assert!(out.status.success(), "{out:?}");
    assert!(out.stderr.is_empty(), "{}", String::from_utf8_lossy(&out.stderr));
}

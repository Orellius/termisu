//! Purpose: the `termisu` command that ships inside Termisu.app, in Contents/Resources/bin,
//!   which the app appends to PATH for the shells it spawns.
//! Commands: `termisu md [-w COLUMNS] [FILE]` prints a markdown file, or standard input, as
//!   styled terminal text (crates/markdown does the rendering).
//! Width: `-w` wins, then the terminal on stdout, then the terminal on stderr, so
//!   `termisu md README.md | less -R` still wraps to the window, then 80.
//! Test strategy: tests/cli.rs runs the built binary with pipes, so no terminal is involved.

use std::io::{self, Read, Write};
use std::process::ExitCode;

const USAGE: &str = "usage: termisu md [-w COLUMNS] [FILE]

Prints a markdown FILE, or standard input when FILE is missing or -, as styled
terminal text wrapped to the terminal's width, or to COLUMNS with -w.
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("md") => md(&args[1..]),
        Some("-h" | "--help" | "help") => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        _ => {
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn usage_error(message: &str) -> ExitCode {
    eprint!("termisu md: {message}\n\n{USAGE}");
    ExitCode::from(2)
}

fn md(args: &[String]) -> ExitCode {
    let mut width = None;
    let mut file: Option<&str> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                print!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            "-w" | "--width" => {
                i += 1;
                match args.get(i).and_then(|w| w.parse::<usize>().ok()).filter(|w| *w > 0) {
                    Some(w) => width = Some(w),
                    None => return usage_error("-w needs a number of columns above zero"),
                }
            }
            arg if arg.starts_with('-') && arg != "-" => {
                return usage_error(&format!("unknown option {arg}"));
            }
            arg if file.is_none() => file = Some(arg),
            _ => return usage_error("give one FILE at most"),
        }
        i += 1;
    }

    let mut bytes = Vec::new();
    let read = match file {
        None | Some("-") => io::stdin().read_to_end(&mut bytes),
        Some(path) => std::fs::File::open(path).and_then(|mut f| f.read_to_end(&mut bytes)),
    };
    if let Err(e) = read {
        eprintln!("termisu md: {}: {e}", file.unwrap_or("-"));
        return ExitCode::FAILURE;
    }

    let width = width.or_else(terminal_width).unwrap_or(80);
    let out = termisu_markdown::render(&String::from_utf8_lossy(&bytes), width);
    let mut stdout = io::stdout().lock();
    match stdout.write_all(out.as_bytes()).and_then(|()| stdout.flush()) {
        Ok(()) => ExitCode::SUCCESS,
        // A pager or `head` that quit early is not an error.
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("termisu md: {e}");
            ExitCode::FAILURE
        }
    }
}

fn terminal_width() -> Option<usize> {
    [libc::STDOUT_FILENO, libc::STDERR_FILENO].into_iter().find_map(|fd| {
        // SAFETY: TIOCGWINSZ writes one winsize into the struct passed and touches nothing
        // else; on a descriptor that is not a terminal it fails and the struct is ignored.
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        let ok = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0;
        (ok && size.ws_col > 0).then_some(usize::from(size.ws_col))
    })
}

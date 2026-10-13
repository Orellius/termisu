//! Purpose: the file a cmd+click on the grid means, if it means one.
//! Public surface: `Target`, `CellRun`, `token_at`, `span_at`, `split_location`, `resolve`,
//!   `file_link`, `target_at`, `target_span_at`.
//! Why this file: agents print paths as plain text. Claude Code 2.1.283 never links a file
//!   path with OSC 8, only URLs (measured in P0 of the agent workspace plan, 2026-09-29), so
//!   the terminal has to find the path itself. That is a policy with a truth table, and it
//!   lives here, over snapshot rows and the disk, so a test can read it without a window.
//! NOT responsible for: URLs (OSC 8 carries those, and the host opens them), or deciding
//!   where a file is shown (the embedder does: the file panel, or Finder when panels are off).
//! Test strategy: the shapes agents and tools really print (a path in backticks, after
//!   Claude's `⎿`, with `:line:col`, at the end of a sentence, split by a soft wrap, as a
//!   git diff's `a/` side), plus the ones that must NOT resolve.

use std::path::{Path, PathBuf};

use termisu_vt_snapshot::{Row, Wide};

/// A file to show, and where in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// Absolute, symlinks resolved, and a regular file when this was built.
    pub path: PathBuf,
    /// 1-based, when the text named one (`src/main.rs:42`).
    pub line: Option<u32>,
    /// 1-based, when the text named one (`src/main.rs:42:7`).
    pub column: Option<u32>,
}

/// Whether `c` can be part of a path as printed.
///
/// An allowlist rather than a list of delimiters, because the delimiters are open-ended:
/// Claude Code decorates its output with `⎿`, `●` and box drawing, and every new glyph a
/// tool invents would be one more entry to forget. Letters and digits in any script are in,
/// so a Hebrew file name is one token. Spaces are out: a path with a space in it is two
/// tokens here, and resolving either half finds nothing rather than the wrong file.
fn is_path_char(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '/' | '.' | '_' | '-' | '~' | '+' | '@' | ':' | '#' | '%' | '=')
}

/// Trailing characters that end a sentence rather than a path: `see src/main.rs.` and
/// `in src/main.rs:` both mean `src/main.rs`.
fn is_trailing_punctuation(c: char) -> bool {
    matches!(c, '.' | ':' | ',' | ';' | '!' | '?')
}

/// One row's share of a token: cells `start..end` of `row`, end exclusive, a wide glyph's
/// spacer included so a mark under it spans both halves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellRun {
    pub row: u16,
    pub start: u16,
    pub end: u16,
}

/// The candidate text under a cell, or `None` if the cell is not on anything path-like.
///
/// Reads the whole LOGICAL line: rows joined across soft wraps, because an agent's long path
/// wraps at the pane edge and a click on either half means the whole path. The same rule
/// word selection follows.
pub fn token_at(rows: &[Row], col: u16, row: u16) -> Option<String> {
    span_at(rows, col, row).map(|(token, _)| token)
}

/// `token_at`, plus the cells the token covers, one run per row it crosses: what a hover
/// marks so the operator sees exactly what a cmd+click would open before clicking.
pub fn span_at(rows: &[Row], col: u16, row: u16) -> Option<(String, Vec<CellRun>)> {
    let row = usize::from(row);
    let clicked = rows.get(row)?;
    let mut col = usize::from(col);
    if col >= clicked.cells.len() {
        return None;
    }
    // The right half of a wide glyph carries no text; it belongs to the cell before it.
    if clicked.cells[col].wide == Wide::SpacerTail && col > 0 {
        col -= 1;
    }

    let mut first = row;
    while first > 0 && rows[first].wrap_continuation {
        first -= 1;
    }
    let mut last = row;
    while last + 1 < rows.len() && rows[last].wrap {
        last += 1;
    }

    let mut chars: Vec<char> = Vec::new();
    // Where each char sits: (row, first cell, cells it spans). A cell holding a cluster
    // pushes several chars that all name it.
    let mut places: Vec<(usize, usize, usize)> = Vec::new();
    let mut at: Option<usize> = None;
    for (y, line) in rows.iter().enumerate().take(last + 1).skip(first) {
        for (x, cell) in line.cells.iter().enumerate() {
            if matches!(cell.wide, Wide::SpacerTail | Wide::SpacerHead) {
                continue;
            }
            if y == row && x == col {
                at = Some(chars.len());
            }
            let width = if cell.wide == Wide::Wide { 2 } else { 1 };
            if cell.text.is_empty() {
                chars.push(' ');
                places.push((y, x, width));
            } else {
                for c in cell.text.chars() {
                    chars.push(c);
                    places.push((y, x, width));
                }
            }
        }
    }

    let at = at?;
    if !chars.get(at).copied().is_some_and(is_path_char) {
        return None;
    }
    let mut start = at;
    while start > 0 && is_path_char(chars[start - 1]) {
        start -= 1;
    }
    let mut end = at + 1;
    while end < chars.len() && is_path_char(chars[end]) {
        end += 1;
    }
    while end > start && is_trailing_punctuation(chars[end - 1]) {
        end -= 1;
    }
    while start < end && chars[start] == ':' {
        start += 1;
    }
    if start >= end {
        return None;
    }
    let token: String = chars[start..end].iter().collect();
    // A URL is the host's business through OSC 8, and a scheme is never a file.
    if token.contains("://") {
        return None;
    }
    let mut runs: Vec<CellRun> = Vec::new();
    for &(y, x, width) in &places[start..end] {
        let (y, x0, x1) = (y as u16, x as u16, (x + width) as u16);
        match runs.last_mut() {
            Some(run) if run.row == y && x0 <= run.end => run.end = run.end.max(x1),
            _ => runs.push(CellRun { row: y, start: x0, end: x1 }),
        }
    }
    Some((token, runs))
}

/// Splits `path:line` and `path:line:column` off a token. Only digits count, and 0 is not a
/// line, so `a:b` and `a:0` stay whole paths.
pub fn split_location(token: &str) -> (&str, Option<u32>, Option<u32>) {
    fn number(text: &str) -> Option<u32> {
        if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        text.parse::<u32>().ok().filter(|n| *n > 0)
    }
    if let Some((rest, last)) = token.rsplit_once(':')
        && let Some(last) = number(last)
    {
        if let Some((path, middle)) = rest.rsplit_once(':')
            && let Some(line) = number(middle)
            && !path.is_empty()
        {
            return (path, Some(line), Some(last));
        }
        if !rest.is_empty() {
            return (rest, Some(last), None);
        }
    }
    (token, None, None)
}

/// The regular file `candidate` names, or `None`.
///
/// `~/` is the home directory, a leading `/` is absolute, and anything else is relative to
/// the pane's working directory, so with no OSC 7 report only absolute and home paths
/// resolve. A directory, a missing file and a device all answer `None`: the click shows
/// nothing rather than something wrong.
pub fn resolve(candidate: &str, cwd: Option<&Path>, home: Option<&Path>) -> Option<PathBuf> {
    let joined = if let Some(rest) = candidate.strip_prefix("~/") {
        home?.join(rest)
    } else if candidate.starts_with('/') {
        PathBuf::from(candidate)
    } else if candidate.starts_with('~') {
        // `~user/...` names another account's home; not worth a lookup to show a file.
        return None;
    } else {
        cwd?.join(candidate)
    };
    let real = joined.canonicalize().ok()?;
    std::fs::metadata(&real).ok()?.is_file().then_some(real)
}

/// The file an OSC 8 `file://` link names, if it is a regular file on this machine.
///
/// Decoded by `cwd::normalize`, the one `file://` decoder in this workspace. It discards the
/// host, so a link another machine printed resolves only if the same path exists here, and
/// then it names a different file. The same trade the history store makes, stated there.
pub fn file_link(uri: &str) -> Option<Target> {
    if !uri.starts_with("file:") {
        return None;
    }
    let path = crate::cwd::normalize(uri.as_bytes())?;
    let real = PathBuf::from(path).canonicalize().ok()?;
    std::fs::metadata(&real).ok()?.is_file().then(|| Target { path: real, line: None, column: None })
}

/// What a cmd+click at a cell opens, from the text under it.
pub fn target_at(
    rows: &[Row],
    col: u16,
    row: u16,
    cwd: Option<&Path>,
    home: Option<&Path>,
) -> Option<Target> {
    target_span_at(rows, col, row, cwd, home).map(|(target, _)| target)
}

/// `target_at`, plus the cells of the text that named it. Only text that resolves to a file
/// gets runs, so a hover never marks something a click would not open.
pub fn target_span_at(
    rows: &[Row],
    col: u16,
    row: u16,
    cwd: Option<&Path>,
    home: Option<&Path>,
) -> Option<(Target, Vec<CellRun>)> {
    let (token, runs) = span_at(rows, col, row)?;
    let (candidate, line, column) = split_location(&token);
    if let Some(path) = resolve(candidate, cwd, home) {
        return Some((Target { path, line, column }, runs));
    }
    // `git diff` prints both sides as `a/src/main.rs` and `b/src/main.rs`.
    for side in ["a/", "b/"] {
        if let Some(rest) = candidate.strip_prefix(side)
            && let Some(path) = resolve(rest, cwd, home)
        {
            return Some((Target { path, line, column }, runs));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use termisu_vt_snapshot::Cell;

    /// Rows from plain strings, one cell per char; `wrap` marks a soft wrap after that row.
    fn rows(lines: &[(&str, bool)]) -> Vec<Row> {
        let width = lines.iter().map(|(text, _)| text.chars().count()).max().unwrap_or(0);
        let mut out: Vec<Row> = Vec::new();
        for (index, (text, wrap)) in lines.iter().enumerate() {
            let mut cells: Vec<Cell> = text
                .chars()
                .map(|c| Cell { text: c.to_string(), ..Cell::blank() })
                .collect();
            cells.resize_with(width, Cell::blank);
            out.push(Row {
                wrap: *wrap,
                wrap_continuation: index > 0 && lines[index - 1].1,
                semantic_prompt: Default::default(),
                cells,
            });
        }
        out
    }

    fn token(line: &str, col: u16) -> Option<String> {
        token_at(&rows(&[(line, false)]), col, 0)
    }

    #[test]
    fn a_path_in_prose_is_the_whole_path() {
        let line = "Edited src/host/main.rs to fix it";
        assert_eq!(token(line, 10).as_deref(), Some("src/host/main.rs"));
        assert_eq!(token(line, 7).as_deref(), Some("src/host/main.rs"));
        assert_eq!(token(line, 22).as_deref(), Some("src/host/main.rs"));
    }

    #[test]
    fn decoration_and_quotes_are_not_part_of_it() {
        assert_eq!(token("  ⎿  Read crates/core/src/lib.rs", 20).as_deref(), Some("crates/core/src/lib.rs"));
        assert_eq!(token("see `web/src/App.tsx` now", 8).as_deref(), Some("web/src/App.tsx"));
        assert_eq!(token("(docs/a.md)", 3).as_deref(), Some("docs/a.md"));
        assert_eq!(token("\"notes/x.md\",", 4).as_deref(), Some("notes/x.md"));
    }

    #[test]
    fn sentence_punctuation_is_trimmed_but_a_location_is_kept() {
        assert_eq!(token("look at src/main.rs.", 10).as_deref(), Some("src/main.rs"));
        assert_eq!(token("in src/main.rs:", 5).as_deref(), Some("src/main.rs"));
        assert_eq!(token("at src/main.rs:42:7,", 5).as_deref(), Some("src/main.rs:42:7"));
    }

    #[test]
    fn blank_and_symbols_are_nothing() {
        assert_eq!(token("a  b", 1), None);
        assert_eq!(token("⎿ x", 0), None);
        assert_eq!(token("...", 1), None);
    }

    #[test]
    fn a_url_is_left_to_osc_8() {
        assert_eq!(token("go to https://example.com/a.md now", 12), None);
    }

    #[test]
    fn a_hebrew_name_is_one_token() {
        assert_eq!(token("open notes/סיכום.md please", 8).as_deref(), Some("notes/סיכום.md"));
    }

    #[test]
    fn a_soft_wrap_joins_the_two_halves_from_either_side() {
        let grid = rows(&[("see crates/host/s", true), ("rc/paths.rs ok", false)]);
        assert_eq!(token_at(&grid, 6, 0).as_deref(), Some("crates/host/src/paths.rs"));
        assert_eq!(token_at(&grid, 3, 1).as_deref(), Some("crates/host/src/paths.rs"));
        // A HARD line break ends the token.
        let hard = rows(&[("see crates/host/s", false), ("rc/paths.rs ok", false)]);
        assert_eq!(token_at(&hard, 3, 1).as_deref(), Some("rc/paths.rs"));
    }

    #[test]
    fn a_span_covers_exactly_the_token_on_every_row_it_crosses() {
        let run = |row, start, end| CellRun { row, start, end };
        // Sentence punctuation is outside the mark, the location inside it.
        let grid = rows(&[("see src/main.rs:3.", false)]);
        assert_eq!(span_at(&grid, 6, 0).map(|s| s.1), Some(vec![run(0, 4, 17)]));
        // A soft wrap gives one run per row, from either half.
        let wrapped = rows(&[("see crates/host/s", true), ("rc/paths.rs ok", false)]);
        let both = Some(vec![run(0, 4, 17), run(1, 0, 11)]);
        assert_eq!(span_at(&wrapped, 6, 0).map(|s| s.1), both);
        assert_eq!(span_at(&wrapped, 3, 1).map(|s| s.1), both);
        // A wide glyph's run includes its spacer, so a mark spans both halves.
        let mut wide = rows(&[("a 字 b", false)]);
        wide[0].cells[2].wide = Wide::Wide;
        wide[0].cells.insert(3, Cell { wide: Wide::SpacerTail, ..Cell::blank() });
        wide[0].cells.truncate(6);
        assert_eq!(span_at(&wide, 3, 0).map(|s| s.1), Some(vec![run(0, 2, 4)]));
        // A plain word is a token too (resolution decides it is no file); a blank is nothing.
        assert_eq!(span_at(&grid, 2, 0).map(|s| s.1), Some(vec![run(0, 0, 3)]));
        assert_eq!(span_at(&rows(&[("a  b", false)]), 1, 0), None);
    }

    #[test]
    fn the_right_half_of_a_wide_glyph_is_its_left_half() {
        let mut grid = rows(&[("a 字 b", false)]);
        // "字" at col 2 is wide: its spacer takes col 3 and the rest shifts right.
        grid[0].cells[2].wide = Wide::Wide;
        grid[0].cells.insert(3, Cell { wide: Wide::SpacerTail, ..Cell::blank() });
        grid[0].cells.truncate(6);
        assert_eq!(token_at(&grid, 3, 0).as_deref(), Some("字"));
    }

    #[test]
    fn locations_split_only_on_digits() {
        assert_eq!(split_location("src/main.rs:42"), ("src/main.rs", Some(42), None));
        assert_eq!(split_location("src/main.rs:42:7"), ("src/main.rs", Some(42), Some(7)));
        assert_eq!(split_location("src/main.rs"), ("src/main.rs", None, None));
        assert_eq!(split_location("a:b"), ("a:b", None, None));
        assert_eq!(split_location("a:0"), ("a:0", None, None));
        assert_eq!(split_location(":42"), (":42", None, None));
    }

    /// A fixture tree: `<root>/repo/src/main.rs`, `<root>/home/.zshrc`, a directory, and a
    /// symlink out of `repo` to a file beside it.
    fn fixture(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("termisu-paths-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("repo/src")).expect("fixture dirs");
        std::fs::create_dir_all(root.join("home")).expect("fixture home");
        std::fs::write(root.join("repo/src/main.rs"), "fn main() {}\n").expect("main.rs");
        std::fs::write(root.join("home/.zshrc"), "\n").expect(".zshrc");
        std::fs::write(root.join("beside.txt"), "x\n").expect("beside");
        std::os::unix::fs::symlink(root.join("beside.txt"), root.join("repo/link.txt")).expect("link");
        root.canonicalize().expect("canonical fixture")
    }

    #[test]
    fn resolution_is_relative_to_the_pane_and_must_be_a_file() {
        let root = fixture("resolve");
        let repo = root.join("repo");
        let home = root.join("home");
        let main = repo.join("src/main.rs");
        assert_eq!(resolve("src/main.rs", Some(&repo), None), Some(main.clone()));
        assert_eq!(resolve("./src/../src/main.rs", Some(&repo), None), Some(main.clone()));
        assert_eq!(resolve(main.to_str().unwrap(), None, None), Some(main.clone()));
        assert_eq!(resolve("~/.zshrc", None, Some(&home)), Some(home.join(".zshrc")));
        // A symlink resolves to what it names, and what the panel is then asked to show is
        // that real file, so its own root check sees the truth.
        assert_eq!(resolve("link.txt", Some(&repo), None), Some(root.join("beside.txt")));

        assert_eq!(resolve("src", Some(&repo), None), None, "a directory is not a file");
        assert_eq!(resolve("src/missing.rs", Some(&repo), None), None);
        assert_eq!(resolve("src/main.rs", None, None), None, "relative with no cwd");
        assert_eq!(resolve("~/.zshrc", None, None), None, "home path with no home");
        assert_eq!(resolve("~other/.zshrc", Some(&repo), Some(&home)), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_click_resolves_path_line_and_column_and_the_diff_sides() {
        let root = fixture("target");
        let repo = root.join("repo");
        let main = repo.join("src/main.rs");
        let grid = rows(&[("error at src/main.rs:3:9: oops", false)]);
        assert_eq!(
            target_at(&grid, 12, 0, Some(&repo), None),
            Some(Target { path: main.clone(), line: Some(3), column: Some(9) })
        );
        let diff = rows(&[("--- a/src/main.rs", false), ("+++ b/src/main.rs", false)]);
        assert_eq!(target_at(&diff, 8, 0, Some(&repo), None).map(|t| t.path), Some(main.clone()));
        assert_eq!(target_at(&diff, 8, 1, Some(&repo), None).map(|t| t.path), Some(main.clone()));
        let nothing = rows(&[("see src/nope.rs", false)]);
        assert_eq!(target_at(&nothing, 6, 0, Some(&repo), None), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_file_link_is_a_local_regular_file_or_nothing() {
        let root = fixture("link");
        let main = root.join("repo/src/main.rs");
        let uri = format!("file://some-host{}", main.display());
        assert_eq!(file_link(&uri), Some(Target { path: main.clone(), line: None, column: None }));
        assert_eq!(file_link(&format!("file://{}", root.join("repo").display())), None, "a directory");
        assert_eq!(file_link("https://example.com/a.md"), None);
        assert_eq!(file_link("file:///definitely/not/here.rs"), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}

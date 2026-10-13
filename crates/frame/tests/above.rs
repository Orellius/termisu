//! Does the strip above the viewport show the history rows the view has just left?
//!
//! The tab band hides nothing: the pane sits below it. What the maintainer asked for (option 2 of the
//! top blur, 2026-10-02) is the rows that ALREADY scrolled off the top showing blurred behind
//! the glass, so the strip is the history directly above the viewport's top row, newest at
//! the bottom. Each test names text the viewport itself cannot contain, so a strip that
//! republished visible rows, or ignored the offset, fails it.

use termisu_vt_core::Terminal;
use termisu_vt_frame::{AbovePublisher, CLUSTER_BYTES, Frame, ReadOutcome, channel};

fn numbered(cols: u16, rows: u16, lines: usize) -> Terminal {
    let mut terminal = Terminal::with_scrollback(cols, rows, 1000);
    for i in 0..lines {
        if i > 0 {
            terminal.write(b"\r\n");
        }
        terminal.write(format!("line-{i}").as_bytes());
    }
    terminal
}

fn text(frame: &Frame) -> Vec<String> {
    let mut scratch = [0u8; CLUSTER_BYTES];
    (0..frame.rows)
        .map(|y| {
            let mut line = String::new();
            for x in 0..frame.cols {
                let cell = frame.cell(x, y);
                if cell.has_text() {
                    line.push_str(cell.cluster(&mut scratch));
                } else {
                    line.push(' ');
                }
            }
            line.trim_end().to_string()
        })
        .collect()
}

/// Publishes the strip and reads it back; `None` when the publisher declined to publish.
fn strip(terminal: &Terminal, offset: u32, rows: u16) -> Vec<String> {
    let (writer, reader) = channel(16, rows);
    let mut publisher = AbovePublisher::new(writer);
    publisher
        .publish(terminal, offset)
        .expect("fits")
        .expect("a first publish always goes out");
    let mut frame = Frame::new();
    assert!(matches!(reader.read_into(&mut frame), ReadOutcome::Fresh(_)));
    text(&frame)
}

#[test]
fn at_the_live_bottom_the_strip_is_the_newest_history_newest_last() {
    // 20 lines through 4 rows: the grid holds line-16..19, history line-0..15.
    let terminal = numbered(16, 4, 20);
    assert_eq!(strip(&terminal, 0, 3), ["line-13", "line-14", "line-15"]);
}

#[test]
fn scrolled_back_the_strip_is_the_history_above_the_scrolled_top() {
    // Offset 2: the viewport's top row is line-14, so the strip ends at line-13.
    let terminal = numbered(16, 4, 20);
    assert_eq!(strip(&terminal, 2, 3), ["line-11", "line-12", "line-13"]);
}

#[test]
fn a_short_history_is_bottom_aligned_with_blank_rows_above_it() {
    // 5 lines through 4 rows: only line-0 has left the screen.
    let terminal = numbered(16, 4, 5);
    assert_eq!(strip(&terminal, 0, 3), ["", "", "line-0"]);
}

#[test]
fn scrolled_to_the_very_top_there_is_nothing_above() {
    let terminal = numbered(16, 4, 20);
    assert_eq!(strip(&terminal, 16, 3), ["", "", ""]);
}

#[test]
fn the_alternate_screen_has_no_strip_and_says_so() {
    let mut terminal = numbered(16, 4, 20);
    terminal.write(b"\x1b[?1049h");
    let (writer, reader) = channel(16, 3);
    let mut publisher = AbovePublisher::new(writer);
    publisher.publish(&terminal, 0).expect("fits");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);
    assert!(frame.alternate_screen(), "the strip must carry the alt-screen bit");
    assert_eq!(text(&frame), ["", "", ""]);
}

#[test]
fn an_unchanged_history_and_offset_publish_nothing_new() {
    // The strip is only history, so with no row pushed and the view not moved it cannot have
    // changed; republishing it would rerender and reblur for nothing on every keystroke.
    let mut terminal = numbered(16, 4, 20);
    let (writer, _reader) = channel(16, 3);
    let mut publisher = AbovePublisher::new(writer);
    assert!(publisher.publish(&terminal, 0).expect("fits").is_some());
    terminal.write(b"x");
    assert!(publisher.publish(&terminal, 0).expect("fits").is_none());
    terminal.write(b"\r\nmore");
    assert!(publisher.publish(&terminal, 0).expect("fits").is_some(), "a pushed row must republish");
    assert!(publisher.publish(&terminal, 1).expect("fits").is_some(), "a moved view must republish");
}

/// The cursor row of a strip of `rows` rows, from a fresh publish.
fn first_real_row(terminal: &Terminal, offset: u32, rows: u16) -> u16 {
    let (writer, reader) = channel(16, rows);
    let mut publisher = AbovePublisher::new(writer);
    publisher.publish(terminal, offset).expect("fits");
    let mut frame = Frame::new();
    reader.read_into(&mut frame);
    frame.cursor.y
}

#[test]
fn the_cursor_row_is_where_real_history_begins() {
    // Pixel scrolling may only climb into rows that exist, and a blank history row cannot be
    // told from padding by its cells. Full, short, exhausted and alternate-screen strips.
    let terminal = numbered(16, 4, 20);
    assert_eq!(first_real_row(&terminal, 0, 3), 0, "sixteen rows of history fill the strip");
    assert_eq!(first_real_row(&terminal, 14, 3), 1, "two rows above line-14's top");
    assert_eq!(first_real_row(&terminal, 16, 3), 3, "at the very top nothing is above");
    let mut blank_history = Terminal::with_scrollback(16, 4, 1000);
    blank_history.write(b"\r\n\r\n\r\n\r\n\r\n");
    assert_eq!(first_real_row(&blank_history, 0, 3), 1, "two blank rows left the screen and are real");
    let mut alternate = numbered(16, 4, 20);
    alternate.write(b"\x1b[?1049h");
    assert_eq!(first_real_row(&alternate, 0, 3), 3, "the alternate screen has no history");
}

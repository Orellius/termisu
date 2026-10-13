//! Purpose: publish the history rows directly ABOVE the viewport, for the blurred strip
//!   behind the tab band.
//! Public surface: `AbovePublisher`.
//! Why this file: the maintainer's option 2 of the top blur (2026-10-02). The pane sits below the band,
//!   so the band hides nothing; what shows behind the glass is the rows that already scrolled
//!   off the top. They are a second, small frame on their own channel rather than extra rows
//!   in the main one, because every consumer of the main frame (renderer, mouse, selection,
//!   links, the host's canvas tests) assumes row 0 is the viewport's top.
//! NOT responsible for: drawing or blurring the strip (the host crate).
//! Test strategy: `tests/above.rs` scrolls numbered lines through a short screen and checks
//!   the strip holds exactly the rows above the viewport, at the bottom and scrolled back.

use termisu_vt_core::Terminal;

use crate::frame::Frame;
use crate::packed::{PackedCell, pack_style};
use crate::seqlock::{CapacityExceeded, FrameWriter};

/// Everything the strip's content depends on. History rows never change once pushed, so the
/// rows above the viewport can only differ when a row was pushed, history was pruned or
/// reflowed (its length), the view moved, the screen switched or the width changed.
type Key = (u64, usize, usize, bool, u16);

pub struct AbovePublisher {
    writer: FrameWriter,
    last: Option<Key>,
}

impl AbovePublisher {
    pub fn new(writer: FrameWriter) -> AbovePublisher {
        AbovePublisher { writer, last: None }
    }

    /// Publishes the channel's row count of history rows ending just above the viewport's top
    /// row, bottom-aligned, blank where history runs out; the cursor row is the first real one. `Ok(None)` when nothing it depends
    /// on changed since the last publish, so the host neither rerenders nor reblurs.
    ///
    /// Takes the terminal by shared reference on purpose: the strip reports no damage and must
    /// never consume the main frame's.
    pub fn publish(&mut self, terminal: &Terminal, offset: u32) -> Result<Option<u64>, CapacityExceeded> {
        let screen = terminal.screen();
        let grid = &screen.grid;
        let history = &screen.history;
        let cols = grid.cols();
        let (_, rows) = self.writer.capacity();
        let offset = (offset as usize).min(history.len());
        let alternate = terminal.on_alternate_screen();
        let key = (history.total_pushed(), history.len(), offset, alternate, cols);
        if self.last == Some(key) {
            return Ok(None);
        }

        // The viewport's top row is history row `len - offset` (or the grid's top when offset
        // is 0), so the strip is the `count` rows before it.
        let count = usize::from(rows).min(history.len() - offset);
        let above = history.rows_from_end(offset + count, count);
        let blank = usize::from(rows) - above.len();

        // Styles arrive by value, as in a scrolled publish. Entry 0 is the grid's default so
        // a blank cell and a cell past the channel's style ceiling both draw unstyled.
        let mut styles: Vec<[u64; 2]> = grid.styles().as_slice().iter().take(1).map(pack_style).collect();
        let cap = self.writer.style_capacity();
        let mut intern = |packed: [u64; 2]| -> u16 {
            if let Some(index) = styles.iter().position(|entry| *entry == packed) {
                return index as u16;
            }
            if styles.len() >= cap {
                return 0;
            }
            styles.push(packed);
            (styles.len() - 1) as u16
        };

        let mut cells: Vec<(u16, u16, PackedCell)> = Vec::new();
        let mut flags: Vec<(u16, bool, bool)> = Vec::new();
        for (index, row) in above.iter().enumerate() {
            let y = (blank + index) as u16;
            for x in 0..cols {
                if let Some(cell) = row.cells.get(usize::from(x)) {
                    let id = intern(pack_style(&cell.style));
                    cells.push((x, y, PackedCell::new(&cell.text, id, cell.wide, cell.semantic)));
                }
            }
            flags.push((y, row.wrap, row.wrap_continuation));
        }

        let generation = self.writer.publish(cols, rows, |frame| {
            for y in 0..rows {
                for x in 0..cols {
                    frame.cell(x, y, PackedCell::BLANK);
                }
                frame.row_flags(y, false, false);
            }
            for (x, y, cell) in cells {
                frame.cell(x, y, cell);
            }
            for (y, wrap, continuation) in flags {
                frame.row_flags(y, wrap, continuation);
            }
            frame.styles(styles.iter().copied());
            frame.whole_frame_changed();
            frame.modes(if alternate { Frame::MODE_ALTERNATE_SCREEN } else { 0 });
            frame.viewport(offset as u32);
            // The strip has no caret, so its cursor ROW says where real history begins: the
            // rows above it are blank padding. Pixel scrolling (M4) climbs only into rows that
            // exist, and a blank history row looks exactly like padding otherwise.
            frame.cursor(0, blank as u16, false, false, styles[0]);
            frame.links(std::iter::empty::<&str>());
            frame.placements(std::iter::empty());
            frame.virtuals(std::iter::empty());
        })?;
        self.last = Some(key);
        Ok(Some(generation))
    }
}

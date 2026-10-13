//! Purpose: the history rows directly above the viewport, drawn sharp, for pixel scrolling.
//! Public surface: `Lead`, `TermisuHostLead`, `termisu_host_lead`.
//! Why this file: the maintainer's motion slice M4 (2026-10-02), smooth pixel scrolling. The grid only
//!   ever holds whole viewport rows, so a view shifted down by part of a row has a gap at its
//!   top that the grid cannot fill. These are the rows that belong in that gap: the strip's
//!   own channel (`termisu_vt_frame::AbovePublisher`), drawn with the session's font and
//!   palette but NOT blurred. Several rows rather than one, so a trackpad can run ahead of the
//!   pump by a few rows without the gap ever showing blank.
//!   The strip draws the same rows before it blurs them, so it takes them from here rather than
//!   reading and drawing the channel a second time (step 2 of the render speed work, 2026-10-02).
//! NOT responsible for: the offset, the snap, or where the image goes (Swift).
//! Test strategy: `tests/lead.rs` spawns children through the C surface: rows that left the
//!   top must arrive sharp at the bottom of the image, report how many of them are real, and
//!   follow the viewport when it scrolls.

use termisu_vt_frame::{Frame, ReadOutcome};
use termisu_vt_pty::Host;
use termisu_vt_render::{FontStack, Palette, Renderer};

use crate::TermisuHost;

/// Mirrors `TermisuHostLead` in `termisu_host.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TermisuHostLead {
    /// RGBA, `width * height * 4` bytes: `rows` history rows ending just above the viewport's
    /// top row, newest at the bottom. Borrowed until the next `termisu_host_lead`, resize, font
    /// change or free. NULL before the first.
    pub pixels: *const u8,
    pub width: u32,
    pub height: u32,
    pub rows: u16,
    /// How many of the bottom rows are real history; the rest above them are blank padding.
    pub above: u16,
    /// The viewport offset these rows sit above. A GUI pairs them with a grid frame of the
    /// same offset only, because the two channels are read one after the other.
    pub viewport: u32,
    /// Rises whenever the pixels or the counts changed.
    pub generation: u64,
}

pub struct Lead {
    above: Frame,
    renderer: Option<Renderer>,
    /// The geometry and font the renderer was made for; any change redraws.
    built_for: (u16, u16, u32, Option<String>, bool),
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    rows: u16,
    real: u16,
    viewport: u32,
    generation: u64,
}

impl Lead {
    pub fn new() -> Lead {
        Lead {
            above: Frame::new(),
            renderer: None,
            built_for: (0, 0, 0, None, false),
            pixels: Vec::new(),
            width: 0,
            height: 0,
            rows: 0,
            real: 0,
            viewport: 0,
            generation: 0,
        }
    }

    /// Reads the latest rows above the viewport and redraws when they or the font changed.
    /// Returns whether anything the GUI sees changed.
    pub fn refresh(
        &mut self,
        host: &Host,
        font_size: f32,
        family: Option<&str>,
        ligatures: bool,
        palette: &Palette,
    ) -> bool {
        let fresh = matches!(host.read_above(&mut self.above), ReadOutcome::Fresh(_));
        if !self.above.is_valid() || self.above.cols == 0 || self.above.rows == 0 {
            return false;
        }
        let built_for = (
            self.above.cols,
            self.above.rows,
            font_size.to_bits(),
            family.map(str::to_owned),
            ligatures,
        );
        let rebuild = self.renderer.is_none() || self.built_for != built_for;
        if !(fresh || rebuild) {
            return false;
        }
        if rebuild {
            let Ok(fonts) = FontStack::with_primary(family, font_size) else {
                return false;
            };
            let mut renderer = Renderer::new(fonts, self.above.cols, self.above.rows);
            renderer.set_palette(palette.clone());
            renderer.set_ligatures(ligatures);
            self.renderer = Some(renderer);
            self.built_for = built_for;
        }
        let Some(renderer) = self.renderer.as_mut() else {
            return false;
        };
        renderer.draw_all(&self.above);
        let cell = renderer.cell_metrics();
        self.pixels = renderer.pixels();
        self.width = cell.width * u32::from(self.above.cols);
        self.height = cell.height * u32::from(self.above.rows);
        self.rows = self.above.rows;
        // The strip publishes its first real row as the cursor row (see `AbovePublisher`).
        self.real = self.above.rows.saturating_sub(self.above.cursor.y);
        self.viewport = self.above.viewport;
        self.generation += 1;
        true
    }

    /// The drawn rows, `width * height * 4` bytes, for the strip to blur.
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    /// Pixel width of `pixels`.
    pub fn width(&self) -> u32 {
        self.width
    }

    /// Rows in `pixels`, zero before the first draw.
    pub fn rows(&self) -> u16 {
        self.rows
    }

    /// Rises with every draw.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Whether the rows were read from the alternate screen, which keeps no history.
    pub fn alternate_screen(&self) -> bool {
        self.above.alternate_screen()
    }

    fn report(&self) -> TermisuHostLead {
        TermisuHostLead {
            pixels: if self.pixels.is_empty() { std::ptr::null() } else { self.pixels.as_ptr() },
            width: self.width,
            height: self.height,
            rows: self.rows,
            above: self.real,
            viewport: self.viewport,
            generation: self.generation,
        }
    }
}

impl Default for Lead {
    fn default() -> Lead {
        Lead::new()
    }
}

/// Fills `out` with the sharp rows above the viewport. Redraws only when they or the font
/// changed.
///
/// # Safety
/// `host` must be a live handle from `termisu_host_spawn`, `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn termisu_host_lead(
    host: *mut TermisuHost,
    out: *mut TermisuHostLead,
) -> crate::TermisuHostResult {
    if host.is_null() || out.is_null() {
        return crate::TermisuHostResult::InvalidValue;
    }
    let host = unsafe { &mut *host };
    host.lead.refresh(
        &host.host,
        host.font_size,
        host.font_family.as_deref(),
        host.ligatures,
        &host.palette,
    );
    unsafe { out.write(host.lead.report()) };
    crate::TermisuHostResult::Success
}

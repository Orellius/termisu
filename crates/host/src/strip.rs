//! Purpose: the blurred strip that shows behind the tab band and fades into the text below it.
//! Public surface: `Strip`, `TermisuHostStrip`, `termisu_host_strip`.
//! Why this file: the maintainer's option 2 of the top blur (2026-10-02). The pump publishes the rows
//!   directly above the viewport on their own channel (`termisu_vt_frame::AbovePublisher`);
//!   this takes them as the lead already drew them (`crate::lead`, so they are drawn once),
//!   adds the viewport's own top rows, blurs the whole column and hands the pixels to the GUI.
//!
//!   The viewport's top rows are in the strip because of Nodee, the reference he named ("פייד
//!   שלא יחתוך את זה ככה ... כמו שעשינו ב Nodee"). Nodee's veil blurs whatever sits under it and
//!   fades its own mask out over the text below, so there is no line where blur meets sharp
//!   text. A strip that stopped at row 0 could only meet the first row with an edge; one that
//!   carries the first rows too lets the GUI fade the blurred copy out over the sharp originals.
//!   The main frame, its canvas and every row-0 assumption downstream of it stay untouched.
//! NOT responsible for: choosing the rows (frame crate), the fade, the tint, or where the strip
//!   goes (Swift).
//! Test strategy: `tests/strip.rs` spawns children through the C surface: text that scrolled
//!   off the top must arrive softened, and the viewport's first row must be in the strip.

use termisu_vt_frame::Frame;
use termisu_vt_pty::Host;
use termisu_vt_render::{FontStack, Palette, Renderer};

use crate::lead::Lead;
use crate::TermisuHost;

/// Viewport rows carried under the history rows. Nodee's veil reaches 36pt below its island,
/// which is under two rows at the default size; three keep that true down to a 12pt cell.
pub const OVERLAP_ROWS: u16 = 3;

/// Mirrors `TermisuHostStrip` in `termisu_host.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TermisuHostStrip {
    /// RGBA, `width * height * 4` bytes: the history rows above the viewport, then the
    /// viewport's first `overlap` pixel rows, blurred as one image. Borrowed until the next
    /// `termisu_host_strip`, resize, font change or free. NULL before the first strip.
    pub pixels: *const u8,
    pub width: u32,
    pub height: u32,
    /// How many of the bottom pixel rows are the viewport's own top rows, so the GUI can lay
    /// them exactly over the originals.
    pub overlap: u32,
    /// Rises whenever the pixels changed, so a GUI rebuilds its image only then.
    pub generation: u64,
    /// The alternate screen keeps no history, so nothing is above its viewport.
    pub alternate_screen: bool,
}

pub struct Strip {
    overlap_renderer: Option<Renderer>,
    /// The width, font and blur the renderer and pixels were made for; any change redraws.
    built_for: (u16, u32, u32),
    /// The lead generation the history rows were last taken from.
    lead_drawn: u64,
    /// The main frame generation the overlap rows were last drawn from.
    overlap_drawn: u64,
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    overlap: u32,
    generation: u64,
    alternate_screen: bool,
}

impl Strip {
    pub fn new() -> Strip {
        Strip {
            overlap_renderer: None,
            built_for: (0, 0, 0),
            lead_drawn: 0,
            overlap_drawn: 0,
            pixels: Vec::new(),
            width: 0,
            height: 0,
            overlap: 0,
            generation: 0,
            alternate_screen: false,
        }
    }

    /// Brings the lead's rows above the viewport up to date and redraws when they, the
    /// viewport's top rows or the blur changed. Returns whether the pixels changed.
    #[allow(clippy::too_many_arguments)]
    pub fn refresh(
        &mut self,
        host: &Host,
        lead: &mut Lead,
        main: &Frame,
        font_size: f32,
        family: Option<&str>,
        ligatures: bool,
        palette: &Palette,
        radius: u32,
    ) -> bool {
        lead.refresh(host, font_size, family, ligatures, palette);
        if lead.rows() == 0 || lead.width() == 0 || !main.is_valid() || main.cols == 0 {
            return false;
        }
        let fresh = lead.generation() != self.lead_drawn;
        let built_for = (main.cols, font_size.to_bits(), radius);
        let rebuild = self.overlap_renderer.is_none() || self.built_for != built_for;
        let overlap_stale = (0..OVERLAP_ROWS.min(main.rows)).any(|y| main.row_is_stale(y, self.overlap_drawn))
            || main.generation < self.overlap_drawn;
        if !(fresh || rebuild || overlap_stale) {
            return false;
        }
        if rebuild {
            let Ok(fonts) = FontStack::with_primary(family, font_size) else {
                return false;
            };
            let mut renderer = Renderer::new(fonts, main.cols, OVERLAP_ROWS);
            renderer.set_palette(palette.clone());
            renderer.set_ligatures(ligatures);
            self.overlap_renderer = Some(renderer);
            self.built_for = built_for;
        }
        let Some(overlap) = self.overlap_renderer.as_mut() else {
            return false;
        };
        // A renderer OVERLAP_ROWS tall fed the whole main frame draws exactly its top rows:
        // `draw_all` stops at the renderer's own row count.
        overlap.draw_all(main);

        let cell = overlap.cell_metrics();
        let above_width = lead.width();
        let width = above_width.max(cell.width * u32::from(main.cols));
        let above_height = cell.height * u32::from(lead.rows());
        let overlap_height = cell.height * u32::from(OVERLAP_ROWS);
        let mut pixels = vec![0u8; (width * (above_height + overlap_height) * 4) as usize];
        // Two canvases stacked into one column, so the blur runs across the seam between the
        // last history row and the first viewport row exactly as it runs between any two rows.
        for (source, source_width, top) in [
            (lead.pixels(), above_width, 0),
            (&overlap.pixels()[..], cell.width * u32::from(main.cols), above_height),
        ] {
            let row_bytes = (source_width.min(width) * 4) as usize;
            for (y, line) in source.chunks((source_width * 4) as usize).enumerate() {
                let at = ((top + y as u32) * width * 4) as usize;
                if let Some(target) = pixels.get_mut(at..at + row_bytes) {
                    target.copy_from_slice(&line[..row_bytes]);
                }
            }
        }
        let height = above_height + overlap_height;
        termisu_vt_render::blur(&mut pixels, width as usize, height as usize, radius as usize);

        self.pixels = pixels;
        self.width = width;
        self.height = height;
        self.overlap = overlap_height;
        self.overlap_drawn = main.generation;
        self.lead_drawn = lead.generation();
        self.alternate_screen = lead.alternate_screen();
        self.generation += 1;
        true
    }

    fn report(&self) -> TermisuHostStrip {
        TermisuHostStrip {
            pixels: if self.pixels.is_empty() { std::ptr::null() } else { self.pixels.as_ptr() },
            width: self.width,
            height: self.height,
            overlap: self.overlap,
            generation: self.generation,
            alternate_screen: self.alternate_screen,
        }
    }
}

impl Default for Strip {
    fn default() -> Strip {
        Strip::new()
    }
}

/// Fills `out` with the strip: the history rows above the viewport and the viewport's own top
/// rows, blurred with a box blur of `radius` pixels (three passes, close to a Gaussian of that
/// standard deviation). Redraws only when something it shows changed.
///
/// # Safety
/// `host` must be a live handle from `termisu_host_spawn`, `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn termisu_host_strip(
    host: *mut TermisuHost,
    radius: u32,
    out: *mut TermisuHostStrip,
) -> crate::TermisuHostResult {
    if host.is_null() || out.is_null() {
        return crate::TermisuHostResult::InvalidValue;
    }
    let host = unsafe { &mut *host };
    host.strip.refresh(
        &host.host,
        &mut host.lead,
        &host.frame,
        host.font_size,
        host.font_family.as_deref(),
        host.ligatures,
        &host.palette,
        radius,
    );
    unsafe { out.write(host.strip.report()) };
    crate::TermisuHostResult::Success
}

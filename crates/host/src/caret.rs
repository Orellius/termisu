//! Purpose: the caret as a layer the GUI can move, instead of pixels baked into the grid.
//! Public surface: `Caret`, `TermisuHostCaret`, `termisu_host_caret`, `termisu_host_set_caret`.
//! Why this file: the maintainer's motion slice M3 (2026-10-02), a live caret that glides between cells
//!   and blinks softly. A caret painted into the grid can only jump, and only when its row is
//!   repainted. So the grid renderer stops painting it, and a one-cell CPU renderer paints the
//!   same caret (the renderer's own `paint_caret`, so the colours and the inverted glyph are
//!   exact) for the GUI to place, slide and fade on its own layer.
//! NOT responsible for: the glide, the blink, or where the layer sits (Swift).
//! Test strategy: `tests/caret.rs` spawns children through the C surface: the sprite must sit
//!   where the cursor is, carry the cell's glyph, follow the cursor, and vanish when the child
//!   hides it; with the grid's caret off, the grid must not paint one.

use termisu_vt_frame::Frame;
use termisu_vt_render::{FontStack, Palette, Renderer};

use crate::TermisuHost;

/// Mirrors `TermisuHostCaret` in `termisu_host.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TermisuHostCaret {
    /// RGBA, `width * height * 4` bytes: one cell, the caret block with its glyph. Borrowed
    /// until the next `termisu_host_caret`, resize, font change or free. NULL before the first.
    pub pixels: *const u8,
    pub width: u32,
    pub height: u32,
    /// The cell the caret is on, visual column and viewport row.
    pub column: u16,
    pub row: u16,
    /// False when the child hid the cursor or it is off the grid; the pixels are then stale.
    pub visible: bool,
    /// Rises whenever anything above changed, so a GUI rebuilds its image only then.
    pub generation: u64,
}

pub struct Caret {
    renderer: Option<Renderer>,
    /// The font the renderer was made for; a zoom rebuilds it.
    built_for: (u32, Option<String>, bool),
    /// The main frame generation last drawn from.
    drawn: u64,
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    column: u16,
    row: u16,
    visible: bool,
    generation: u64,
}

impl Caret {
    pub fn new() -> Caret {
        Caret {
            renderer: None,
            built_for: (0, None, false),
            drawn: 0,
            pixels: Vec::new(),
            width: 0,
            height: 0,
            column: 0,
            row: 0,
            visible: false,
            generation: 0,
        }
    }

    /// Redraws the caret when the frame moved on or the font changed. Returns whether
    /// anything the GUI sees changed.
    pub fn refresh(
        &mut self,
        main: &Frame,
        font_size: f32,
        family: Option<&str>,
        ligatures: bool,
        palette: &Palette,
    ) -> bool {
        if !main.is_valid() || main.cols == 0 {
            return false;
        }
        let built_for = (font_size.to_bits(), family.map(str::to_owned), ligatures);
        let rebuild = self.renderer.is_none() || self.built_for != built_for;
        if !rebuild && main.generation == self.drawn {
            return false;
        }
        if rebuild {
            let Ok(fonts) = FontStack::with_primary(family, font_size) else {
                return false;
            };
            let mut renderer = Renderer::new(fonts, 1, 1);
            renderer.set_palette(palette.clone());
            renderer.set_ligatures(ligatures);
            self.renderer = Some(renderer);
            self.built_for = built_for;
        }
        let Some(renderer) = self.renderer.as_mut() else {
            return false;
        };
        self.drawn = main.generation;
        let place = renderer.draw_caret_sprite(main);
        let cell = renderer.cell_metrics();
        let pixels = renderer.pixels();
        let (column, row) = place.unwrap_or((self.column, self.row));
        let changed = rebuild
            || place.is_some() != self.visible
            || (column, row) != (self.column, self.row)
            || pixels != self.pixels;
        if !changed {
            return false;
        }
        self.pixels = pixels;
        self.width = cell.width;
        self.height = cell.height;
        self.column = column;
        self.row = row;
        self.visible = place.is_some();
        self.generation += 1;
        true
    }

    fn report(&self) -> TermisuHostCaret {
        TermisuHostCaret {
            pixels: if self.pixels.is_empty() { std::ptr::null() } else { self.pixels.as_ptr() },
            width: self.width,
            height: self.height,
            column: self.column,
            row: self.row,
            visible: self.visible,
            generation: self.generation,
        }
    }
}

impl Default for Caret {
    fn default() -> Caret {
        Caret::new()
    }
}

/// Fills `out` with the caret: its one-cell image and the cell it belongs on, from the frame
/// the last poll read. Redraws only when the frame or the font changed.
///
/// # Safety
/// `host` must be a live handle from `termisu_host_spawn`, `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn termisu_host_caret(
    host: *mut TermisuHost,
    out: *mut TermisuHostCaret,
) -> crate::TermisuHostResult {
    if host.is_null() || out.is_null() {
        return crate::TermisuHostResult::InvalidValue;
    }
    let host = unsafe { &mut *host };
    host.caret.refresh(
        &host.frame,
        host.font_size,
        host.font_family.as_deref(),
        host.ligatures,
        &host.palette,
    );
    unsafe { out.write(host.caret.report()) };
    crate::TermisuHostResult::Success
}

/// Whether the grid paints its own caret. Off for an embedder that draws the caret from
/// `termisu_host_caret`. Everything is repainted on the next poll, so the old caret pixels
/// never linger in a row nobody touches.
///
/// # Safety
/// `host` must be a live handle from `termisu_host_spawn`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn termisu_host_set_caret(
    host: *mut TermisuHost,
    painted: bool,
) -> crate::TermisuHostResult {
    if host.is_null() {
        return crate::TermisuHostResult::InvalidValue;
    }
    let host = unsafe { &mut *host };
    if host.caret_painted != painted {
        host.caret_painted = painted;
        host.renderer.set_caret(painted);
        host.drawn_generation = 0;
    }
    crate::TermisuHostResult::Success
}

//! Purpose: the boundary a rendering backend sits behind.
//! Public surface: `Surface`, and `TruncatingSurface`, which is a test control.
//! Why this file: slice 7 adds a second backend, and a second backend is only safe if the
//!   first one can be used to check it. Reducing a backend to four operations is what makes
//!   "the GPU agrees with the CPU" a statement about bytes rather than about intent -- the
//!   two paths share the atlas, the run-to-column mapping and the damage logic, so the only
//!   place they can disagree is here.
//! NOT responsible for: deciding what to paint (`renderer.rs`) or how a pixel is stored
//!   (`canvas.rs` for the CPU reference).
//! Test strategy: `tests/backend.rs` renders identical frames through two surfaces and
//!   requires byte-identical output, with `TruncatingSurface` proving that comparison fails
//!   when a backend is wrong.

use crate::canvas::Canvas;
use crate::color::Rgba;
use crate::gamma::{self, Blending};

/// Somewhere a frame can be painted.
///
/// Deliberately four operations and no more. Every backend-agnostic decision -- which rows
/// are stale, which column a run occupies, which glyph a cluster needs -- has already been
/// made by the time anything here is called.
///
/// **The blend is specified, not left to the backend.** `blend_mask` must compute
/// `(source * alpha + destination * (255 - alpha) + 127) / 255` in integer arithmetic, per
/// channel, and leave alpha at 255. A backend that blends in floating point and rounds
/// differently is not a rounding detail away from correct; it is a different renderer, and
/// the differential test exists to say so.
pub trait Surface {
    /// Which colour space this surface blends coverage in.
    ///
    /// On the trait rather than on each backend because `tests/backend.rs` has to be able to
    /// put two backends in the SAME mode before demanding they agree, and a mode that only one
    /// of them knows about is a differential with a hole in it.
    fn set_blending(&mut self, blending: Blending);

    /// Creates a surface of the given pixel size, cleared to transparent black.
    fn with_size(width: u32, height: u32) -> Self
    where
        Self: Sized;

    fn width(&self) -> u32;

    fn height(&self) -> u32;

    /// Paints a solid rectangle, clipped to the surface.
    fn fill(&mut self, x: i32, y: i32, width: u32, height: u32, color: Rgba);

    /// Blends `color` over the surface through an 8-bit coverage mask, clipped.
    fn blend_mask(
        &mut self,
        x: i32,
        y: i32,
        mask_width: u32,
        mask_height: u32,
        coverage: &[u8],
        color: Rgba,
    );

    /// Blends a straight-RGBA image over the surface, its own alpha as coverage, clipped.
    ///
    /// The color-glyph path (emoji). Same per-channel expression as `blend_mask` with the
    /// source color coming from the image instead of a uniform -- one blend spec, so the
    /// backend differential covers both.
    fn blend_image(&mut self, x: i32, y: i32, width: u32, height: u32, rgba: &[u8]);

    /// The finished pixels: straight RGBA, row-major, top-down.
    ///
    /// Returns owned bytes rather than a borrow because a GPU backend has to read them back,
    /// and a trait that could only be implemented by something holding a CPU buffer would
    /// have quietly decided slice 7's outcome.
    ///
    /// Takes `&mut self` because reading is where a deferred backend does its work and
    /// retires what it has already done. A shared borrow forced the GPU surface to keep every
    /// operation it had ever recorded, since it could never clear them.
    fn read_pixels(&mut self) -> Vec<u8>;
}

impl Surface for Canvas {
    fn set_blending(&mut self, blending: Blending) {
        Canvas::set_blending(self, blending);
    }

    fn with_size(width: u32, height: u32) -> Canvas {
        Canvas::new(width, height)
    }

    fn width(&self) -> u32 {
        Canvas::width(self)
    }

    fn height(&self) -> u32 {
        Canvas::height(self)
    }

    fn fill(&mut self, x: i32, y: i32, width: u32, height: u32, color: Rgba) {
        Canvas::fill(self, x, y, width, height, color)
    }

    fn blend_mask(
        &mut self,
        x: i32,
        y: i32,
        mask_width: u32,
        mask_height: u32,
        coverage: &[u8],
        color: Rgba,
    ) {
        Canvas::blend_mask(self, x, y, mask_width, mask_height, coverage, color)
    }

    fn blend_image(&mut self, x: i32, y: i32, width: u32, height: u32, rgba: &[u8]) {
        Canvas::blend_image(self, x, y, width, height, rgba)
    }

    fn read_pixels(&mut self) -> Vec<u8> {
        Canvas::pixels(self).to_vec()
    }
}

/// A backend that truncates the blend instead of rounding it.
///
/// A control, not a feature, and wrong in the most plausible way a real backend goes wrong:
/// dropping the `+ 127` is what you get from a shader that computes in floats and lets the
/// hardware round toward zero. The error is at most one unit per channel and invisible to a
/// human, which is exactly why a comparison that has never been seen to fail cannot be
/// trusted to catch it. It has no legitimate caller.
///
/// **It blends in LINEAR light, exactly as the reference does.** That is not cosmetic. When
/// the reference moved to linear blending this control was briefly left in encoded space, and
/// it went on "passing" while measuring the wrong thing: the two backends then differed by up
/// to 65 units, so the comparison was being proven against an error a human could see, not
/// against the sub-perceptual one it exists to catch. A control that is wrong in a BIGGER way
/// than the defect it stands in for is not evidence.
///
/// The one unit is now a unit of LINEAR, and the reverse table absorbs most of them -- which
/// is itself a robustness gain, and the reason `a_backend_that_truncates_the_blend_is_caught`
/// asserts that some byte still differs rather than assuming it.
#[doc(hidden)]
#[derive(Debug, Clone)]
pub struct TruncatingSurface {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
    blending: Blending,
}

impl TruncatingSurface {
    fn offset(&self, x: i32, y: i32) -> Option<usize> {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            return None;
        }
        Some(((y as u32 * self.width + x as u32) * 4) as usize)
    }
}

impl Surface for TruncatingSurface {
    fn set_blending(&mut self, blending: Blending) {
        self.blending = blending;
    }

    fn with_size(width: u32, height: u32) -> TruncatingSurface {
        TruncatingSurface {
            width,
            height,
            pixels: vec![0; (width as usize) * (height as usize) * 4],
            blending: Blending::default(),
        }
    }

    fn width(&self) -> u32 {
        self.width
    }

    fn height(&self) -> u32 {
        self.height
    }

    fn fill(&mut self, x: i32, y: i32, width: u32, height: u32, color: Rgba) {
        for row in 0..height as i32 {
            for column in 0..width as i32 {
                if let Some(base) = self.offset(x + column, y + row) {
                    self.pixels[base..base + 4].copy_from_slice(&color);
                }
            }
        }
    }

    fn blend_mask(
        &mut self,
        x: i32,
        y: i32,
        mask_width: u32,
        mask_height: u32,
        coverage: &[u8],
        color: Rgba,
    ) {
        for row in 0..mask_height {
            for column in 0..mask_width {
                let alpha = coverage[(row * mask_width + column) as usize];
                if alpha == 0 {
                    continue;
                }
                let Some(base) = self.offset(x + column as i32, y + row as i32) else {
                    continue;
                };
                if alpha == u8::MAX {
                    self.pixels[base..base + 4].copy_from_slice(&color);
                    continue;
                }
                truncated_blend(self.blending, color, &mut self.pixels[base..base + 3], alpha);
                self.pixels[base + 3] = 255;
            }
        }
    }

    fn blend_image(&mut self, x: i32, y: i32, width: u32, height: u32, rgba: &[u8]) {
        // The same deliberate truncation as blend_mask, applied to the image path, so the
        // backend differential can be shown to fail for images too.
        for row in 0..height {
            for column in 0..width {
                let source_base = ((row * width + column) * 4) as usize;
                let alpha = u32::from(rgba[source_base + 3]);
                if alpha == 0 {
                    continue;
                }
                let Some(base) = self.offset(x + column as i32, y + row as i32) else {
                    continue;
                };
                if alpha == 255 {
                    self.pixels[base..base + 3].copy_from_slice(&rgba[source_base..source_base + 3]);
                    self.pixels[base + 3] = 255;
                    continue;
                }
                let source = [
                    rgba[source_base],
                    rgba[source_base + 1],
                    rgba[source_base + 2],
                    rgba[source_base + 3],
                ];
                truncated_blend(
                    self.blending,
                    source,
                    &mut self.pixels[base..base + 3],
                    alpha as u8,
                );
                self.pixels[base + 3] = 255;
            }
        }
    }

    fn read_pixels(&mut self) -> Vec<u8> {
        self.pixels.clone()
    }
}

/// `gamma::blend_pixel` with the rounding term removed, in whichever space `mode` names.
///
/// Kept beside the control rather than inside `gamma.rs`, because it is a deliberate defect and
/// a defect does not belong in the module that defines correct. It tracks the real spec mode
/// for mode: a control that blends in a different colour space from the reference stands in for
/// the wrong error entirely, which is how this file went briefly wrong on 2026-08-25.
fn truncated_blend(mode: Blending, source: Rgba, destination: &mut [u8], alpha: u8) {
    let a = u32::from(alpha);
    match mode {
        Blending::Native => {
            for (target, channel) in destination.iter_mut().zip(source) {
                let over = u32::from(channel) * a + u32::from(*target) * (255 - a);
                *target = (over / 255) as u8;
            }
        }
        Blending::Linear => {
            for (target, channel) in destination.iter_mut().zip(source) {
                let over = gamma::to_linear(channel) * a + gamma::to_linear(*target) * (255 - a);
                *target = gamma::to_srgb(over / 255);
            }
        }
        Blending::LinearCorrected => {
            let existing = [destination[0], destination[1], destination[2]];
            let wide = gamma::corrected_coverage(
                [source[0], source[1], source[2]],
                existing,
                alpha,
            );
            for (target, channel) in destination.iter_mut().zip(source) {
                let over = gamma::to_linear(channel) * wide
                    + gamma::to_linear(*target) * (gamma::COVERAGE_MAX - wide);
                *target = gamma::to_srgb(over / gamma::COVERAGE_MAX);
            }
        }
    }
}

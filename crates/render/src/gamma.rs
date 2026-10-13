//! Purpose: the sRGB <-> linear tables the blend uses, and the packed copy the shader reads.
//! Public surface: `to_linear`, `to_srgb`, `TABLE_BYTES`, `table_bytes`.
//! Why this file: a coverage mask is a GEOMETRIC fraction -- half the pixel is covered -- but
//!   the bytes it is applied to are sRGB-ENCODED, so mixing them with a straight integer lerp
//!   averages two encoded numbers and lands nowhere near the colour that half-coverage means.
//!   Measured on white over black at alpha 128: the encoded lerp gives 128, the correct answer
//!   is 188. That 60-unit deficit on every antialiased edge IS the thin, washed look that kept
//!   this terminal from being the one the maintainer uses.
//! NOT responsible for: the blend itself (`canvas.rs` and the shader in `gpu.rs`), or glyph
//!   coverage (`atlas.rs`).
//!
//! **Why tables rather than the formula.** The CPU and GPU backends are required to be
//! byte-identical, and `powf` is not: a shader's transcendentals are permitted to differ from
//! libm's in the last bits, which is exactly the one-unit-per-channel drift `tests/backend.rs`
//! exists to catch. Both backends therefore read the SAME bytes, built once here. The float
//! math runs in `f64` at startup and its result is data, not arithmetic either backend repeats.
//!
//! **Why 16-bit linear.** The blend must satisfy `to_srgb(to_linear(x)) == x` for all 256
//! values, or a glyph blended over its own colour would shift. That needs the forward table to
//! be injective; at 16 bits the closest pair of encoded values is 20 apart, at 12 bits they
//! collide below 3. `roundtrip_is_exact_for_every_byte` pins it.

use std::sync::OnceLock;

use crate::color::Rgba;

/// Which colour space the coverage blend runs in.
///
/// The reference terminal makes this configurable for a reason, and its own macOS default is
/// `Native` -- read from `ruuah` at `f4c68d65e`, `src/config/Config.zig`, `alpha-blending`.
/// Its documented trade, verbatim in substance: `Linear` "will eliminate the darkening
/// artifacts around the edges of text" but "makes dark text look much thinner than normal and
/// light text much thicker", and `LinearCorrected` is the same "with a correction step applied
/// for text that makes it look nearly or completely identical to `native`, but without any of
/// the darkening artifacts".
///
/// So `LinearCorrected` is NOT a way to make text heavier. It restores the weight `Native`
/// had and keeps the colour correctness `Linear` bought. On white-on-black it lands close to
/// `Native` by design; where it pays is colour pairs like red on green, which is exactly where
/// an encoded-space blend dips through a muddy midpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u32)]
pub enum Blending {
    /// Mix the sRGB-encoded bytes directly. What this renderer did before 2026-08-25.
    Native = 0,
    /// Mix in linear light. Correct colour, but text changes weight.
    Linear = 1,
    /// Mix in linear light, with the coverage pre-corrected to land on `Native`'s weight.
    #[default]
    LinearCorrected = 2,
}

/// Rec. 709 luminance weights, scaled to sum to EXACTLY 65536.
///
/// The reference uses `dot(color, float3(0.2126, 0.7152, 0.0722))`. Rounding each independently
/// sums to 65539 and would let a fully-white pixel report a luminance above the table's top
/// index; `the_luma_weights_sum_to_one` pins the adjusted triple instead. Duplicated verbatim
/// into the WGSL source, and pinned there by the same test.
pub const LUMA: [u32; 3] = [13933, 46871, 4732];

/// Below this linear difference the correction is skipped, because the mapping it performs
/// divides by exactly that difference.
///
/// The reference uses 0.001 in a 0..1 float; this is the same number in table units.
pub const CORRECTION_FLOOR: u32 = 66;

/// Linear values are fixed point over this range, so a product with a 0..255 coverage still
/// fits a `u32` (65535 * 255 * 2 is well under 2^32) and the shader needs no wider type.
pub const LINEAR_MAX: u32 = 65535;

/// Bytes the packed table occupies: 256 `u16` forward, then 65536 `u8` reverse.
pub const TABLE_BYTES: usize = 256 * 2 + 65536;

/// Word index in the packed table where the reverse (linear -> sRGB) half begins.
///
/// The shader indexes the packed buffer as `array<u32>`, so this is stated in WORDS and is
/// duplicated into the WGSL source as `SRGB_BASE`. `packed_layout_matches_the_shader` pins
/// the two together.
pub const SRGB_WORD_BASE: u32 = 128;

struct Tables {
    forward: [u16; 256],
    reverse: Box<[u8; 65536]>,
    packed: Box<[u8; TABLE_BYTES]>,
}

fn decode(encoded: f64) -> f64 {
    if encoded <= 0.04045 {
        encoded / 12.92
    } else {
        ((encoded + 0.055) / 1.055).powf(2.4)
    }
}

fn build() -> Tables {
    let mut forward = [0u16; 256];
    for (byte, slot) in forward.iter_mut().enumerate() {
        let linear = decode(byte as f64 / 255.0) * LINEAR_MAX as f64;
        *slot = linear.round() as u16;
    }

    // The reverse table is the NEAREST inverse, not a recomputed formula: filling each byte's
    // span out to the midpoint with its neighbour is what makes the roundtrip exact by
    // construction rather than by luck at the rounding boundaries.
    let mut reverse = Box::new([0u8; 65536]);
    for byte in 0u32..256 {
        let low = if byte == 0 {
            0
        } else {
            (u32::from(forward[byte as usize - 1]) + u32::from(forward[byte as usize])).div_ceil(2)
        };
        let high = if byte == 255 {
            LINEAR_MAX
        } else {
            (u32::from(forward[byte as usize]) + u32::from(forward[byte as usize + 1])) / 2
        };
        for slot in low..=high {
            reverse[slot as usize] = byte as u8;
        }
    }

    let mut packed = Box::new([0u8; TABLE_BYTES]);
    for (byte, value) in forward.iter().enumerate() {
        packed[byte * 2..byte * 2 + 2].copy_from_slice(&value.to_le_bytes());
    }
    packed[512..].copy_from_slice(reverse.as_slice());

    Tables {
        forward,
        reverse,
        packed,
    }
}

fn tables() -> &'static Tables {
    static TABLES: OnceLock<Tables> = OnceLock::new();
    TABLES.get_or_init(build)
}

/// sRGB byte -> linear, in `0..=LINEAR_MAX`.
#[inline]
pub fn to_linear(encoded: u8) -> u32 {
    u32::from(tables().forward[usize::from(encoded)])
}

/// Linear (`0..=LINEAR_MAX`) -> sRGB byte. Values past the top clamp rather than wrap.
#[inline]
pub fn to_srgb(linear: u32) -> u8 {
    tables().reverse[linear.min(LINEAR_MAX) as usize]
}

/// The same two tables as one little-endian byte block, for upload to the GPU.
///
/// The shader reads these bytes and nothing else, which is the whole point: agreement between
/// the backends is a property of them sharing data, not of them agreeing about `powf`.
pub fn table_bytes() -> &'static [u8] {
    tables().packed.as_slice()
}

/// Linear luminance of an sRGB triple, in `0..=LINEAR_MAX`.
#[inline]
pub fn luminance(colour: [u8; 3]) -> u32 {
    let sum = LUMA[0] * to_linear(colour[0])
        + LUMA[1] * to_linear(colour[1])
        + LUMA[2] * to_linear(colour[2]);
    sum >> 16
}

/// Coverage is carried at this width through the corrected path.
///
/// **Not 8 bits, and the two levels it buys are the whole reason.** Rounding the corrected
/// coverage to a byte first put alpha 32 on a corrected 4/255, which lands on 34 instead of
/// the 32 the encoded blend produced -- the steps are simply too coarse down at the dark end,
/// where a terminal spends most of its antialiasing. At 16 bits the same case is exact.
pub const COVERAGE_MAX: u32 = 65535;

/// The coverage a linear blend must use to land where an encoded blend would have landed.
///
/// Transcribed from the reference's grayscale path (`ruuah` at `f4c68d65e`,
/// `src/renderer/shaders/shaders.metal`, the `use_linear_correction` branch): take the two
/// luminances, blend them in ENCODED space to get the luminance the old blend produced, then
/// solve for the alpha a LINEAR interpolation from `bg` to `fg` needs to reach it. Returns a
/// fraction of `COVERAGE_MAX`.
///
/// **One deliberate divergence from the reference, and it is the price of the law here.** The
/// reference does this in floats. This quantises the two unlinearized luminances to 8 bits,
/// because the reverse table's output is a byte. Floats would put a shader's `pow` back in the
/// loop, which is the entire thing `gamma.rs` exists to keep out. The cost is bounded and
/// measured: `the_correction_lands_back_on_the_encoded_weight` holds it to one level.
#[inline]
pub fn corrected_coverage(source: [u8; 3], destination: [u8; 3], alpha: u8) -> u32 {
    let fg_l = luminance(source);
    let bg_l = luminance(destination);
    let span = fg_l.abs_diff(bg_l);
    if span <= CORRECTION_FLOOR {
        return u32::from(alpha) * COVERAGE_MAX / 255;
    }

    let a = u32::from(alpha);
    let encoded_fg = u32::from(to_srgb(fg_l));
    let encoded_bg = u32::from(to_srgb(bg_l));
    let encoded_blend = (encoded_fg * a + encoded_bg * (255 - a) + 127) / 255;
    let blend_l = to_linear(encoded_blend as u8);

    // `encoded_blend` lies between the two encoded endpoints and both tables are monotonic, so
    // `blend_l` lies between the two luminances and this distance is never a wrapping one.
    let reached = blend_l.abs_diff(bg_l);
    ((reached * COVERAGE_MAX + span / 2) / span).min(COVERAGE_MAX)
}

/// Blends `source` over three destination bytes at `alpha` coverage, in `mode`'s colour space.
///
/// **The single blend spec.** `canvas.rs` calls it, `surface.rs`'s control calls a deliberately
/// truncated twin, and the WGSL in `gpu.rs` is a transcription. Anything that changes here and
/// not in the shader is caught by `tests/backend.rs`.
#[inline]
pub fn blend_pixel(mode: Blending, source: Rgba, destination: &mut [u8], alpha: u8) {
    match mode {
        Blending::Native => {
            let a = u32::from(alpha);
            for (target, channel) in destination.iter_mut().zip(source) {
                let over = u32::from(channel) * a + u32::from(*target) * (255 - a);
                // Rounded rather than truncated, so a full-coverage blend of X over X is X.
                *target = ((over + 127) / 255) as u8;
            }
        }
        Blending::Linear => {
            let a = u32::from(alpha);
            for (target, channel) in destination.iter_mut().zip(source) {
                let over = to_linear(channel) * a + to_linear(*target) * (255 - a);
                *target = to_srgb((over + 127) / 255);
            }
        }
        Blending::LinearCorrected => {
            let existing = [destination[0], destination[1], destination[2]];
            let a = corrected_coverage([source[0], source[1], source[2]], existing, alpha);
            for (target, channel) in destination.iter_mut().zip(source) {
                let over = to_linear(channel) * a + to_linear(*target) * (COVERAGE_MAX - a);
                *target = to_srgb((over + COVERAGE_MAX / 2) / COVERAGE_MAX);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_is_exact_for_every_byte() {
        // The invariant the blend rests on: a colour blended over ITSELF at any coverage must
        // come back unchanged. If this fails, text on a matching background shifts hue.
        for byte in 0u8..=255 {
            assert_eq!(to_srgb(to_linear(byte)), byte, "roundtrip failed at {byte}");
        }
    }

    #[test]
    fn the_endpoints_are_the_endpoints() {
        assert_eq!(to_linear(0), 0);
        assert_eq!(to_linear(255), LINEAR_MAX);
        assert_eq!(to_srgb(0), 0);
        assert_eq!(to_srgb(LINEAR_MAX), 255);
    }

    #[test]
    fn both_tables_are_monotonic() {
        // A non-monotonic table would make a brighter source render darker somewhere in the
        // middle, which no endpoint test can see.
        for byte in 1u8..=255 {
            assert!(
                to_linear(byte) > to_linear(byte - 1),
                "forward dipped at {byte}"
            );
        }
        for slot in 1..=LINEAR_MAX {
            assert!(
                to_srgb(slot) >= to_srgb(slot - 1),
                "reverse dipped at {slot}"
            );
        }
    }

    #[test]
    fn half_coverage_white_on_black_is_the_perceptual_middle() {
        // The measured number from the file header, and the reason this module exists.
        let half = (to_linear(255) * 128 + to_linear(0) * 127 + 127) / 255;
        assert_eq!(to_srgb(half), 188);
    }

    #[test]
    fn the_luma_weights_sum_to_one() {
        // If they summed to more, a white pixel's luminance would index past the reverse
        // table; if less, white would not read as full luminance and the correction would
        // never reach alpha 255.
        assert_eq!(LUMA[0] + LUMA[1] + LUMA[2], 65536);
        assert_eq!(luminance([255, 255, 255]), LINEAR_MAX);
        assert_eq!(luminance([0, 0, 0]), 0);
    }

    #[test]
    fn the_correction_lands_back_on_the_encoded_weight() {
        // The whole claim of `LinearCorrected`: correcting the coverage and then blending in
        // linear light reproduces what the encoded blend produced. Grayscale is the case the
        // reference calls "virtually identical", so it is the one held to a tight bound.
        for alpha in 1u8..=254 {
            let mut native = [0u8, 0, 0];
            blend_pixel(Blending::Native, [255, 255, 255, 255], &mut native, alpha);
            let mut corrected = [0u8, 0, 0];
            blend_pixel(
                Blending::LinearCorrected,
                [255, 255, 255, 255],
                &mut corrected,
                alpha,
            );
            assert!(
                corrected[0].abs_diff(native[0]) <= 1,
                "alpha {alpha}: native {}, corrected {}",
                native[0],
                corrected[0]
            );
        }
    }

    #[test]
    fn the_correction_is_skipped_when_there_is_nothing_to_correct() {
        // Dividing by the luminance span is only safe because of this guard, and a colour on
        // its own background is the case that would divide by zero.
        // Falls back to the plain coverage, widened, rather than dividing by the span.
        assert_eq!(
            corrected_coverage([90, 90, 90], [90, 90, 90], 77),
            77 * COVERAGE_MAX / 255
        );
    }

    #[test]
    fn dark_text_on_a_light_background_corrects_too() {
        // The span is negative in this direction. An implementation that subtracts without
        // taking the magnitude wraps and clamps to 255, painting solid text at every coverage.
        let coverage = corrected_coverage([0, 0, 0], [255, 255, 255], 128);
        assert!(coverage > 0 && coverage < COVERAGE_MAX, "got {coverage}");

        let mut landed = [255u8, 255, 255];
        blend_pixel(Blending::LinearCorrected, [0, 0, 0, 255], &mut landed, 128);
        let mut native = [255u8, 255, 255];
        blend_pixel(Blending::Native, [0, 0, 0, 255], &mut native, 128);
        assert!(
            landed[0].abs_diff(native[0]) <= 1,
            "landed {}, native {}",
            landed[0],
            native[0]
        );
    }

    #[test]
    fn packed_layout_matches_the_shader() {
        let bytes = table_bytes();
        assert_eq!(bytes.len(), TABLE_BYTES);
        assert_eq!(SRGB_WORD_BASE as usize * 4, 512);
        // Forward half, read back the way the shader extracts a u16 half-word.
        for byte in 0u8..=255 {
            let index = usize::from(byte);
            let packed = u16::from_le_bytes([bytes[index * 2], bytes[index * 2 + 1]]);
            assert_eq!(u32::from(packed), to_linear(byte));
        }
        // Reverse half, read back the way the shader extracts a byte from a word.
        for slot in [0u32, 1, 19, 20, 12345, LINEAR_MAX] {
            assert_eq!(bytes[512 + slot as usize], to_srgb(slot));
        }
    }
}

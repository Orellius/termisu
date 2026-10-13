//! The gate for the blend's colour space, written before the fix and seen red against it.
//!
//! Every existing pixel test compares a renderer with itself, so all of them stay green while
//! the blend averages sRGB-ENCODED bytes -- a mistake that is uniform, and therefore invisible
//! to any self-comparison. `backend.rs` cannot see it either: it demands the two backends agree,
//! and they agreed on the wrong answer. What no test here could state until now is what the
//! right answer IS.
//!
//! Half coverage means half the PHOTONS, not half the encoded byte. White over black at alpha
//! 128 is 188, not 128. Everything below is that one claim, applied where it shows up.

use termisu_vt_render::{Canvas, GpuSurface, Surface, gamma, gamma::Blending};

const BLACK: [u8; 4] = [0, 0, 0, 255];
const WHITE: [u8; 4] = [255, 255, 255, 255];

fn blended(alpha: u8) -> [u8; 4] {
    blended_in(Blending::Linear, alpha)
}

fn blended_in(mode: Blending, alpha: u8) -> [u8; 4] {
    let mut canvas = Canvas::new(1, 1);
    canvas.set_blending(mode);
    canvas.fill(0, 0, 1, 1, BLACK);
    canvas.blend_mask(0, 0, 1, 1, &[alpha], WHITE);
    canvas.pixel(0, 0)
}

#[test]
fn half_coverage_is_half_the_light_not_half_the_byte() {
    // The whole slice in one assertion. 128 is what an encoded-space lerp produces and is the
    // measured cause of thin, washed-out text.
    assert_eq!(blended(128)[0], 188);
}

#[test]
fn the_coverage_endpoints_still_pass_through_untouched() {
    assert_eq!(blended(0), BLACK);
    assert_eq!(blended(255), WHITE);
}

#[test]
fn a_colour_blended_over_itself_never_shifts() {
    // The invariant that pays for the 16-bit table. Any coverage, any colour, no drift -- a
    // glyph drawn on a background of its own colour must vanish, not leave a smudge.
    for colour in [[0, 0, 0, 255], [18, 18, 18, 255], [200, 90, 40, 255], WHITE] {
        for alpha in [1u8, 7, 64, 128, 200, 254] {
            let mut canvas = Canvas::new(1, 1);
            canvas.fill(0, 0, 1, 1, colour);
            canvas.blend_mask(0, 0, 1, 1, &[alpha], colour);
            assert_eq!(
                canvas.pixel(0, 0),
                colour,
                "{colour:?} shifted at alpha {alpha}"
            );
        }
    }
}

#[test]
fn linear_blending_is_monotonic_in_coverage() {
    // A table read with the wrong index arithmetic can still pass the endpoints and the
    // midpoint while dipping somewhere between them.
    let mut previous = 0u8;
    for alpha in 0u8..=255 {
        let value = blended(alpha)[0];
        assert!(
            value >= previous,
            "alpha {alpha} went backwards: {previous} -> {value}"
        );
        previous = value;
    }
}

#[test]
fn the_gpu_lands_on_the_same_bytes() {
    // The tables are uploaded rather than recomputed in the shader precisely so this holds.
    // Skipped rather than failed where no adapter exists, so CI without a GPU stays honest.
    let Ok(mut gpu) = GpuSurface::new(1, 1) else {
        eprintln!("no GPU adapter: skipping the cross-backend half of this gate");
        return;
    };
    for mode in [
        Blending::Native,
        Blending::Linear,
        Blending::LinearCorrected,
    ] {
        gpu.set_blending(mode);
        for alpha in [1u8, 33, 128, 199, 254] {
            gpu.fill(0, 0, 1, 1, BLACK);
            gpu.blend_mask(0, 0, 1, 1, &[alpha], WHITE);
            let pixels = gpu.read_pixels();
            assert_eq!(
                pixels[0],
                blended_in(mode, alpha)[0],
                "backends disagreed at alpha {alpha} in {mode:?}"
            );
        }
    }
}

#[test]
fn an_encoded_space_blend_would_be_caught() {
    // The control. This is the arithmetic the blend used before this slice; if the assertions
    // above can pass while this expression is what runs, they are measuring nothing.
    // The background is black, so its term drops out. Named rather than written as a literal
    // `0 *` so the shape of the old expression stays legible without clippy reading it as a
    // mistake -- which it did, as a hard `erasing_op` deny, once `--all-targets` was run.
    let background = 0u32;
    let encoded = (255u32 * 128 + background * 127 + 127) / 255;
    assert_eq!(encoded, 128);
    assert_ne!(encoded as u8, blended(128)[0]);
    // And the module the fix rests on agrees with the number the gate demands.
    assert_eq!(
        gamma::to_srgb((gamma::to_linear(255) * 128 + 127) / 255),
        188
    );
}

/// The shipped default, and the reason it is not `Linear`.
///
/// `LinearCorrected` deliberately lands back on the weight the ENCODED blend produced, so on
/// grayscale it reads almost exactly like the old renderer. What it does not do is dip through
/// the muddy midpoint on a colour pair, which is what `Linear` was bought for. Anyone reading
/// "128" here and concluding the colour space regressed should read `gamma.rs`'s `Blending`.
#[test]
fn the_default_mode_restores_the_encoded_weight() {
    assert_eq!(Blending::default(), Blending::LinearCorrected);
    for alpha in 1u8..=254 {
        let native = blended_in(Blending::Native, alpha)[0];
        let corrected = blended_in(Blending::LinearCorrected, alpha)[0];
        assert!(
            corrected.abs_diff(native) <= 1,
            "alpha {alpha}: native {native}, corrected {corrected}"
        );
    }
}

/// Where the correction actually pays, and the one number that shows it.
///
/// Pure red over pure green at half coverage. Their luminances differ enormously (green carries
/// 0.7152 of the weight, red 0.2126), so the encoded blend walks a path through colour space
/// that the linear one does not.
#[test]
fn a_colour_pair_still_differs_from_the_encoded_blend() {
    let red = [255u8, 0, 0, 255];
    let green = [0u8, 255, 0, 255];

    let mut native = Canvas::new(1, 1);
    native.set_blending(Blending::Native);
    native.fill(0, 0, 1, 1, green);
    native.blend_mask(0, 0, 1, 1, &[128], red);

    let mut corrected = Canvas::new(1, 1);
    corrected.set_blending(Blending::LinearCorrected);
    corrected.fill(0, 0, 1, 1, green);
    corrected.blend_mask(0, 0, 1, 1, &[128], red);

    assert_ne!(
        native.pixel(0, 0),
        corrected.pixel(0, 0),
        "the correction collapsed onto the encoded blend even for a colour pair, so it bought \
         nothing at all"
    );
}

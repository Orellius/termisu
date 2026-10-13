//! Purpose: soften the strip of history rows that shows behind the tab band.
//! Public surface: `blur`.
//! Why this file: the maintainer's option 2 of the top blur (2026-10-02). Both platform blurs were tried
//!   for option 1 and neither worked over this pane (NSVisualEffectView paints its own grey, a
//!   Core Image background filter drew nothing), so the strip is blurred here, on its pixels,
//!   where a test can measure it.
//! NOT responsible for: choosing the rows (frame `AbovePublisher`) or placing the strip (Swift).
//! Test strategy: the unit tests below pin that a flat image is left exactly as it was (a blank
//!   strip must stay the ground colour) and that a hard edge becomes a ramp as wide as the
//!   radius promises.

/// Three box passes each way, which is within a few percent of a Gaussian of sigma
/// `radius * 0.8` and costs the same whatever the radius: a running sum per line.
pub fn blur(pixels: &mut [u8], width: usize, height: usize, radius: usize) {
    if radius == 0 || width == 0 || height == 0 || pixels.len() < width * height * 4 {
        return;
    }
    let pixels = &mut pixels[..width * height * 4];
    let span = 2 * radius + 1;
    // The rounded mean for every sum a window can reach, so the inner loops never divide.
    let mean: Vec<u8> = (0..=255 * span).map(|sum| ((sum + span / 2) / span) as u8).collect();
    // A pass along the rows runs as a pass down the columns of the turned image: one running
    // sum per line is a serial chain, and down runs every line's chain side by side.
    let mut turned = vec![0u8; pixels.len()];
    let mut copy = Vec::with_capacity(pixels.len());
    let mut sums = vec![0u32; width.max(height) * 4];
    for _ in 0..3 {
        turn(pixels, width, height, &mut turned);
        down(&mut turned, height, width, radius, &mean, &mut copy, &mut sums[..height * 4]);
        turn(&turned, height, width, pixels);
        down(pixels, width, height, radius, &mean, &mut copy, &mut sums[..width * 4]);
    }
}

/// Transposes `width` x `height` pixels into `turned`, in small tiles so both sides stay in cache.
fn turn(pixels: &[u8], width: usize, height: usize, turned: &mut [u8]) {
    const TILE: usize = 16;
    for y0 in (0..height).step_by(TILE) {
        for x0 in (0..width).step_by(TILE) {
            for y in y0..(y0 + TILE).min(height) {
                for x in x0..(x0 + TILE).min(width) {
                    let from = (y * width + x) * 4;
                    let to = (x * height + y) * 4;
                    turned[to..to + 4].copy_from_slice(&pixels[from..from + 4]);
                }
            }
        }
    }
}

/// One box pass down every column at once, a row at a time, so the image is read in memory
/// order. Edges clamp, so a flat line stays flat to the last bit. The sums run over all four
/// lanes; only colour is written back, so alpha is left alone.
fn down(pixels: &mut [u8], width: usize, height: usize, radius: usize, mean: &[u8], copy: &mut Vec<u8>, sums: &mut [u32]) {
    copy.clear();
    copy.extend_from_slice(pixels);
    let stride = width * 4;
    let row = |y: usize| &copy[y.min(height - 1) * stride..][..stride];
    sums.fill(0);
    for (sum, v) in sums.iter_mut().zip(row(0)) {
        *sum = u32::from(*v) * radius as u32;
    }
    for y in 0..=radius {
        for (sum, v) in sums.iter_mut().zip(row(y)) {
            *sum += u32::from(*v);
        }
    }
    for y in 0..height {
        for (o, s) in pixels[y * stride..][..stride].chunks_exact_mut(4).zip(sums.chunks_exact(4)) {
            o[0] = mean[s[0] as usize];
            o[1] = mean[s[1] as usize];
            o[2] = mean[s[2] as usize];
        }
        let next = row(y + radius + 1);
        let out = row(y.saturating_sub(radius));
        for ((sum, n), o) in sums.iter_mut().zip(next).zip(out) {
            *sum = *sum + u32::from(*n) - u32::from(*o);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::blur;

    /// The first implementation (2026-10-02), one line at a time with a division per value. The
    /// faster passes above must give exactly its bytes.
    fn reference(pixels: &mut [u8], width: usize, height: usize, radius: usize) {
        if radius == 0 || width == 0 || height == 0 || pixels.len() < width * height * 4 {
            return;
        }
        let mut line = Vec::new();
        for _ in 0..3 {
            for y in 0..height {
                pass(pixels, y * width * 4, 4, width, radius, &mut line);
            }
            for x in 0..width {
                pass(pixels, x * 4, width * 4, height, radius, &mut line);
            }
        }
    }

    fn pass(pixels: &mut [u8], start: usize, stride: usize, len: usize, radius: usize, line: &mut Vec<[u32; 3]>) {
        line.clear();
        line.extend((0..len).map(|i| {
            let p = start + i * stride;
            [u32::from(pixels[p]), u32::from(pixels[p + 1]), u32::from(pixels[p + 2])]
        }));
        let at = |i: isize| line[i.clamp(0, len as isize - 1) as usize];
        let span = (2 * radius + 1) as u32;
        let mut sum = [0u32; 3];
        for i in -(radius as isize)..=(radius as isize) {
            let v = at(i);
            for c in 0..3 {
                sum[c] += v[c];
            }
        }
        for i in 0..len {
            let p = start + i * stride;
            for c in 0..3 {
                pixels[p + c] = ((sum[c] + span / 2) / span) as u8;
            }
            let out = at(i as isize - radius as isize);
            let next = at(i as isize + radius as isize + 1);
            for c in 0..3 {
                sum[c] = sum[c] + next[c] - out[c];
            }
        }
    }

    #[test]
    fn the_fast_passes_give_exactly_the_reference_bytes() {
        let mut seed = 0x2545_f491_u32;
        let mut noise = move || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as u8
        };
        for (width, height) in [(1, 1), (1, 9), (9, 1), (3, 50), (50, 3), (37, 23), (200, 61)] {
            for radius in [1, 2, 5, 10, 40] {
                // Four spare bytes past the image must be left alone too.
                let mut pixels: Vec<u8> = (0..width * height * 4 + 4).map(|_| noise()).collect();
                let mut expected = pixels.clone();
                reference(&mut expected, width, height, radius);
                blur(&mut pixels, width, height, radius);
                assert!(pixels == expected, "{width}x{height} radius {radius} differs from the reference");
            }
        }
    }

    fn image(width: usize, height: usize, paint: impl Fn(usize, usize) -> u8) -> Vec<u8> {
        let mut pixels = Vec::with_capacity(width * height * 4);
        for y in 0..height {
            for x in 0..width {
                let v = paint(x, y);
                pixels.extend([v, v, v, 255]);
            }
        }
        pixels
    }

    #[test]
    fn a_flat_image_is_left_exactly_as_it_was() {
        let mut pixels = image(40, 12, |_, _| 13);
        let before = pixels.clone();
        blur(&mut pixels, 40, 12, 5);
        assert_eq!(pixels, before);
    }

    #[test]
    fn a_hard_edge_becomes_a_ramp_as_wide_as_the_radius() {
        // Black left half, white right half. Unblurred, the step is one pixel wide.
        let (width, height) = (80, 4);
        let mut pixels = image(width, height, |x, _| if x < 40 { 0 } else { 255 });
        blur(&mut pixels, width, height, 4);
        let row: Vec<u8> = (0..width).map(|x| pixels[(width + x) * 4]).collect();
        let ramp = row.iter().filter(|v| **v > 8 && **v < 247).count();
        assert!(ramp >= 8, "the edge spans only {ramp} pixels: {row:?}");
        assert!(row[0] < 8 && row[width - 1] > 247, "far from the edge must keep its value");
        assert!(row.windows(2).all(|w| w[0] <= w[1]), "a blurred step stays monotonic");
    }

    #[test]
    fn alpha_is_untouched() {
        let mut pixels = image(10, 10, |x, _| (x * 25) as u8);
        for (i, p) in pixels.chunks_mut(4).enumerate() {
            p[3] = (i % 256) as u8;
        }
        let alphas: Vec<u8> = pixels.chunks(4).map(|p| p[3]).collect();
        blur(&mut pixels, 10, 10, 3);
        assert_eq!(pixels.chunks(4).map(|p| p[3]).collect::<Vec<_>>(), alphas);
    }
}

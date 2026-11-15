import Foundation

/// The colour a cover is remembered by, bright enough to read on a black notch.
public enum CoverTint {
    /// `pixels` are RGBA bytes. Nil when the cover has no colour worth naming (black and white, near black).
    public static func dominant(rgba pixels: [UInt8]) -> (red: Double, green: Double, blue: Double)? {
        let buckets = 12
        var weight = [Double](repeating: 0, count: buckets)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: buckets)
        var index = 0
        while index + 3 < pixels.count {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            index += 4
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            guard high > 0.18, delta / high > 0.22 else { continue }
            var hue = high == r ? (g - b) / delta : high == g ? 2 + (b - r) / delta : 4 + (r - g) / delta
            hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
            let bucket = min(buckets - 1, Int(hue * Double(buckets)))
            // Vivid pixels count for more than washed-out ones: the eye keeps the colour, not the haze.
            let score = (delta / high) * high
            weight[bucket] += score
            sums[bucket].0 += r * score; sums[bucket].1 += g * score; sums[bucket].2 += b * score
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > Double(pixels.count / 4) * 0.01 else { return nil }
        var r = sums[best].0 / weight[best], g = sums[best].1 / weight[best], b = sums[best].2 / weight[best]
        // Same hue, lifted to a brightness that stays visible on black.
        let high = max(r, g, b)
        if high > 0, high < 0.9 { let gain = 0.9 / high; r *= gain; g *= gain; b *= gain }
        // A very saturated colour vibrates on black: pull it a little towards white.
        let low = min(r, g, b)
        if low < 0.25 { let mix = 0.25 - low; r += (1 - r) * mix; g += (1 - g) * mix; b += (1 - b) * mix }
        return (min(1, r), min(1, g), min(1, b))
    }
}

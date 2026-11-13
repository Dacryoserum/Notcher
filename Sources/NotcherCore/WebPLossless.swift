import Foundation

/// A small lossless WebP (VP8L) encoder: macOS can read WebP but ships no encoder.
/// Pixels go through the subtract-green and predictor transforms, then one Huffman code per channel.
/// There is no LZ77 or colour cache, so files are valid and exact but larger than a tuned encoder's.
public enum WebPLossless {
    /// `pixels` are 0xAARRGGBB, row by row, with straight (non-premultiplied) alpha.
    public static func encode(width: Int, height: Int, pixels: [UInt32]) -> Data? {
        guard width > 0, height > 0, width <= 16384, height <= 16384, pixels.count == width * height else { return nil }
        var bits = BitWriter()
        bits.write(UInt32(width - 1), 14); bits.write(UInt32(height - 1), 14)
        bits.write(pixels.contains { $0 >> 24 != 0xff } ? 1 : 0, 1)
        bits.write(0, 3) // version

        // Transforms are announced in the order the encoder applies them.
        bits.write(1, 1); bits.write(2, 2) // subtract green
        var image = pixels.map { pixel -> UInt32 in
            let green = (pixel >> 8) & 0xff
            let red = ((pixel >> 16) & 0xff &- green) & 0xff, blue = (pixel & 0xff &- green) & 0xff
            return (pixel & 0xff00ff00) | (red << 16) | blue
        }
        bits.write(1, 1); bits.write(0, 2) // predictor
        let blockBits = 9
        bits.write(UInt32(blockBits - 2), 3)
        let blocks = ((width + (1 << blockBits) - 1) >> blockBits) * ((height + (1 << blockBits) - 1) >> blockBits)
        // One mode for the whole image: 12, "left + top − top-left", clamped per channel.
        writeImage([UInt32](repeating: 0xff00_0c00, count: blocks), into: &bits)
        image = residuals(of: image, width: width, height: height)
        bits.write(0, 1) // no further transform

        bits.write(0, 1) // no colour cache
        bits.write(0, 1) // a single group of prefix codes
        writeCodesAndPixels(image, into: &bits)

        let payload = [0x2f] + bits.finish()
        var data = Data("RIFF".utf8)
        let padded = payload.count + (payload.count & 1)
        data.append(littleEndian(UInt32(4 + 8 + padded)))
        data.append(Data("WEBPVP8L".utf8))
        data.append(littleEndian(UInt32(payload.count)))
        data.append(contentsOf: payload)
        if payload.count & 1 == 1 { data.append(0) }
        return data
    }

    private static func littleEndian(_ value: UInt32) -> Data { Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]) }

    /// Each pixel minus its prediction, channel by channel, modulo 256.
    private static func residuals(of image: [UInt32], width: Int, height: Int) -> [UInt32] {
        var output = image
        func subtract(_ a: UInt32, _ b: UInt32) -> UInt32 {
            var result: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) { result |= (((a >> UInt32(shift)) & 0xff &- (b >> UInt32(shift)) & 0xff) & 0xff) << UInt32(shift) }
            return result
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let prediction: UInt32
                if x == 0 && y == 0 { prediction = 0xff00_0000 }
                else if y == 0 { prediction = image[index - 1] }
                else if x == 0 { prediction = image[index - width] }
                else {
                    let left = image[index - 1], top = image[index - width], corner = image[index - width - 1]
                    var value: UInt32 = 0
                    for shift in stride(from: 0, to: 32, by: 8) {
                        let s = UInt32(shift)
                        let sum = Int((left >> s) & 0xff) + Int((top >> s) & 0xff) - Int((corner >> s) & 0xff)
                        value |= UInt32(min(255, max(0, sum))) << s
                    }
                    prediction = value
                }
                output[index] = subtract(image[index], prediction)
            }
        }
        return output
    }

    /// An entropy-coded sub-image (used for the predictor modes): colour-cache flag, codes, pixels.
    private static func writeImage(_ image: [UInt32], into bits: inout BitWriter) {
        bits.write(0, 1)
        writeCodesAndPixels(image, into: &bits)
    }

    private static func writeCodesAndPixels(_ image: [UInt32], into bits: inout BitWriter) {
        // Channel order of the format: green, red, blue, alpha.
        let shifts: [UInt32] = [8, 16, 0, 24]
        var counts = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        for pixel in image { for channel in 0..<4 { counts[channel][Int((pixel >> shifts[channel]) & 0xff)] += 1 } }
        var codes: [Code] = []
        for channel in 0..<4 {
            // The green alphabet also holds 24 length codes, which this encoder never emits.
            codes.append(writeCode(counts: counts[channel], alphabet: channel == 0 ? 280 : 256, into: &bits))
        }
        bits.write(1, 1); bits.write(0, 1); bits.write(0, 1); bits.write(0, 1) // distance code: one unused symbol
        for pixel in image {
            for channel in 0..<4 {
                let symbol = Int((pixel >> shifts[channel]) & 0xff)
                bits.write(codes[channel].bits[symbol], codes[channel].lengths[symbol])
            }
        }
    }

    private struct Code { var lengths: [Int]; var bits: [UInt32] }

    private static func writeCode(counts: [Int], alphabet: Int, into bits: inout BitWriter) -> Code {
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.count == 1 {
            // A single symbol needs no bit at all.
            bits.write(1, 1); bits.write(0, 1); bits.write(1, 1); bits.write(UInt32(used[0]), 8)
            return Code(lengths: [Int](repeating: 0, count: 256), bits: [UInt32](repeating: 0, count: 256))
        }
        let lengths = huffmanLengths(counts, limit: 15)
        bits.write(0, 1)
        bits.write(15, 4) // all 19 code-length codes follow
        // Lengths 0…15 are each sent as a plain 4-bit code; the repeat codes 16, 17 and 18 are unused.
        for symbol in [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] { bits.write(symbol < 16 ? 4 : 0, 3) }
        bits.write(0, 1) // lengths for the whole alphabet
        for symbol in 0..<alphabet { bits.write(reversed(UInt32(symbol < 256 ? lengths[symbol] : 0), 4), 4) }
        return Code(lengths: lengths, bits: canonicalCodes(lengths))
    }

    private static func reversed(_ value: UInt32, _ count: Int) -> UInt32 {
        var result: UInt32 = 0
        for bit in 0..<count where value & (1 << UInt32(bit)) != 0 { result |= 1 << UInt32(count - 1 - bit) }
        return result
    }
    /// Canonical codes, already bit-reversed for a stream written least significant bit first.
    private static func canonicalCodes(_ lengths: [Int]) -> [UInt32] {
        var perLength = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 { perLength[length] += 1 }
        var next = [UInt32](repeating: 0, count: 16), code: UInt32 = 0
        for length in 1..<16 { code = (code + UInt32(perLength[length - 1])) << 1; next[length] = code }
        return lengths.map { length in
            guard length > 0 else { return 0 }
            defer { next[length] += 1 }
            return reversed(next[length], length)
        }
    }
    /// Huffman code lengths. Counts are flattened until no code is longer than `limit`.
    static func huffmanLengths(_ counts: [Int], limit: Int) -> [Int] {
        var scaled = counts
        while true {
            var lengths = [Int](repeating: 0, count: counts.count)
            // Each node: weight, and the symbols beneath it.
            var nodes = scaled.indices.filter { scaled[$0] > 0 }.map { (weight: scaled[$0], symbols: [$0]) }
            if nodes.count == 1 { lengths[nodes[0].symbols[0]] = 1; return lengths }
            while nodes.count > 1 {
                nodes.sort { $0.weight > $1.weight }
                let first = nodes.removeLast(), second = nodes.removeLast()
                for symbol in first.symbols + second.symbols { lengths[symbol] += 1 }
                nodes.append((first.weight + second.weight, first.symbols + second.symbols))
            }
            if (lengths.max() ?? 0) <= limit { return lengths }
            scaled = scaled.map { $0 > 0 ? max(1, $0 / 2) : 0 }
        }
    }

    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var buffer: UInt64 = 0
        private var filled = 0
        mutating func write(_ value: UInt32, _ count: Int) {
            guard count > 0 else { return }
            buffer |= UInt64(value & (count == 32 ? .max : (1 << UInt32(count)) - 1)) << UInt64(filled)
            filled += count
            while filled >= 8 { bytes.append(UInt8(buffer & 0xff)); buffer >>= 8; filled -= 8 }
        }
        mutating func finish() -> [UInt8] {
            if filled > 0 { bytes.append(UInt8(buffer & 0xff)); buffer = 0; filled = 0 }
            return bytes
        }
    }
}

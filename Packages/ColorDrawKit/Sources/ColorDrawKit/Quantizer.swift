import Foundation

/// Small, fast, seedable random number generator so puzzles are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Picks a small palette that represents an image and maps every pixel to one of its entries.
enum Quantizer {
    struct Result {
        var palette: [LabColor]
        /// Palette index for every pixel.
        var indices: [UInt8]
    }

    /// If the image already uses at most `maxColors` distinct colors (clip art, the built-in
    /// pictures), returns them exactly so no color gets blended or lost.
    static func exactPalette(of image: RGBAImage, maxColors: Int) -> Result? {
        var lookup: [UInt32: UInt8] = [:]
        var colors: [RGBColor] = []
        var indices = [UInt8](repeating: 0, count: image.width * image.height)
        for i in 0..<(image.width * image.height) {
            let r = image.pixels[i * 4], g = image.pixels[i * 4 + 1], b = image.pixels[i * 4 + 2]
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            if let index = lookup[key] {
                indices[i] = index
            } else {
                guard colors.count < maxColors else { return nil }
                let index = UInt8(colors.count)
                lookup[key] = index
                colors.append(RGBColor(r: r, g: g, b: b))
                indices[i] = index
            }
        }
        return Result(palette: colors.map(\.lab), indices: indices)
    }

    /// k-means++ clustering in Lab space.
    static func kMeans(_ image: LabImage, colorCount: Int, seed: UInt64) -> Result {
        let n = image.count
        let k = max(1, min(colorCount, 255, n))
        var rng = SplitMix64(seed: seed)

        // Train on a sample: plenty for a stable palette and much faster than every pixel.
        let sampleCount = min(n, 24_000)
        var sample = [LabColor]()
        sample.reserveCapacity(sampleCount)
        let step = Double(n) / Double(sampleCount)
        for s in 0..<sampleCount {
            let jitter = Double.random(in: 0..<step, using: &rng)
            let index = min(n - 1, Int(Double(s) * step + jitter))
            sample.append(image.color(at: index))
        }

        var centers = seedCenters(sample, k: k, rng: &rng)
        for _ in 0..<24 {
            var sums = [(l: Float, a: Float, b: Float, n: Int)](repeating: (0, 0, 0, 0), count: centers.count)
            for color in sample {
                let nearest = nearestIndex(of: color, in: centers)
                sums[nearest].l += color.l
                sums[nearest].a += color.a
                sums[nearest].b += color.b
                sums[nearest].n += 1
            }
            var moved: Float = 0
            for c in centers.indices where sums[c].n > 0 {
                let count = Float(sums[c].n)
                let updated = LabColor(l: sums[c].l / count, a: sums[c].a / count, b: sums[c].b / count)
                moved = max(moved, updated.distanceSquared(to: centers[c]))
                centers[c] = updated
            }
            // Drop clusters that ended up empty.
            centers = centers.indices.filter { sums[$0].n > 0 }.map { centers[$0] }
            if moved < 0.01 { break }
        }

        return Result(palette: centers, indices: assign(image, to: centers))
    }

    /// Merges palette entries that a child could not tell apart, then remaps pixels.
    static func mergeSimilarColors(_ result: Result, image: LabImage, minimumDistance: Float) -> Result {
        var palette = result.palette
        guard palette.count > 1 else { return result }
        var counts = [Int](repeating: 0, count: palette.count)
        for index in result.indices { counts[Int(index)] += 1 }

        let threshold = minimumDistance * minimumDistance
        var merged = true
        while merged && palette.count > 1 {
            merged = false
            var best: (i: Int, j: Int, d: Float)?
            for i in 0..<palette.count {
                for j in (i + 1)..<palette.count {
                    let d = palette[i].distanceSquared(to: palette[j])
                    if d < threshold, d < (best?.d ?? .infinity) { best = (i, j, d) }
                }
            }
            if let (i, j, _) = best {
                let wi = Float(max(counts[i], 1)), wj = Float(max(counts[j], 1))
                let total = wi + wj
                palette[i] = LabColor(
                    l: (palette[i].l * wi + palette[j].l * wj) / total,
                    a: (palette[i].a * wi + palette[j].a * wj) / total,
                    b: (palette[i].b * wi + palette[j].b * wj) / total
                )
                counts[i] += counts[j]
                palette.remove(at: j)
                counts.remove(at: j)
                merged = true
            }
        }
        guard palette.count != result.palette.count else { return result }
        return Result(palette: palette, indices: assign(image, to: palette))
    }

    static func assign(_ image: LabImage, to centers: [LabColor]) -> [UInt8] {
        var indices = [UInt8](repeating: 0, count: image.count)
        for i in 0..<image.count {
            indices[i] = UInt8(nearestIndex(of: image.color(at: i), in: centers))
        }
        return indices
    }

    @inline(__always)
    static func nearestIndex(of color: LabColor, in centers: [LabColor]) -> Int {
        var best = 0
        var bestDistance = Float.infinity
        for (i, center) in centers.enumerated() {
            let d = color.distanceSquared(to: center)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    /// k-means++ seeding: spreads the initial centers across the color space.
    private static func seedCenters(_ sample: [LabColor], k: Int, rng: inout SplitMix64) -> [LabColor] {
        var centers = [sample[Int.random(in: 0..<sample.count, using: &rng)]]
        var distances = sample.map { $0.distanceSquared(to: centers[0]) }
        while centers.count < k {
            let total = distances.reduce(0, +)
            guard total > 0 else { break } // Fewer distinct colors than requested.
            var target = Float.random(in: 0..<total, using: &rng)
            var chosen = sample.count - 1
            for (i, d) in distances.enumerated() {
                target -= d
                if target <= 0 {
                    chosen = i
                    break
                }
            }
            let center = sample[chosen]
            centers.append(center)
            for i in sample.indices {
                distances[i] = min(distances[i], sample[i].distanceSquared(to: center))
            }
        }
        return centers
    }
}

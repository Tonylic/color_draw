import Foundation

/// An inclusive rectangle of pixels.
public struct PixelBounds: Hashable, Sendable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public var isEmpty: Bool { maxX < minX || maxY < minY }

    static let empty = PixelBounds(minX: .max, minY: .max, maxX: .min, maxY: .min)
}

/// A high-resolution version of a puzzle's region map with smooth, rounded outlines.
///
/// Puzzles are built at a low "working" resolution so shapes stay simple. Scaling that map up
/// directly would give staircase edges, so every high-res pixel instead takes the region with the
/// strongest Gaussian-weighted vote among its 5×5 nearest working pixels, which turns stairs into
/// soft curves. Painting, hit testing and outlines all use this map, so what a child sees is
/// exactly what responds to their finger.
public struct DetailMap: Sendable {
    public let scale: Int
    public let width: Int
    public let height: Int
    /// Region index of every high-res pixel, row-major.
    public let labels: [UInt16]
    /// Bounding box of every region in high-res pixels.
    public let bounds: [PixelBounds]
    /// How decisively each pixel won its region's vote: the winning Gaussian weight minus the
    /// strongest other region's, in steps of 1/64 (255 = nowhere near a border). The border runs
    /// where this falls to zero and it changes smoothly, so outlines drawn from it are
    /// anti-aliased instead of following the pixel staircase.
    public let margins: [UInt8]

    /// A scale that makes the longest side about `targetLongSide` pixels.
    public static func recommendedScale(for puzzle: Puzzle, targetLongSide: Int = 2000) -> Int {
        let longest = max(puzzle.width, puzzle.height)
        return max(2, min(16, Int((Double(targetLongSide) / Double(longest)).rounded())))
    }

    /// - Parameters:
    ///   - scale: High-res pixels per working pixel along each axis.
    ///   - smoothing: Standard deviation, in working pixels, of the Gaussian that rounds outlines.
    public init(puzzle: Puzzle, scale: Int, smoothing: Float = 1.0) {
        precondition(scale >= 1, "Scale must be positive")
        let sw = puzzle.width, sh = puzzle.height
        let w = sw * scale, h = sh * scale
        self.scale = scale
        width = w
        height = h

        // For each sub-pixel phase: Gaussian weights of the five nearest working pixels
        // (offsets -2...2 from the pixel's own cell) along one axis.
        let radius = 2
        let phases: [[Float]] = (0..<scale).map { phase in
            let position = (Double(phase) + 0.5) / Double(scale) - 0.5
            return (-radius...radius).map { offset in
                let d = Double(offset) - position
                return Float(exp(-d * d / (2 * Double(smoothing * smoothing))))
            }
        }

        let source = puzzle.regionMap
        // A working pixel whose 5×5 neighborhood is one region maps straight through.
        var uniform = [Bool](repeating: false, count: sw * sh)
        for y in 0..<sh {
            for x in 0..<sw {
                let id = source[y * sw + x]
                var same = true
                outer: for dy in -2...2 {
                    let ny = min(max(y + dy, 0), sh - 1)
                    for dx in -2...2 {
                        let nx = min(max(x + dx, 0), sw - 1)
                        if source[ny * sw + nx] != id {
                            same = false
                            break outer
                        }
                    }
                }
                uniform[y * sw + x] = same
            }
        }

        var labels = [UInt16](repeating: 0, count: w * h)
        var margins = [UInt8](repeating: 255, count: w * h)
        let taps = 2 * radius + 1
        var candidateIDs = [UInt16](repeating: 0, count: taps * taps)
        var candidateWeights = [Float](repeating: 0, count: taps * taps)
        for y in 0..<h {
            let cellY = y / scale
            let weightsY = phases[y % scale]
            for x in 0..<w {
                let cellX = x / scale
                let cell = cellY * sw + cellX
                if uniform[cell] {
                    labels[y * w + x] = source[cell]
                    continue
                }
                let weightsX = phases[x % scale]
                var count = 0
                for j in 0..<taps {
                    let sy = min(max(cellY - radius + j, 0), sh - 1)
                    let wy = weightsY[j]
                    for i in 0..<taps {
                        let sx = min(max(cellX - radius + i, 0), sw - 1)
                        let id = source[sy * sw + sx]
                        let weight = wy * weightsX[i]
                        var slot = 0
                        while slot < count && candidateIDs[slot] != id { slot += 1 }
                        if slot == count {
                            candidateIDs[slot] = id
                            candidateWeights[slot] = weight
                            count += 1
                        } else {
                            candidateWeights[slot] += weight
                        }
                    }
                }
                // Ties go to the pixel's own region so nothing shifts without reason.
                let own = source[cell]
                var best = own
                var bestWeight: Float = -1
                var runnerUpWeight: Float = 0
                for slot in 0..<count {
                    let weight = candidateWeights[slot]
                    if weight > bestWeight || (weight == bestWeight && candidateIDs[slot] == own) {
                        runnerUpWeight = max(runnerUpWeight, bestWeight)
                        best = candidateIDs[slot]
                        bestWeight = weight
                    } else {
                        runnerUpWeight = max(runnerUpWeight, weight)
                    }
                }
                labels[y * w + x] = best
                margins[y * w + x] = UInt8(min(255, ((bestWeight - runnerUpWeight) * 64).rounded()))
            }
        }

        // Smoothing can swallow a slim region. Put back any region that lost too much, and make
        // sure every number sits on its own region.
        var detailArea = [Int](repeating: 0, count: puzzle.regions.count)
        for id in labels { detailArea[Int(id)] += 1 }
        for (id, region) in puzzle.regions.enumerated() {
            let labelX = min(w - 1, Int(region.labelX * Float(scale)))
            let labelY = min(h - 1, Int(region.labelY * Float(scale)))
            let lostTooMuch = detailArea[id] * 10 < region.area * scale * scale * 6
            guard lostTooMuch || Int(labels[labelY * w + labelX]) != id else { continue }
            for sy in region.minY...region.maxY {
                for sx in region.minX...region.maxX where Int(source[sy * sw + sx]) == id {
                    for y in (sy * scale)..<((sy + 1) * scale) {
                        for x in (sx * scale)..<((sx + 1) * scale) {
                            labels[y * w + x] = UInt16(id)
                            margins[y * w + x] = 255
                        }
                    }
                }
            }
        }

        var bounds = [PixelBounds](repeating: .empty, count: puzzle.regions.count)
        for y in 0..<h {
            for x in 0..<w {
                let id = Int(labels[y * w + x])
                if x < bounds[id].minX { bounds[id].minX = x }
                if x > bounds[id].maxX { bounds[id].maxX = x }
                if y < bounds[id].minY { bounds[id].minY = y }
                if y > bounds[id].maxY { bounds[id].maxY = y }
            }
        }
        self.labels = labels
        self.margins = margins
        self.bounds = bounds
    }

    /// The region under a high-res pixel, or `nil` outside the picture.
    @inline(__always)
    public func region(atX x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return Int(labels[y * width + x])
    }
}

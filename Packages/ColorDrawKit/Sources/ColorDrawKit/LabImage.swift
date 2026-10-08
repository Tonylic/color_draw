import Foundation

/// An image stored as three planes of CIE L*a*b* values.
struct LabImage: Sendable {
    let width: Int
    let height: Int
    var l: [Float]
    var a: [Float]
    var b: [Float]

    var count: Int { width * height }

    init(_ image: RGBAImage) {
        width = image.width
        height = image.height
        let n = image.width * image.height
        var l = [Float](repeating: 0, count: n)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        // Photos repeat colors a lot, so cache conversions.
        var cache: [UInt32: LabColor] = [:]
        image.pixels.withUnsafeBufferPointer { px in
            for i in 0..<n {
                let r = px[i * 4], g = px[i * 4 + 1], bl = px[i * 4 + 2]
                let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(bl)
                let lab: LabColor
                if let cached = cache[key] {
                    lab = cached
                } else {
                    lab = ColorMath.lab(r: r, g: g, b: bl)
                    if cache.count < 200_000 { cache[key] = lab }
                }
                l[i] = lab.l
                a[i] = lab.a
                b[i] = lab.b
            }
        }
        self.l = l
        self.a = a
        self.b = b
    }

    @inline(__always)
    func color(at index: Int) -> LabColor {
        LabColor(l: l[index], a: a[index], b: b[index])
    }

    /// Edge-preserving smoothing: flattens texture and noise (grass, skin, sensor noise)
    /// while keeping the outlines between differently colored areas sharp.
    mutating func applyBilateralFilter(radius: Int, sigmaSpace: Float, sigmaColor: Float) {
        guard radius > 0 else { return }
        let w = width, h = height
        let diameter = 2 * radius + 1
        var spatial = [Float](repeating: 0, count: diameter * diameter)
        for dy in -radius...radius {
            for dx in -radius...radius {
                let d2 = Float(dx * dx + dy * dy)
                spatial[(dy + radius) * diameter + dx + radius] = expf(-d2 / (2 * sigmaSpace * sigmaSpace))
            }
        }
        // Color weights come from a table indexed by squared distance (in steps of 0.5 ΔE²).
        let tableSize = 4096
        let tableStep: Float = 2
        let colorTable = (0..<tableSize).map { expf(-(Float($0) / tableStep) / (2 * sigmaColor * sigmaColor)) }

        var outL = l, outA = a, outB = b
        l.withUnsafeBufferPointer { L in
            a.withUnsafeBufferPointer { A in
                b.withUnsafeBufferPointer { B in
                    spatial.withUnsafeBufferPointer { S in
                        colorTable.withUnsafeBufferPointer { C in
                            for y in 0..<h {
                                let y0 = max(0, y - radius), y1 = min(h - 1, y + radius)
                                for x in 0..<w {
                                    let x0 = max(0, x - radius), x1 = min(w - 1, x + radius)
                                    let center = y * w + x
                                    let cl = L[center], ca = A[center], cb = B[center]
                                    var sumL: Float = 0, sumA: Float = 0, sumB: Float = 0, sumW: Float = 0
                                    for ny in y0...y1 {
                                        let rowBase = ny * w
                                        let spatialRow = (ny - y + radius) * diameter + radius - x
                                        for nx in x0...x1 {
                                            let i = rowBase + nx
                                            let dl = L[i] - cl, da = A[i] - ca, db = B[i] - cb
                                            let slot = Int((dl * dl + da * da + db * db) * tableStep)
                                            guard slot < tableSize else { continue }
                                            let weight = S[spatialRow + nx] * C[slot]
                                            sumL += L[i] * weight
                                            sumA += A[i] * weight
                                            sumB += B[i] * weight
                                            sumW += weight
                                        }
                                    }
                                    outL[center] = sumL / sumW
                                    outA[center] = sumA / sumW
                                    outB[center] = sumB / sumW
                                }
                            }
                        }
                    }
                }
            }
        }
        l = outL
        a = outA
        b = outB
    }
}

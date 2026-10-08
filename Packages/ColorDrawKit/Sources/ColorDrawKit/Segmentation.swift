import Foundation

/// Turns a per-pixel color index map into paintable regions.
enum Segmentation {
    /// Connected areas of equal color index (4-connectivity).
    struct Components {
        let width: Int
        let height: Int
        /// Region id for every pixel.
        var labels: [Int32]
        /// Color index of each region.
        var colors: [UInt8]
        /// Pixel count of each region.
        var areas: [Int]

        var count: Int { colors.count }
    }

    /// Replaces every pixel by the most common color among its 3×3 neighborhood. Removes speckles
    /// and one-pixel-wide slivers that would be impossible to paint. Ties keep the current color.
    static func majorityFilter(_ indices: [UInt8], width: Int, height: Int, passes: Int) -> [UInt8] {
        guard width > 2, height > 2, passes > 0 else { return indices }
        var current = indices
        var next = indices
        var window = [UInt8](repeating: 0, count: 9)
        for _ in 0..<passes {
            var changed = false
            for y in 0..<height {
                for x in 0..<width {
                    var n = 0
                    for dy in -1...1 {
                        let ny = min(max(y + dy, 0), height - 1)
                        for dx in -1...1 {
                            let nx = min(max(x + dx, 0), width - 1)
                            window[n] = current[ny * width + nx]
                            n += 1
                        }
                    }
                    let center = current[y * width + x]
                    var best = center
                    var bestCount = 0
                    for i in 0..<9 {
                        let candidate = window[i]
                        var count = 0
                        for j in 0..<9 where window[j] == candidate { count += 1 }
                        if count > bestCount || (count == bestCount && candidate == center) {
                            best = candidate
                            bestCount = count
                        }
                    }
                    next[y * width + x] = best
                    if best != center { changed = true }
                }
            }
            swap(&current, &next)
            if !changed { break }
        }
        return current
    }

    static func connectedComponents(_ indices: [UInt8], width: Int, height: Int) -> Components {
        let n = width * height
        var labels = [Int32](repeating: -1, count: n)
        var colors: [UInt8] = []
        var areas: [Int] = []
        var stack: [Int32] = []
        stack.reserveCapacity(1024)

        for start in 0..<n where labels[start] < 0 {
            let id = Int32(colors.count)
            let color = indices[start]
            var area = 0
            labels[start] = id
            stack.append(Int32(start))
            while let last = stack.popLast() {
                let p = Int(last)
                area += 1
                let x = p % width
                if x > 0, labels[p - 1] < 0, indices[p - 1] == color {
                    labels[p - 1] = id
                    stack.append(Int32(p - 1))
                }
                if x < width - 1, labels[p + 1] < 0, indices[p + 1] == color {
                    labels[p + 1] = id
                    stack.append(Int32(p + 1))
                }
                if p >= width, labels[p - width] < 0, indices[p - width] == color {
                    labels[p - width] = id
                    stack.append(Int32(p - width))
                }
                if p + width < n, labels[p + width] < 0, indices[p + width] == color {
                    labels[p + width] = id
                    stack.append(Int32(p + width))
                }
            }
            colors.append(color)
            areas.append(area)
        }
        return Components(width: width, height: height, labels: labels, colors: colors, areas: areas)
    }

    /// Squared distance from every pixel to the nearest edge of its region (or of the image),
    /// via the exact Felzenszwalb–Huttenlocher Euclidean distance transform.
    static func edgeDistanceSquared(_ labels: [Int32], width: Int, height: Int) -> [Float] {
        let far: Float = 1e20
        var grid = [Float](repeating: far, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let id = labels[p]
                let isEdge = x == 0 || y == 0 || x == width - 1 || y == height - 1
                    || labels[p - 1] != id || labels[p + 1] != id
                    || labels[p - width] != id || labels[p + width] != id
                if isEdge { grid[p] = 0 }
            }
        }

        let longest = max(width, height)
        var f = [Float](repeating: 0, count: longest)
        var d = [Float](repeating: 0, count: longest)
        var v = [Int](repeating: 0, count: longest)
        var z = [Float](repeating: 0, count: longest + 1)

        for x in 0..<width {
            for y in 0..<height { f[y] = grid[y * width + x] }
            distanceTransform1D(f, count: height, output: &d, v: &v, z: &z)
            for y in 0..<height { grid[y * width + x] = d[y] }
        }
        for y in 0..<height {
            for x in 0..<width { f[x] = grid[y * width + x] }
            distanceTransform1D(f, count: width, output: &d, v: &v, z: &z)
            for x in 0..<width { grid[y * width + x] = d[x] }
        }
        return grid
    }

    private static func distanceTransform1D(_ f: [Float], count n: Int, output d: inout [Float], v: inout [Int], z: inout [Float]) {
        var k = 0
        v[0] = 0
        z[0] = -.infinity
        z[1] = .infinity
        if n > 1 {
            for q in 1..<n {
                let fq = f[q] + Float(q * q)
                var s = (fq - (f[v[k]] + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
                while s <= z[k] {
                    k -= 1
                    s = (fq - (f[v[k]] + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = .infinity
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let diff = Float(q - v[k])
            d[q] = diff * diff + f[v[k]]
        }
    }

    /// For each region: a spot deep inside it (the best place for its number) and the radius of
    /// the largest circle centered there that stays inside the region. Among nearly-deepest spots
    /// the one closest to the region's center of mass wins, which looks more natural.
    static func labelPlacement(_ components: Components, distances: [Float]) -> [(x: Int, y: Int, radius: Float)] {
        let width = components.width
        let count = components.count
        var deepest = [Float](repeating: 0, count: count)
        var sumX = [Double](repeating: 0, count: count)
        var sumY = [Double](repeating: 0, count: count)
        for (p, id32) in components.labels.enumerated() {
            let id = Int(id32)
            deepest[id] = max(deepest[id], distances[p].squareRoot())
            sumX[id] += Double(p % width)
            sumY[id] += Double(p / width)
        }
        var best = [(x: Int, y: Int, radius: Float)](repeating: (0, 0, 0), count: count)
        var bestCentrality = [Double](repeating: .infinity, count: count)
        for (p, id32) in components.labels.enumerated() {
            let id = Int(id32)
            let depth = distances[p].squareRoot()
            guard depth >= max(deepest[id] - 1, deepest[id] * 0.85) else { continue }
            let x = p % width, y = p / width
            let area = Double(components.areas[id])
            let dx = Double(x) - sumX[id] / area, dy = Double(y) - sumY[id] / area
            let centrality = dx * dx + dy * dy
            if centrality < bestCentrality[id] {
                bestCentrality[id] = centrality
                best[id] = (x, y, depth + 0.5)
            }
        }
        return best
    }

    /// Repeatedly folds regions that are too small or too thin to paint into their best neighbor,
    /// and, while there are more than `maximumCount` regions, the smallest remaining ones too (so
    /// the biggest, most recognizable shapes are the ones that survive).
    /// Returns the cleaned color index map.
    static func mergeTinyRegions(
        _ indices: [UInt8],
        palette: [LabColor],
        width: Int,
        height: Int,
        minimumArea: Int,
        minimumRadius: Float,
        maximumCount: Int = .max,
        maximumPasses: Int = 20
    ) -> [UInt8] {
        var indices = indices
        for _ in 0..<maximumPasses {
            let components = connectedComponents(indices, width: width, height: height)
            let distances = edgeDistanceSquared(components.labels, width: width, height: height)
            var deepest = [Float](repeating: 0, count: components.count)
            for (p, id) in components.labels.enumerated() {
                deepest[Int(id)] = max(deepest[Int(id)], distances[p])
            }
            let minimumDepthSquared = max(0, minimumRadius - 0.5) * max(0, minimumRadius - 0.5)
            var isTiny = (0..<components.count).map { id in
                components.areas[id] < minimumArea || deepest[id] < minimumDepthSquared
            }
            // Still too many shapes for this level: fold the smallest of the rest as well.
            let excess = (components.count - isTiny.lazy.filter { $0 }.count) - max(1, maximumCount)
            if excess > 0 {
                let smallest = (0..<components.count).filter { !isTiny[$0] }.sorted { components.areas[$0] < components.areas[$1] }
                for id in smallest.prefix(excess) { isTiny[id] = true }
            }
            guard isTiny.contains(true), components.count > 1 else { break }

            // Shared border length between neighboring regions.
            var borders: [UInt64: Int] = [:]
            func addBorder(_ a: Int32, _ b: Int32) {
                let key = UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
                borders[key, default: 0] += 1
            }
            for y in 0..<height {
                for x in 0..<width {
                    let p = y * width + x
                    let id = components.labels[p]
                    if x + 1 < width, components.labels[p + 1] != id { addBorder(id, components.labels[p + 1]) }
                    if y + 1 < height, components.labels[p + width] != id { addBorder(id, components.labels[p + width]) }
                }
            }
            var neighbors = [[(id: Int, length: Int)]](repeating: [], count: components.count)
            for (key, length) in borders {
                let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
                neighbors[a].append((b, length))
                neighbors[b].append((a, length))
            }

            // Union-find so chains of merges resolve to their final region.
            var parent = Array(0..<components.count)
            func root(_ id: Int) -> Int {
                var r = id
                while parent[r] != r { r = parent[r] }
                var c = id
                while parent[c] != r {
                    let next = parent[c]
                    parent[c] = r
                    c = next
                }
                return r
            }
            var area = components.areas
            let color = components.colors.map(Int.init)
            var settled = isTiny.map { !$0 }

            let order = (0..<components.count).filter { isTiny[$0] }.sorted { components.areas[$0] < components.areas[$1] }
            for id in order {
                // Total border with each distinct (already merged) neighbor.
                var candidates: [Int: Int] = [:]
                for neighbor in neighbors[id] {
                    let r = root(neighbor.id)
                    if r != id { candidates[r, default: 0] += neighbor.length }
                }
                guard !candidates.isEmpty else { continue }
                let own = palette[color[id]]
                let target = candidates.max { lhs, rhs in
                    // Prefer big, settled neighbors; then the longest shared border; then the closest color.
                    if settled[lhs.key] != settled[rhs.key] { return !settled[lhs.key] }
                    if lhs.value != rhs.value { return lhs.value < rhs.value }
                    return own.distanceSquared(to: palette[color[lhs.key]]) > own.distanceSquared(to: palette[color[rhs.key]])
                }!.key
                parent[id] = target
                area[target] += area[id]
                if area[target] >= minimumArea { settled[target] = true }
            }

            var changed = false
            for p in indices.indices {
                let r = root(Int(components.labels[p]))
                let newColor = UInt8(color[r])
                if indices[p] != newColor {
                    indices[p] = newColor
                    changed = true
                }
            }
            if !changed { break }
        }
        return indices
    }
}

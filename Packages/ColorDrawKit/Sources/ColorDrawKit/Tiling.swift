import Foundation

/// A photo cut into a grid of regular tiles, like a mosaic: every tile is a shape of its own.
/// Tile edges stay perfectly crisp (so faces stay recognizable), and neighboring tiles often share
/// a color, so one swipe paints a whole run of them.
public struct Tiling: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable {
        case squares
        /// Equilateral triangles in rows, alternately pointing up and down. The picture's left and
        /// right edges cut the first and last triangle of every row in half.
        case triangles
    }

    public let shape: Shape
    /// Tiles per row.
    public let columns: Int
    public let rows: Int

    public init(shape: Shape, columns: Int, rows: Int) {
        self.shape = shape
        self.columns = columns
        self.rows = rows
    }

    public var tileCount: Int { columns * rows }

    /// Region ids are 16-bit, so a puzzle has at most this many tiles.
    public static let maximumTileCount = Int(UInt16.max)

    /// Whether the layout makes sense at all (triangle rows need a left and a right half).
    var isValid: Bool {
        rows >= 1 && columns >= (shape == .triangles ? 2 : 1) && columns <= 4096 && rows <= 4096
            && tileCount <= Self.maximumTileCount
    }

    @inline(__always)
    public func position(of tile: Int) -> (row: Int, column: Int) {
        (tile / columns, tile % columns)
    }

    /// Whether a triangle points up: its tip at the top, its flat side at the bottom.
    @inline(__always)
    public func pointsUp(row: Int, column: Int) -> Bool {
        (row + column).isMultiple(of: 2)
    }

    /// The tiles sharing an edge with `tile`.
    public func neighbors(of tile: Int) -> [Int] {
        let (row, column) = position(of: tile)
        var result: [Int] = []
        result.reserveCapacity(4)
        if column > 0 { result.append(tile - 1) }
        if column + 1 < columns { result.append(tile + 1) }
        switch shape {
        case .squares:
            if row > 0 { result.append(tile - columns) }
            if row + 1 < rows { result.append(tile + columns) }
        case .triangles:
            // A triangle's flat side touches the row it faces.
            if pointsUp(row: row, column: column) {
                if row + 1 < rows { result.append(tile + columns) }
            } else if row > 0 {
                result.append(tile - columns)
            }
        }
        return result
    }
}

/// A tiling stretched over a picture of a given size (in working pixels, or any other unit).
struct TileLayout {
    let tiling: Tiling
    let width: Double
    let height: Double
    /// Squares: a tile's width. Triangles: the horizontal distance between neighboring
    /// triangles' centers, which is half a side.
    let step: Double
    let rowHeight: Double
    /// Triangles: the length of a slanted side.
    private let sideLength: Double

    init(_ tiling: Tiling, width: Double, height: Double) {
        self.tiling = tiling
        self.width = width
        self.height = height
        rowHeight = height / Double(tiling.rows)
        switch tiling.shape {
        case .squares: step = width / Double(tiling.columns)
        case .triangles: step = width / Double(max(1, tiling.columns - 1))
        }
        sideLength = (step * step + rowHeight * rowHeight).squareRoot()
    }

    /// The tile under a point. Points outside the picture get the nearest tile along each axis.
    @inline(__always)
    func tile(atX x: Double, y: Double) -> Int {
        let columns = tiling.columns
        let row = min(max(Int((y / rowHeight).rounded(.down)), 0), tiling.rows - 1)
        switch tiling.shape {
        case .squares:
            let column = min(max(Int((x / step).rounded(.down)), 0), columns - 1)
            return row * columns + column
        case .triangles:
            // Between the centers of triangles `left` and `left + 1`, a slanted edge splits the row.
            let u = x / step
            let left = min(max(Int(u.rounded(.down)), 0), columns - 2)
            let fx = u - Double(left)
            let fy = y / rowHeight - Double(row)
            let isLeft = tiling.pointsUp(row: row, column: left) ? fx < fy : fx + fy < 1
            return row * columns + (isLeft ? left : left + 1)
        }
    }

    /// How far a point inside `tile` is from the nearest edge it shares with another tile — where
    /// grid lines are drawn. The picture's own border doesn't count.
    @inline(__always)
    func distanceToSharedEdge(x: Double, y: Double, tile: Int) -> Double {
        let (row, column) = tiling.position(of: tile)
        let top = Double(row) * rowHeight, bottom = top + rowHeight
        var distance = Double.infinity
        switch tiling.shape {
        case .squares:
            let left = Double(column) * step
            if column > 0 { distance = min(distance, x - left) }
            if column + 1 < tiling.columns { distance = min(distance, left + step - x) }
            if row > 0 { distance = min(distance, y - top) }
            if row + 1 < tiling.rows { distance = min(distance, bottom - y) }
        case .triangles:
            let up = tiling.pointsUp(row: row, column: column)
            // The flat side.
            if up, row + 1 < tiling.rows { distance = min(distance, bottom - y) }
            if !up, row > 0 { distance = min(distance, y - top) }
            // The slanted sides run from the tip to the flat side's corners.
            let center = Double(column) * step
            let tipY = up ? top : bottom
            let rise = (up ? rowHeight : -rowHeight) * (x - center)
            if column > 0 { distance = min(distance, abs(-step * (y - tipY) - rise) / sideLength) }
            if column + 1 < tiling.columns { distance = min(distance, abs(step * (y - tipY) - rise) / sideLength) }
        }
        return distance
    }

    /// A tile's corners, clockwise, cut off at the picture's edges.
    func corners(of tile: Int) -> [(x: Double, y: Double)] {
        let (row, column) = tiling.position(of: tile)
        let top = Double(row) * rowHeight, bottom = top + rowHeight
        switch tiling.shape {
        case .squares:
            let left = Double(column) * step, right = left + step
            return [(left, top), (right, top), (right, bottom), (left, bottom)]
        case .triangles:
            let center = Double(column) * step
            // The edge triangles' tips lie exactly on the picture's border, so clamping the
            // corners that stick out cuts them neatly in half.
            func clamp(_ x: Double) -> Double { min(max(x, 0), width) }
            if tiling.pointsUp(row: row, column: column) {
                return [(center, top), (clamp(center + step), bottom), (clamp(center - step), bottom)]
            }
            return [(clamp(center - step), top), (clamp(center + step), top), (center, bottom)]
        }
    }

    /// Where a tile's number goes — the center of the biggest circle inside it — and that
    /// circle's radius.
    func label(of tile: Int) -> (x: Double, y: Double, radius: Double) {
        let corners = corners(of: tile)
        if corners.count == 4 {
            return ((corners[0].x + corners[1].x) / 2, (corners[0].y + corners[2].y) / 2, min(step, rowHeight) / 2)
        }
        // A triangle's incircle: the corners weighted by the opposite sides' lengths.
        let (a, b, c) = (corners[0], corners[1], corners[2])
        func length(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double)) -> Double {
            ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
        }
        let la = length(b, c), lb = length(c, a), lc = length(a, b)
        let perimeter = la + lb + lc
        let doubleArea = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y))
        return (
            (la * a.x + lb * b.x + lc * c.x) / perimeter,
            (la * a.y + lb * b.y + lc * c.y) / perimeter,
            doubleArea / perimeter
        )
    }
}

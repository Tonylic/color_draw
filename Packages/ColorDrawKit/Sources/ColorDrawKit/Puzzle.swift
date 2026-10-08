import Foundation

/// One paintable area of a puzzle.
public struct PuzzleRegion: Codable, Hashable, Sendable {
    /// Index into `Puzzle.palette`. The number shown to the child is `colorIndex + 1`.
    public var colorIndex: Int
    /// Size in working pixels.
    public var area: Int
    /// Where to print the number, in working-pixel coordinates (pixel centers are at +0.5).
    public var labelX: Float
    public var labelY: Float
    /// Radius of the largest circle around the label point that fits inside the region.
    public var labelRadius: Float
    /// Bounding box in working pixels (inclusive).
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public init(colorIndex: Int, area: Int, labelX: Float, labelY: Float, labelRadius: Float, minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.colorIndex = colorIndex
        self.area = area
        self.labelX = labelX
        self.labelY = labelY
        self.labelRadius = labelRadius
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

/// A paint-by-number picture: a map of numbered regions plus the palette to paint them with.
public struct Puzzle: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Region index of every working pixel, row-major.
    public let regionMap: [UInt16]
    public let regions: [PuzzleRegion]
    public let palette: [RGBColor]

    public init(width: Int, height: Int, regionMap: [UInt16], regions: [PuzzleRegion], palette: [RGBColor]) {
        precondition(regionMap.count == width * height, "Region map does not match puzzle size")
        self.width = width
        self.height = height
        self.regionMap = regionMap
        self.regions = regions
        self.palette = palette
    }

    @inline(__always)
    public func region(atX x: Int, y: Int) -> Int {
        Int(regionMap[y * width + x])
    }

    /// Region indices grouped by palette color.
    public var regionsByColor: [[Int]] {
        var groups = [[Int]](repeating: [], count: palette.count)
        for (index, region) in regions.enumerated() {
            groups[region.colorIndex].append(index)
        }
        return groups
    }

    // MARK: Codable — the region map is stored as raw little-endian bytes to keep files small.

    private enum CodingKeys: String, CodingKey {
        case version, width, height, regionMap, regions, palette
    }

    public static let formatVersion = 1

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Puzzle format \(version) is newer than this app")
        }
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let data = try container.decode(Data.self, forKey: .regionMap)
        // Puzzles are small; anything huge is a corrupt file (and must not overflow the math below).
        guard (1...4096).contains(width), (1...4096).contains(height), data.count == width * height * 2 else {
            throw DecodingError.dataCorruptedError(forKey: .regionMap, in: container, debugDescription: "Region map has the wrong size")
        }
        self.width = width
        self.height = height
        regionMap = data.withUnsafeBytes { raw in
            (0..<(width * height)).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        regions = try container.decode([PuzzleRegion].self, forKey: .regions)
        palette = try container.decode([RGBColor].self, forKey: .palette)
        let regionsAreValid = regions.allSatisfy { region in
            palette.indices.contains(region.colorIndex)
                && region.area > 0
                && 0 <= region.minX && region.minX <= region.maxX && region.maxX < width
                && 0 <= region.minY && region.minY <= region.maxY && region.maxY < height
                && (0..<Float(width)).contains(region.labelX) && (0..<Float(height)).contains(region.labelY)
                && region.labelRadius.isFinite && region.labelRadius > 0
        }
        guard regionsAreValid, regionMap.allSatisfy({ Int($0) < regions.count }) else {
            throw DecodingError.dataCorruptedError(forKey: .regions, in: container, debugDescription: "Puzzle references missing regions or colors")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        var data = Data(capacity: regionMap.count * 2)
        for value in regionMap {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        try container.encode(data, forKey: .regionMap)
        try container.encode(regions, forKey: .regions)
        try container.encode(palette, forKey: .palette)
    }
}

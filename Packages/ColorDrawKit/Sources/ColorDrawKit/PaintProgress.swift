import Foundation

/// The rules of painting: which regions are done, how many of each color are left, and what
/// happens when a child taps a region with the selected color.
public struct PaintProgress: Equatable, Sendable {
    public enum FillResult: Equatable, Sendable {
        /// The region got painted. `colorFinished` / `pictureFinished` say whether that was the
        /// last region of its color / of the whole picture.
        case filled(colorFinished: Bool, pictureFinished: Bool)
        case alreadyFilled
        /// The selected color does not belong here; `expected` is the color that does.
        case wrongColor(expected: Int)
    }

    private let regionColors: [Int]
    public private(set) var filled: [Bool]
    public private(set) var remainingByColor: [Int]
    public private(set) var filledCount: Int

    public init(puzzle: Puzzle, filledRegions: some Sequence<Int> = []) {
        regionColors = puzzle.regions.map(\.colorIndex)
        filled = [Bool](repeating: false, count: puzzle.regions.count)
        remainingByColor = [Int](repeating: 0, count: puzzle.palette.count)
        for color in regionColors { remainingByColor[color] += 1 }
        filledCount = 0
        for region in filledRegions where filled.indices.contains(region) && !filled[region] {
            filled[region] = true
            remainingByColor[regionColors[region]] -= 1
            filledCount += 1
        }
    }

    public var regionCount: Int { filled.count }
    public var isComplete: Bool { filledCount == filled.count }
    public var fraction: Double { filled.isEmpty ? 1 : Double(filledCount) / Double(filled.count) }
    public var filledRegions: [Int] { filled.indices.filter { filled[$0] } }

    public func isFinished(color: Int) -> Bool { remainingByColor[color] == 0 }

    public func color(of region: Int) -> Int { regionColors[region] }

    /// The first unfinished color after `color`, wrapping around; `nil` when everything is painted.
    public func nextUnfinishedColor(after color: Int) -> Int? {
        let count = remainingByColor.count
        guard count > 0 else { return nil }
        for step in 1...count {
            let candidate = (color + step) % count
            if remainingByColor[candidate] > 0 { return candidate }
        }
        return nil
    }

    public mutating func fill(region: Int, with selectedColor: Int) -> FillResult {
        guard !filled[region] else { return .alreadyFilled }
        let expected = regionColors[region]
        guard expected == selectedColor else { return .wrongColor(expected: expected) }
        filled[region] = true
        remainingByColor[expected] -= 1
        filledCount += 1
        return .filled(colorFinished: remainingByColor[expected] == 0, pictureFinished: isComplete)
    }
}

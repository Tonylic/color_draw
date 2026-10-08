import CoreGraphics
import Foundation
import Testing
@testable import ColorDrawKit

/// Drag painting: a swipe must find every shape it brushes, however fast it goes.
@Suite("Brush strokes")
struct BrushTests {
    /// Vertical stripes 1 working pixel wide (the slimmest shapes a puzzle can have, scaled up),
    /// alternating two colors, so a horizontal swipe crosses many separate shapes.
    func makeStripes(count: Int = 40) -> (Puzzle, DetailMap) {
        let width = count * 3, height = 12
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where (x / 3).isMultiple(of: 2) {
                let i = (y * width + x) * 4
                pixels[i] = 220; pixels[i + 1] = 40; pixels[i + 2] = 40
            }
        }
        let settings = PuzzleSettings(colorCount: 4, maxDimension: width, minimumRegionArea: 1, minimumRegionRadius: 0, smoothingPasses: 0, minimumColorDistance: 0)
        let puzzle = PuzzleGenerator.generate(from: RGBAImage(width: width, height: height, pixels: pixels), settings: settings)
        return (puzzle, DetailMap(puzzle: puzzle, scale: 5))
    }

    @Test func oneLongFastSwipeFindsEveryShapeItCrosses() {
        let (puzzle, detail) = makeStripes()
        #expect(puzzle.regions.count == 40)
        // A single jump from one edge to the other, like a flick that produced only two touch events.
        let y = CGFloat(detail.height) / 2
        let found = detail.regions(alongSegmentFrom: CGPoint(x: 2, y: y), to: CGPoint(x: CGFloat(detail.width) - 2, y: y), radius: 6)
        #expect(Set(found).count == puzzle.regions.count, "Every stripe is reached")
        // In the order the swipe reaches them, left to right.
        let xs = found.map { puzzle.regions[$0].minX }
        #expect(xs == xs.sorted())
    }

    @Test func aWiderBrushReachesShapesBesideThePath() {
        let (_, detail) = makeStripes()
        let y = CGFloat(detail.height) / 2
        // A tap-sized "swipe" between two stripes: a tiny brush sees one shape, a finger-sized one
        // also the neighbors.
        let x = CGFloat(3 * 5 * 10 + 7)
        let narrow = detail.regions(alongSegmentFrom: CGPoint(x: x, y: y), to: CGPoint(x: x, y: y), radius: 1)
        let wide = detail.regions(alongSegmentFrom: CGPoint(x: x, y: y), to: CGPoint(x: x, y: y), radius: 20)
        #expect(narrow.count == 1)
        #expect(wide.count >= 3)
        #expect(wide.first == narrow.first, "The shape under the finger comes first")
    }

    @Test func strokesOffThePictureAreHarmless() {
        let (_, detail) = makeStripes()
        #expect(detail.regions(alongSegmentFrom: CGPoint(x: -500, y: -500), to: CGPoint(x: -400, y: -450), radius: 10).isEmpty)
        let edge = detail.regions(alongSegmentFrom: CGPoint(x: -50, y: 10), to: CGPoint(x: 30, y: 10), radius: 4)
        #expect(!edge.isEmpty)
    }
}

import Foundation
import Testing
@testable import ColorDrawKit

@Suite("Segmentation building blocks")
struct SegmentationTests {
    @Test func distanceTransformMatchesBruteForce() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<10 {
            let width = Int.random(in: 3...24, using: &rng), height = Int.random(in: 3...24, using: &rng)
            // Blocky random regions.
            let labels: [Int32] = (0..<(width * height)).map { p in
                Int32(((p % width) / Int.random(in: 2...5, using: &rng) + (p / width) / 3) % 4)
            }
            let fast = Segmentation.edgeDistanceSquared(labels, width: width, height: height)

            var edges: [(Int, Int)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let p = y * width + x, id = labels[p]
                    let edge = x == 0 || y == 0 || x == width - 1 || y == height - 1
                        || labels[p - 1] != id || labels[p + 1] != id || labels[p - width] != id || labels[p + width] != id
                    if edge { edges.append((x, y)) }
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    let brute = edges.map { Float(($0.0 - x) * ($0.0 - x) + ($0.1 - y) * ($0.1 - y)) }.min()!
                    #expect(fast[y * width + x] == brute)
                }
            }
        }
    }

    @Test func connectedComponentsSplitSameColoredAreasThatDontTouch() {
        // Two red squares separated by a blue column.
        let indices: [UInt8] = [
            0, 0, 1, 0, 0,
            0, 0, 1, 0, 0,
        ]
        let components = Segmentation.connectedComponents(indices, width: 5, height: 2)
        #expect(components.count == 3)
        #expect(components.areas.sorted() == [2, 4, 4])
        #expect(components.labels[0] != components.labels[3])
    }

    @Test func specksAreFoldedIntoTheirSurroundings() {
        // A 20×20 field of color 0 with a 2×2 speck of color 1 and a 1-pixel-wide line of color 2.
        var indices = [UInt8](repeating: 0, count: 400)
        indices[5 * 20 + 5] = 1; indices[5 * 20 + 6] = 1; indices[6 * 20 + 5] = 1; indices[6 * 20 + 6] = 1
        for y in 0..<20 { indices[y * 20 + 14] = 2 }
        let palette = [LabColor(l: 50, a: 0, b: 0), LabColor(l: 60, a: 0, b: 0), LabColor(l: 20, a: 40, b: 0)]
        let cleaned = Segmentation.mergeTinyRegions(indices, palette: palette, width: 20, height: 20, minimumArea: 10, minimumRadius: 1.5)
        #expect(cleaned.allSatisfy { $0 == 0 }, "The speck and the thin line are both too small to paint")
    }

    @Test func bigRegionsSurviveMerging() {
        var indices = [UInt8](repeating: 0, count: 400)
        for y in 0..<20 { for x in 10..<20 { indices[y * 20 + x] = 1 } }
        let palette = [LabColor(l: 50, a: 0, b: 0), LabColor(l: 80, a: 0, b: 0)]
        let cleaned = Segmentation.mergeTinyRegions(indices, palette: palette, width: 20, height: 20, minimumArea: 10, minimumRadius: 1.5)
        #expect(cleaned == indices)
    }

    @Test func majorityFilterRemovesSaltAndPepper() {
        var indices = [UInt8](repeating: 3, count: 100)
        indices[44] = 7
        indices[55] = 1
        let filtered = Segmentation.majorityFilter(indices, width: 10, height: 10, passes: 1)
        #expect(filtered.allSatisfy { $0 == 3 })
    }

    @Test func numbersGoDeepInsideTheirRegion() {
        // An L-shaped region: the label must not land in the corner of the L's bounding box.
        var indices = [UInt8](repeating: 1, count: 30 * 30)
        for y in 0..<30 { for x in 0..<30 where x < 12 || y > 17 { indices[y * 30 + x] = 0 } }
        let components = Segmentation.connectedComponents(indices, width: 30, height: 30)
        let distances = Segmentation.edgeDistanceSquared(components.labels, width: 30, height: 30)
        let labels = Segmentation.labelPlacement(components, distances: distances)
        for (id, label) in labels.enumerated() {
            #expect(components.labels[label.y * 30 + label.x] == Int32(id))
            #expect(label.radius >= 4)
        }
    }
}

import ColorDrawKit
import CoreText
import os
import UIKit

/// Draws the region numbers as crisp vector text at every zoom level.
///
/// A `CATiledLayer` redraws only the tiles it needs, at the resolution of the current zoom, on
/// background threads. All state it reads is behind a lock.
final class NumbersLayer: CATiledLayer, @unchecked Sendable {
    private struct State: Sendable {
        var puzzle: Puzzle?
        var filled: [Bool] = []
        /// Points per working pixel at zoom 1.
        var pixelSize: CGFloat = 1
        var color = CanvasStyle.standard.number
    }

    /// Numbers smaller than this on screen are skipped; zooming in reveals them.
    static let minimumReadableSize: CGFloat = 9

    private let state = OSAllocatedUnfairLock(initialState: State())

    // Core Text fonts are immutable and documented as thread-safe.
    nonisolated(unsafe) private static let baseFont: CTFont = {
        let base = UIFont.systemFont(ofSize: 20, weight: .bold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFont(descriptor: rounded, size: 20) as CTFont
    }()

    override class func fadeDuration() -> CFTimeInterval { 0.12 }

    override init() {
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    /// Core Animation copies layers for rendering; carry the state across.
    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? NumbersLayer {
            let copied = other.state.withLock { $0 }
            state.withLock { $0 = copied }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(puzzle: Puzzle, filled: [Bool], pixelSize: CGFloat, maximumZoom: CGFloat) {
        state.withLock {
            $0.puzzle = puzzle
            $0.filled = filled
            $0.pixelSize = pixelSize
        }
        // Enough detail levels for crisp text all the way to maximum zoom.
        let magnifiedLevels = max(1, Int(ceil(log2(maximumZoom))))
        levelsOfDetailBias = magnifiedLevels
        levelsOfDetail = magnifiedLevels + 2
        setNeedsDisplay()
    }

    /// Hides a painted region's number.
    func markFilled(_ region: Int) {
        let rect: CGRect? = state.withLock { state in
            guard let puzzle = state.puzzle, state.filled.indices.contains(region) else { return nil }
            state.filled[region] = true
            return Self.labelRect(for: puzzle.regions[region], in: puzzle, pixelSize: state.pixelSize)
        }
        if let rect { setNeedsDisplay(rect) }
    }

    override func draw(in context: CGContext) {
        let state = state.withLock { $0 }
        guard let puzzle = state.puzzle else { return }
        let clip = context.boundingBoxOfClipPath
        // Device pixels per point for this tile, divided by the screen scale: the zoom level.
        let zoom = abs(context.ctm.a) / max(contentsScale, 1)
        let color = CGColor(srgbRed: CGFloat(state.color.r) / 255, green: CGFloat(state.color.g) / 255, blue: CGFloat(state.color.b) / 255, alpha: 1)
        var fonts: [Int: CTFont] = [:]

        for (index, region) in puzzle.regions.enumerated() where !state.filled[index] {
            let size = NumberRenderer.fontSize(for: region, in: puzzle, pixelSize: state.pixelSize)
            guard size * zoom >= Self.minimumReadableSize else { continue }
            let rect = Self.labelRect(for: region, in: puzzle, pixelSize: state.pixelSize)
            guard rect.intersects(clip) else { continue }
            // Round sizes so similar numbers share a font.
            let key = Int((size * 4).rounded())
            let font = fonts[key] ?? CTFontCreateCopyWithAttributes(Self.baseFont, CGFloat(key) / 4, nil, nil)
            fonts[key] = font
            let center = CGPoint(x: CGFloat(region.labelX) * state.pixelSize, y: CGFloat(region.labelY) * state.pixelSize)
            NumberRenderer.draw(String(region.colorIndex + 1), centeredAt: center, font: font, color: color, in: context)
        }
    }

    /// Generous bounds of a region's number, in layer coordinates.
    private static func labelRect(for region: PuzzleRegion, in puzzle: Puzzle, pixelSize: CGFloat) -> CGRect {
        let size = NumberRenderer.fontSize(for: region, in: puzzle, pixelSize: pixelSize)
        let center = CGPoint(x: CGFloat(region.labelX) * pixelSize, y: CGFloat(region.labelY) * pixelSize)
        return CGRect(x: center.x - size * 1.4, y: center.y - size, width: size * 2.8, height: size * 2)
    }
}

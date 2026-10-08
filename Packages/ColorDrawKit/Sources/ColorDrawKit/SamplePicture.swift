import CoreGraphics
import Foundation

/// Built-in pictures drawn in code, so children can paint right away without any photos.
public enum SamplePicture: String, CaseIterable, Identifiable, Sendable {
    case kitty, rainbow, fish, house, flower, rocket

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .kitty: "Kitty"
        case .rainbow: "Rainbow"
        case .fish: "Fishy"
        case .house: "House"
        case .flower: "Flower"
        case .rocket: "Rocket"
        }
    }

    /// Settings that keep every little detail (eyes, stars, windows) of the drawings.
    public static let settings = PuzzleSettings(colorCount: 24, maximumRegionCount: 50, maxDimension: 150, minimumRegionArea: 10, minimumRegionRadius: 1.5, smoothingPasses: 0, minimumColorDistance: 0)

    /// Draws the picture without anti-aliasing so it has a handful of exact, flat colors.
    public func render(size: Int = 150) -> RGBAImage {
        RGBAImage.render(width: size, height: size, antialias: false) { context in
            // Draw in a 100 × 100 design space.
            context.scaleBy(x: CGFloat(size) / 100, y: CGFloat(size) / 100)
            let pen = Pen(context: context)
            switch self {
            case .kitty: Self.drawKitty(pen)
            case .rainbow: Self.drawRainbow(pen)
            case .fish: Self.drawFish(pen)
            case .house: Self.drawHouse(pen)
            case .flower: Self.drawFlower(pen)
            case .rocket: Self.drawRocket(pen)
            }
        }!
    }

    public func makePuzzle() -> Puzzle {
        PuzzleGenerator.generate(from: render(size: Self.settings.maxDimension), settings: Self.settings)
    }

    // MARK: - Drawings

    private static func drawKitty(_ p: Pen) {
        p.rect(0, 0, 100, 100, 0xBDE7FF)
        p.rect(0, 84, 100, 16, 0x8CE99A)
        let fur: UInt32 = 0xFFA94D, pink: UInt32 = 0xFF8FAB, dark: UInt32 = 0x3D3A4B
        p.ellipse(cx: 50, cy: 88, rx: 26, ry: 16, fur) // Body.
        p.polygon([(20, 46), (24, 10), (46, 30)], fur) // Ears.
        p.polygon([(80, 46), (76, 10), (54, 30)], fur)
        p.polygon([(26, 36), (27, 19), (39, 30)], pink)
        p.polygon([(74, 36), (73, 19), (61, 30)], pink)
        p.ellipse(cx: 50, cy: 52, rx: 32, ry: 28, fur) // Head.
        p.ellipse(cx: 38, cy: 49, rx: 5.5, ry: 7, dark) // Eyes.
        p.ellipse(cx: 62, cy: 49, rx: 5.5, ry: 7, dark)
        p.ellipse(cx: 40, cy: 46.5, rx: 2.2, ry: 2.2, 0xFFFFFF)
        p.ellipse(cx: 64, cy: 46.5, rx: 2.2, ry: 2.2, 0xFFFFFF)
        p.ellipse(cx: 30, cy: 62, rx: 5, ry: 3.5, pink) // Cheeks.
        p.ellipse(cx: 70, cy: 62, rx: 5, ry: 3.5, pink)
        p.polygon([(45, 58), (55, 58), (50, 64)], 0xE64980) // Nose.
        p.polygon([(36, 76), (64, 76), (58, 82), (42, 82)], 0x845EF7) // Collar.
        p.ellipse(cx: 50, cy: 84, rx: 4, ry: 4, 0xFFD43B) // Bell.
    }

    private static func drawRainbow(_ p: Pen) {
        let sky: UInt32 = 0xA5D8FF
        p.rect(0, 0, 100, 100, sky)
        p.ellipse(cx: 84, cy: 16, rx: 11, ry: 11, 0xFFD43B)
        let bands: [UInt32] = [0xFF6B6B, 0xFFA94D, 0xFFE066, 0x69DB7C, 0x4DABF7, 0x9775FA]
        for (i, color) in bands.enumerated() {
            let r = 46 - CGFloat(i) * 6
            p.ellipse(cx: 50, cy: 86, rx: r, ry: r, color)
        }
        p.ellipse(cx: 50, cy: 86, rx: 10, ry: 10, sky)
        let cloud: UInt32 = 0xFFFFFF
        for (cx, cy) in [(CGFloat(10), CGFloat(80)), (90, 80)] {
            p.ellipse(cx: cx - 7, cy: cy + 2, rx: 8, ry: 7, cloud)
            p.ellipse(cx: cx + 7, cy: cy + 2, rx: 8, ry: 7, cloud)
            p.ellipse(cx: cx, cy: cy - 3, rx: 9, ry: 8, cloud)
        }
        p.ellipse(cx: 22, cy: 22, rx: 9, ry: 6, cloud)
        p.ellipse(cx: 30, cy: 19, rx: 7, ry: 6, cloud)
        p.rect(0, 88, 100, 12, 0x51CF66)
    }

    private static func drawFish(_ p: Pen) {
        p.rect(0, 0, 100, 100, 0x74C0FC)
        p.ellipse(cx: 50, cy: 104, rx: 70, ry: 18, 0xFFE8A3) // Sand.
        let weed: UInt32 = 0x37B24D
        p.ellipse(cx: 12, cy: 78, rx: 5, ry: 16, weed)
        p.ellipse(cx: 22, cy: 82, rx: 4, ry: 11, weed)
        p.ellipse(cx: 90, cy: 76, rx: 5, ry: 17, weed)
        p.polygon([(66, 48), (90, 30), (86, 48), (90, 66)], 0xF76707) // Tail.
        p.polygon([(36, 34), (52, 22), (60, 36)], 0xFFD43B) // Top fin.
        p.ellipse(cx: 44, cy: 48, rx: 26, ry: 17, 0xFF922B) // Body.
        p.ellipse(cx: 50, cy: 48, rx: 4, ry: 15, 0xFFFFFF) // Stripe.
        p.ellipse(cx: 30, cy: 44, rx: 6, ry: 6, 0xFFFFFF) // Eye.
        p.ellipse(cx: 29, cy: 44, rx: 3, ry: 3, 0x3D3A4B)
        p.polygon([(48, 58), (58, 56), (52, 66)], 0xFFD43B) // Side fin.
        for (cx, cy, r) in [(CGFloat(16), CGFloat(30), CGFloat(3.5)), (12, 18, 3), (18, 8, 2.5), (78, 14, 3)] {
            p.ellipse(cx: cx, cy: cy, rx: r, ry: r, 0xE7F5FF)
        }
    }

    private static func drawHouse(_ p: Pen) {
        p.rect(0, 0, 100, 100, 0xA5D8FF)
        p.ellipse(cx: 14, cy: 14, rx: 9, ry: 9, 0xFFD43B)
        p.ellipse(cx: 52, cy: 12, rx: 9, ry: 5, 0xFFFFFF)
        p.ellipse(cx: 60, cy: 10, rx: 7, ry: 5, 0xFFFFFF)
        p.rect(0, 78, 100, 22, 0x69DB7C)
        p.rect(60, 24, 7, 16, 0xC92A2A) // Chimney.
        p.rect(24, 46, 46, 34, 0xFFE066) // Walls.
        p.polygon([(18, 48), (47, 22), (76, 48)], 0xFA5252) // Roof.
        p.rect(41, 58, 12, 22, 0xA0522D) // Door.
        p.ellipse(cx: 50.5, cy: 70, rx: 1.4, ry: 1.4, 0xFFD43B)
        p.rect(28, 54, 9, 9, 0xD0EBFF) // Windows.
        p.rect(57, 54, 9, 9, 0xD0EBFF)
        p.rect(81, 56, 5, 24, 0x8B5A2B) // Tree.
        p.ellipse(cx: 83.5, cy: 50, rx: 12, ry: 13, 0x2F9E44)
        p.polygon([(41, 80), (53, 80), (58, 100), (36, 100)], 0xDEE2E6) // Path.
    }

    private static func drawFlower(_ p: Pen) {
        p.rect(0, 0, 100, 100, 0xFFF0F6)
        p.ellipse(cx: 85, cy: 15, rx: 6, ry: 6, 0xFFE066)
        p.rect(47.5, 44, 5, 34, 0x40C057) // Stem.
        p.ellipse(cx: 39, cy: 64, rx: 10, ry: 5, 0x40C057) // Leaves.
        p.ellipse(cx: 61, cy: 58, rx: 10, ry: 5, 0x40C057)
        for i in 0..<6 {
            let angle = CGFloat(i) / 6 * 2 * .pi
            p.ellipse(cx: 50 + cos(angle) * 15, cy: 34 + sin(angle) * 15, rx: 10, ry: 10, i.isMultiple(of: 2) ? 0xF783AC : 0xDA77F2)
        }
        p.ellipse(cx: 50, cy: 34, rx: 9, ry: 9, 0xFFD43B)
        p.polygon([(32, 76), (68, 76), (62, 98), (38, 98)], 0xE8590C) // Pot.
        p.rect(30, 74, 40, 6, 0xD9480F)
    }

    private static func drawRocket(_ p: Pen) {
        p.rect(0, 0, 100, 100, 0x25285C)
        for (cx, cy) in [(CGFloat(12), CGFloat(14)), (84, 10), (90, 52), (10, 60), (22, 88), (78, 88), (60, 6)] {
            p.ellipse(cx: cx, cy: cy, rx: 2.4, ry: 2.4, 0xFFE066)
        }
        p.ellipse(cx: 16, cy: 34, rx: 8, ry: 8, 0xB197FC) // Planet.
        p.polygon([(42, 76), (35, 93), (50, 87), (65, 93), (58, 76)], 0xFF922B) // Flame.
        p.polygon([(45, 78), (50, 91), (55, 78)], 0xFFE066)
        p.polygon([(38, 54), (26, 76), (42, 72)], 0xFA5252) // Fins.
        p.polygon([(62, 54), (74, 76), (58, 72)], 0xFA5252)
        p.ellipse(cx: 50, cy: 48, rx: 14, ry: 28, 0xF1F3F5) // Body.
        p.ellipse(cx: 50, cy: 48, rx: 14, ry: 28, 0xFA5252, clip: CGRect(x: 0, y: 0, width: 100, height: 32)) // Nose.
        p.ellipse(cx: 50, cy: 46, rx: 8, ry: 8, 0x868E96) // Window.
        p.ellipse(cx: 50, cy: 46, rx: 5.5, ry: 5.5, 0x74C0FC)
        p.rect(38, 68, 24, 9, 0x495057) // Engine.
    }
}

/// Tiny drawing helper for the sample pictures.
private struct Pen {
    let context: CGContext

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ hex: UInt32) {
        context.setFillColor(color(hex))
        context.fill(CGRect(x: x, y: y, width: width, height: height))
    }

    func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, _ hex: UInt32, clip: CGRect? = nil) {
        context.saveGState()
        if let clip { context.clip(to: clip) }
        context.setFillColor(color(hex))
        context.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        context.restoreGState()
    }

    func polygon(_ points: [(CGFloat, CGFloat)], _ hex: UInt32) {
        guard let first = points.first else { return }
        context.setFillColor(color(hex))
        context.beginPath()
        context.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
        context.closePath()
        context.fillPath()
    }

    private func color(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

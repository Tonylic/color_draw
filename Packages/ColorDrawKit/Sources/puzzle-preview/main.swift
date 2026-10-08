// Renders puzzles to PNG files for tuning the engine on a Mac.
//
//   swift run -c release puzzle-preview <output-dir> [photo ...]
//
// With no photos it renders the built-in sample pictures. For each photo it renders the
// easy / medium / hard puzzles.
import ColorDrawKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Lays images out in a grid (row-major) on a white sheet.
func contactSheet(_ images: [[CGImage?]], cellWidth: Int) -> CGImage? {
    let columns = images.map(\.count).max() ?? 0
    let cellHeights = images.map { row in row.compactMap { $0 }.map { Int(Double(cellWidth) * Double($0.height) / Double($0.width)) }.max() ?? 0 }
    let gap = 12
    let width = columns * (cellWidth + gap) + gap
    let height = cellHeights.reduce(gap) { $0 + $1 + gap }
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var top = gap
    for (r, row) in images.enumerated() {
        for (c, image) in row.enumerated() {
            guard let image else { continue }
            let h = Int(Double(cellWidth) * Double(image.height) / Double(image.width))
            context.draw(image, in: CGRect(x: gap + c * (cellWidth + gap), y: height - top - h, width: cellWidth, height: h))
        }
        top += cellHeights[r] + gap
    }
    return context.makeImage()
}

@discardableResult
func render(_ puzzle: Puzzle, name: String, into directory: URL, seconds: Double) -> (blank: CGImage?, done: CGImage?) {
    let detail = DetailMap(puzzle: puzzle, scale: DetailMap.recommendedScale(for: puzzle))
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 12, nil)
    let blank = PuzzleSnapshot.render(puzzle: puzzle, detail: detail, appearance: { _ in .blank }, outputWidth: 1400, numberFont: font)
    let firstColor = 0
    let partial = PuzzleSnapshot.render(puzzle: puzzle, detail: detail, appearance: { index in
        let color = puzzle.regions[index].colorIndex
        if color == firstColor { return .highlighted }
        return index % 3 == 0 ? .painted(puzzle.palette[color]) : .blank
    }, outputWidth: 1400, numberFont: font)
    let done = PuzzleSnapshot.render(puzzle: puzzle, detail: detail, appearance: { .painted(puzzle.palette[puzzle.regions[$0].colorIndex]) }, outputWidth: 1400)
    if let blank { writePNG(blank, to: directory.appendingPathComponent("\(name)-blank.png")) }
    if let partial { writePNG(partial, to: directory.appendingPathComponent("\(name)-partial.png")) }
    if let done { writePNG(done, to: directory.appendingPathComponent("\(name)-done.png")) }
    let tiny = puzzle.regions.filter { $0.labelRadius < 2 }.count
    print(String(format: "%@: %dx%d, %d colors, %d regions (%d with radius < 2), %.2fs", name, puzzle.width, puzzle.height, puzzle.palette.count, puzzle.regions.count, tiny, seconds))
    return (blank, done)
}

/// A magnified crop of a sample's outlines over its paint, the way Core Animation shows them when
/// zoomed in (bilinear filtering), for judging how smooth the lines are.
func renderZoomedCrop(_ sample: SamplePicture, to url: URL) {
    let puzzle = sample.makePuzzle()
    let detail = DetailMap(puzzle: puzzle, scale: DetailMap.recommendedScale(for: puzzle))
    let buffer = PaintBuffer(detail: detail)
    buffer.render { .painted(puzzle.palette[puzzle.regions[$0].colorIndex]) }
    guard let paint = buffer.makeImage(), let outline = OutlineRenderer.makeImage(detail, color: CanvasStyle.standard.outline) else { return }
    let crop = CGRect(x: detail.width * 2 / 5, y: detail.height / 4, width: 140, height: 140)
    guard let paintCrop = paint.cropping(to: crop), let outlineCrop = outline.cropping(to: crop) else { return }
    let size = 840
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.interpolationQuality = .low // Bilinear, like a magnified CALayer.
    context.draw(paintCrop, in: CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(outlineCrop, in: CGRect(x: 0, y: 0, width: size, height: size))
    if let image = context.makeImage() { writePNG(image, to: url) }
}

let arguments = CommandLine.arguments.dropFirst()
guard let outputPath = arguments.first else {
    print("usage: puzzle-preview <output-dir> [photo ...]")
    exit(1)
}
let output = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let photos = Array(arguments.dropFirst())
if photos.isEmpty {
    renderZoomedCrop(.rocket, to: output.appendingPathComponent("rocket-zoomed-outline.png"))
    for sample in SamplePicture.allCases {
        let start = Date()
        let puzzle = sample.makePuzzle()
        render(puzzle, name: sample.rawValue, into: output, seconds: Date().timeIntervalSince(start))
    }
} else {
    for path in photos {
        guard let image = loadImage(path) else {
            print("Could not read \(path)")
            continue
        }
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
        var blanks: [CGImage?] = [image]
        var dones: [CGImage?] = [nil]
        for (level, settings) in [("easy", PuzzleSettings.easy), ("medium", .medium), ("hard", .hard)] {
            let start = Date()
            do {
                let puzzle = try PuzzleGenerator.generate(from: image, settings: settings)
                let result = render(puzzle, name: "\(base)-\(level)", into: output, seconds: Date().timeIntervalSince(start))
                blanks.append(result.blank)
                dones.append(result.done)
            } catch {
                print("Failed \(path): \(error)")
            }
        }
        if let sheet = contactSheet([blanks, dones], cellWidth: 520) {
            writePNG(sheet, to: output.appendingPathComponent("\(base)-sheet.png"))
        }
    }
}

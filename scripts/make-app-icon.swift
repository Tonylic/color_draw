// Draws the 1024×1024 app icon: Dotty the paint drop surrounded by numbered paint dots.
//
//   swift scripts/make-app-icon.swift ColorDraw/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreGraphics
import Foundation

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work in a top-left-origin space.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

// Background: warm pink → sunny yellow.
let background = CGGradient(colorsSpace: space, colors: [color(0xFFB3D4), color(0xFFD98A)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: .zero, end: CGPoint(x: size, y: size), options: [])
for (x, y, r) in [(180.0, 520.0, 120.0), (880.0, 560.0, 90.0), (520.0, 960.0, 140.0)] {
    context.setFillColor(color(0xFFFFFF, 0.18))
    context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// Numbered paint dots.
func number(_ text: String, at center: CGPoint, size fontSize: CGFloat) {
    let base = NSFont.systemFont(ofSize: fontSize, weight: .black)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize) ?? base
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    let line = CTLineCreateWithAttributedString(string)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: center.x - CGFloat(width) / 2, y: center.y + font.capHeight / 2)
    CTLineDraw(line, context)
    context.restoreGState()
}
let dots: [(CGFloat, CGFloat, UInt32, String)] = [(205, 215, 0xFFC107, "1"), (819, 215, 0xFF5C7A, "2"), (205, 819, 0x40C057, "3"), (819, 819, 0x4DABF7, "4")]
for (x, y, hex, text) in dots {
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 0, color: color(0x000000, 0.12))
    context.setFillColor(color(hex))
    context.fillEllipse(in: CGRect(x: x - 92, y: y - 92, width: 184, height: 184))
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setFillColor(color(0xFFFFFF, 0.35))
    context.fillEllipse(in: CGRect(x: x - 58, y: y - 70, width: 44, height: 30))
    number(text, at: CGPoint(x: x, y: y + 4), size: 118)
}

// Dotty the paint drop.
let cx: CGFloat = 512, cy: CGFloat = 600, r: CGFloat = 255
let k: CGFloat = 0.5523
let drop = CGMutablePath()
drop.move(to: CGPoint(x: cx, y: 150))
drop.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + 60, y: 260), control2: CGPoint(x: cx + r, y: cy - 190))
drop.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx + r, y: cy + k * r), control2: CGPoint(x: cx + k * r, y: cy + r))
drop.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - k * r, y: cy + r), control2: CGPoint(x: cx - r, y: cy + k * r))
drop.addCurve(to: CGPoint(x: cx, y: 150), control1: CGPoint(x: cx - r, y: cy - 190), control2: CGPoint(x: cx - 60, y: 260))
drop.closeSubpath()

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0x6B3FA0, 0.35))
context.addPath(drop)
context.setFillColor(color(0x845EF7))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(drop)
context.clip()
let body = CGGradient(colorsSpace: space, colors: [color(0x5C9DFF), color(0x8E5CF7)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(body, start: CGPoint(x: cx - r, y: 150), end: CGPoint(x: cx + r, y: cy + r), options: [])
context.setFillColor(color(0xFFFFFF, 0.28))
context.fillEllipse(in: CGRect(x: cx - 190, y: cy - 200, width: 95, height: 150))
context.restoreGState()

for side: CGFloat in [-1, 1] {
    let ex = cx + side * 95, ey = cy - 10
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: ex - 58, y: ey - 68, width: 116, height: 136))
    context.setFillColor(color(0x2D2A3E))
    context.fillEllipse(in: CGRect(x: ex - 36, y: ey - 26, width: 72, height: 80))
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: ex - 20, y: ey - 16, width: 26, height: 26))
    context.setFillColor(color(0xFF8FAB, 0.85))
    context.fillEllipse(in: CGRect(x: cx + side * 170 - 40, y: cy + 78, width: 80, height: 48))
}
context.setStrokeColor(color(0x2D2A3E))
context.setLineWidth(24)
context.setLineCap(.round)
context.move(to: CGPoint(x: cx - 62, y: cy + 92))
context.addQuadCurve(to: CGPoint(x: cx + 62, y: cy + 92), control: CGPoint(x: cx, y: cy + 160))
context.strokePath()

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")

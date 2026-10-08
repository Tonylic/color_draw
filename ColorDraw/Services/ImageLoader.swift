import CoreGraphics
import ImageIO
import UIKit

/// Turns picked photos into upright, reasonably sized images for the puzzle engine.
enum ImageLoader {
    /// The engine never needs more than this; smaller images keep memory and time low.
    static let maxPixelSize = 1024

    /// Decodes image data (JPEG, HEIC, PNG…), applying its EXIF orientation. Safe off the main thread.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Redraws a camera photo upright (camera images carry a rotation flag) and shrinks it,
    /// in the background.
    static func image(from photo: UIImage) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let longest = max(photo.size.width, photo.size.height)
            guard longest > 0 else { return nil }
            let scale = min(1, CGFloat(maxPixelSize) / longest)
            let size = CGSize(width: (photo.size.width * scale).rounded(), height: (photo.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                photo.draw(in: CGRect(origin: .zero, size: size))
            }.cgImage
        }.value
    }
}

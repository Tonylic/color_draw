import Photos
import UIKit

/// Gentle taps from the Taptic Engine.
@MainActor
enum Haptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()
    private static var lastPaint = Date.distantPast

    static func paint() {
        guard Date().timeIntervalSince(lastPaint) > 0.05 else { return }
        lastPaint = Date()
        soft.impactOccurred(intensity: 0.8)
    }

    static func oops() { rigid.impactOccurred(intensity: 0.35) }
    static func select() { soft.impactOccurred(intensity: 0.5) }
    static func success() { notification.notificationOccurred(.success) }
}

/// Saves finished paintings to the photo library (asks for add-only access the first time).
enum PhotoSaver {
    enum Result {
        case saved
        /// The grown-ups said no (or parental controls forbid it); only Settings can change that.
        case notAllowed
        case failed
    }

    static func save(_ image: UIImage) async -> Result {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .notAllowed }
        guard let data = image.pngData() else { return .failed }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }
}

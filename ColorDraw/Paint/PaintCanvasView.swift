import ColorDrawKit
import SwiftUI
import UIKit

/// The zoomable picture. One finger paints (tap or drag), two fingers pinch and move. When zoomed
/// in, a one-finger drag that starts somewhere it can't paint moves the picture instead, and in
/// move mode every one-finger drag does.
///
/// Layers inside the zoomed content view, bottom to top:
/// 1. `paintLayer`: the painted / blank / striped regions (a bitmap from `PaintBuffer`).
/// 2. `outlineLayer`: smooth region borders (a bitmap made once).
/// 3. `numbersLayer`: numbers as vector text, redrawn sharply for every zoom level.
/// Sparkles and pulses live in `effectsView` above the scroll view, so they keep their size.
final class PaintCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, PaintCanvasControlling {
    private let session: PaintSession
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let paintLayer = CALayer()
    private let outlineLayer = CALayer()
    private let numbersLayer = NumbersLayer()
    private let effectsView = UIView()
    private let buffer: PaintBuffer
    private var outlineImage: CGImage?
    private var needsPaintUpload = false
    private var laidOutSize: CGSize = .zero
    private var lastStrokePoint: CGPoint?
    /// The paint a drag started with; the stroke ends if the color changes underneath it.
    private var strokeColor: Int?
    /// Set while a one-finger drag is moving the picture rather than painting: the content
    /// offset when the drag began.
    private var panStartOffset: CGPoint?
    private var isMoveMode = false
    /// True while the picture glides on after a one-finger flick.
    private var isGliding = false
    private weak var focusMarker: UIView?

    /// Room kept free under the picture for the zoom buttons.
    static let bottomControlsHeight: CGFloat = 62

    /// Finger "brush" radius and tap forgiveness, in screen points.
    private let brushRadius: CGFloat = 9
    private let tapForgiveness: CGFloat = 16

    init(session: PaintSession) {
        self.session = session
        buffer = PaintBuffer(detail: session.detail)
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        // Moving needs two fingers; one finger is for painting.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.delaysContentTouches = false
        addSubview(scrollView)

        scrollView.addSubview(contentView)

        for layer in [paintLayer, outlineLayer] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .trilinear
            // Rounded per layer: cheap for single-image layers, unlike masking the zooming view.
            layer.cornerRadius = 6
            layer.masksToBounds = true
            contentView.layer.addSublayer(layer)
        }
        paintLayer.isOpaque = true
        contentView.layer.addSublayer(numbersLayer)

        effectsView.isUserInteractionEnabled = false
        addSubview(effectsView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        let stroke = UIPanGestureRecognizer(target: self, action: #selector(handleStroke(_:)))
        stroke.maximumNumberOfTouches = 1
        stroke.delegate = self
        addGestureRecognizer(stroke)

        // The picture is one accessibility element; the "Find" marker is another one beside it.
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = "Coloring picture"
        contentView.accessibilityHint = "Tap shapes with the matching number to paint them. Use the light bulb button to find one."

        outlineImage = OutlineRenderer.makeImage(session.detail, color: CanvasStyle.standard.outline)
        outlineLayer.contents = outlineImage
        renderAllRegions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var puzzle: Puzzle { session.puzzle }

    // MARK: Layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        numbersLayer.contentsScale = traitCollection.displayScale
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        effectsView.frame = bounds
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        focusMarker?.removeFromSuperview()

        // At zoom 1 the whole picture fits on screen, above the zoom buttons.
        var available = bounds.insetBy(dx: 14, dy: 14).size
        available.height -= Self.bottomControlsHeight
        let aspect = CGFloat(puzzle.width) / CGFloat(puzzle.height)
        var size = available
        if available.width / available.height > aspect {
            size.width = (available.height * aspect).rounded()
        } else {
            size.height = (available.width / aspect).rounded()
        }
        scrollView.zoomScale = 1
        contentView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        for layer in [paintLayer, outlineLayer, numbersLayer] as [CALayer] {
            layer.frame = contentView.bounds
        }
        let pixelSize = size.width / CGFloat(puzzle.width)
        let maximumZoom = Self.maximumZoom(for: puzzle, pixelSize: pixelSize)
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maximumZoom
        numbersLayer.configure(puzzle: puzzle, filled: session.progress.filled, pixelSize: pixelSize, maximumZoom: maximumZoom)
        centerContent()
        refreshVisibleColors()
        updateOutlineStrength()
    }

    /// Enough zoom that even the smallest number becomes big enough to read comfortably.
    private static func maximumZoom(for puzzle: Puzzle, pixelSize: CGFloat) -> CGFloat {
        let smallest = puzzle.regions.map { NumberRenderer.fontSize(for: $0, in: puzzle, pixelSize: pixelSize) }.min() ?? 10
        return min(10, max(3, 24 / max(smallest, 0.5)))
    }

    /// Centers the picture while it's smaller than the screen, and always leaves room to scroll
    /// its bottom edge above the zoom buttons.
    private func centerContent() {
        let reserve = Self.bottomControlsHeight
        let horizontal = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let vertical = max((scrollView.bounds.height - reserve - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical + reserve, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        refreshVisibleColors()
        updateOutlineStrength()
    }

    /// Pictures with hundreds of shapes are a dense web of lines when zoomed out, which hides the
    /// picture. Their outlines start soft and become fully crisp as the child zooms in to paint.
    private func updateOutlineStrength() {
        guard session.usesLargePalette else { return }
        let zoomedIn = min(1, max(0, (scrollView.zoomScale - 1) / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.opacity = Float(0.45 + 0.55 * zoomedIn)
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshVisibleColors()
        guard scrollView.isTracking || scrollView.isZooming || scrollView.isDecelerating else { return }
        // The child is moving the picture around: they're busy, not stuck. And the marker sits in
        // screen space, so it would drift away from its shape.
        session.noteActivity()
        focusMarker?.removeFromSuperview()
    }

    // MARK: Painting gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Like any scroll view: a tap on a gliding picture just stops it.
        if isGliding {
            stopGlide()
            return
        }
        let point = gesture.location(in: contentView)
        guard let region = region(at: point) else { return }
        if session.canPaint(region: region) {
            session.paint(region: region, isTap: true)
            return
        }
        // Forgive slightly-off taps on small shapes: paint the closest matching shape nearby.
        let radius = tapForgiveness / scrollView.zoomScale
        if let nearby = regions(near: point, radius: radius).first(where: session.canPaint(region:)) {
            session.paint(region: nearby, isTap: true)
        } else {
            session.paint(region: region, isTap: true)
        }
    }

    @objc private func handleStroke(_ gesture: UIPanGestureRecognizer) {
        // A second finger means the child is zooming, not painting.
        if gesture.numberOfTouches > 1 || scrollView.pinchGestureRecognizer?.state == .changed {
            lastStrokePoint = nil
            panStartOffset = nil
            return
        }
        if gesture.state == .began {
            // Catch a gliding picture first, so the finger's position is measured against what's
            // actually on screen.
            stopGlide()
            // Start where the finger first touched, not where the drag was recognized.
            let point = gesture.location(in: contentView)
            let translation = gesture.translation(in: contentView)
            let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            let isZoomedIn = scrollView.zoomScale > 1.05
            let startsOnPaint = regions(near: start, radius: brushRadius / scrollView.zoomScale).contains(where: session.canPaint(region:))
            if isMoveMode || (isZoomedIn && !startsOnPaint) {
                panStartOffset = scrollView.contentOffset
            }
        }
        if let panStartOffset {
            movePicture(with: gesture, from: panStartOffset)
            return
        }
        let point = gesture.location(in: contentView)
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: contentView)
            let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            strokeColor = session.selectedColor
            lastStrokePoint = start
            paintStroke(from: start, to: point)
        case .changed:
            // Finishing a color hands over the next paint; don't let the same stroke keep going
            // with a color the child didn't choose.
            guard let last = lastStrokePoint, strokeColor == session.selectedColor else {
                lastStrokePoint = nil
                return
            }
            paintStroke(from: last, to: point)
        default:
            lastStrokePoint = nil
            strokeColor = nil
            return
        }
        lastStrokePoint = point
    }

    /// Scrolls the picture along with a one-finger drag, gliding a little after the finger lifts.
    private func movePicture(with gesture: UIPanGestureRecognizer, from startOffset: CGPoint) {
        session.noteActivity()
        focusMarker?.removeFromSuperview()
        let translation = gesture.translation(in: scrollView)
        switch gesture.state {
        case .began, .changed:
            scrollView.contentOffset = clampedOffset(CGPoint(x: startOffset.x - translation.x, y: startOffset.y - translation.y))
        default:
            panStartOffset = nil
            let velocity = gesture.velocity(in: scrollView)
            let current = scrollView.contentOffset
            let target = clampedOffset(CGPoint(x: current.x - velocity.x * 0.18, y: current.y - velocity.y * 0.18))
            isGliding = true
            UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                self.scrollView.contentOffset = target
            } completion: { _ in
                self.isGliding = false
            }
        }
    }

    /// Stops a glide where the picture is on screen right now. Only touches our own glide, never
    /// an in-flight zoom animation.
    private func stopGlide() {
        guard isGliding else { return }
        isGliding = false
        let onScreen = scrollView.layer.presentation()?.bounds.origin ?? scrollView.contentOffset
        scrollView.layer.removeAllAnimations()
        scrollView.contentOffset = onScreen
    }

    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        let insets = scrollView.contentInset
        let maxX = max(-insets.left, scrollView.contentSize.width - scrollView.bounds.width + insets.right)
        let maxY = max(-insets.top, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        return CGPoint(x: min(max(offset.x, -insets.left), maxX), y: min(max(offset.y, -insets.top), maxY))
    }

    private func paintStroke(from start: CGPoint, to end: CGPoint) {
        session.noteActivity()
        let radius = brushRadius / scrollView.zoomScale
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int(distance / max(radius * 0.7, 0.5)))
        var painted = Set<Int>()
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            for region in regions(near: point, radius: radius) where !painted.contains(region) && session.canPaint(region: region) {
                painted.insert(region)
                session.paint(region: region, isTap: false)
                if session.selectedColor != strokeColor { return }
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    // MARK: Hit testing

    /// High-res map coordinates for a point in content view coordinates.
    private func detailPoint(_ point: CGPoint) -> (x: Int, y: Int) {
        let scale = CGFloat(session.detail.width) / max(contentView.bounds.width, 1)
        return (Int((point.x * scale).rounded(.down)), Int((point.y * scale).rounded(.down)))
    }

    private func region(at point: CGPoint) -> Int? {
        let p = detailPoint(point)
        return session.detail.region(atX: p.x, y: p.y)
    }

    /// Regions under a small circle, closest-first.
    private func regions(near center: CGPoint, radius: CGFloat) -> [Int] {
        var found: [(region: Int, distance: CGFloat)] = []
        func probe(_ point: CGPoint, distance: CGFloat) {
            guard let region = region(at: point) else { return }
            if let index = found.firstIndex(where: { $0.region == region }) {
                found[index].distance = min(found[index].distance, distance)
            } else {
                found.append((region, distance))
            }
        }
        probe(center, distance: 0)
        for ring in [0.5, 1.0] as [CGFloat] {
            for step in 0..<10 {
                let angle = CGFloat(step) / 10 * 2 * .pi
                let r = radius * ring
                probe(CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r), distance: r)
            }
        }
        return found.sorted { $0.distance < $1.distance }.map(\.region)
    }

    // MARK: PaintCanvasControlling

    func regionPainted(_ region: Int) {
        focusMarker?.removeFromSuperview()
        buffer.update(region: region, to: session.appearance(of: region))
        numbersLayer.markFilled(region)
        refreshVisibleColors()
        schedulePaintUpload()
        sparkle(at: region)
    }

    func selectionChanged() {
        focusMarker?.removeFromSuperview()
        renderAllRegions()
    }

    func zoom(by factor: CGFloat) {
        let target = min(max(scrollView.zoomScale * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        let visibleCenter = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
        let center = scrollView.convert(visibleCenter, to: contentView)
        zoom(to: center, scale: target)
    }

    func zoomToFit() {
        focusMarker?.removeFromSuperview()
        scrollView.setZoomScale(1, animated: true)
    }

    func setMoveMode(_ isOn: Bool) {
        // In move mode one-finger drags scroll the picture; taps still paint.
        isMoveMode = isOn
    }

    /// The part of the picture the child can see: the screen minus the strip under the controls.
    private var visibleContentRect: CGRect {
        var visible = scrollView.bounds
        visible.size.height -= Self.bottomControlsHeight
        return scrollView.convert(visible, to: contentView)
    }

    /// How many nearby colors are reported to the paint tray (it shows as many as fit).
    static let nearbyColorCount = 12

    /// Tells the session which colors have unpainted shapes closest to the middle of the screen:
    /// the ones the child is looking at. Cheap enough for every scroll step (one distance per
    /// shape); the session ignores unchanged results.
    private func refreshVisibleColors() {
        guard contentView.bounds.width > 0 else { return }
        let visible = visibleContentRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let pixelSize = contentView.bounds.width / CGFloat(puzzle.width)
        var nearest: [Int: CGFloat] = [:]
        for (index, region) in puzzle.regions.enumerated() where !session.progress.filled[index] {
            let point = labelPoint(of: index)
            guard visible.contains(point) else { continue }
            // Close to the middle, with a head start for big shapes: those catch the eye first.
            let score = hypot(point.x - center.x, point.y - center.y) - 2 * CGFloat(region.labelRadius) * pixelSize
            if score < nearest[region.colorIndex, default: .infinity] { nearest[region.colorIndex] = score }
        }
        let closest = nearest.sorted { $0.value < $1.value }.prefix(Self.nearbyColorCount).map(\.key)
        session.updateVisibleColors(Array(closest))
    }

    func isAnyUnpaintedRegionVisible(of color: Int) -> Bool {
        let visible = visibleContentRect
        return puzzle.regions.indices.contains { region in
            !session.progress.filled[region] && puzzle.regions[region].colorIndex == color && visible.contains(labelPoint(of: region))
        }
    }

    func focus(on region: Int) {
        let center = labelPoint(of: region)
        // Zoom in until the number is comfortably big (but never zoom out).
        let fontSize = NumberRenderer.fontSize(for: puzzle.regions[region], in: puzzle, pixelSize: contentView.bounds.width / CGFloat(puzzle.width))
        let wanted = min(scrollView.maximumZoomScale, max(scrollView.zoomScale, 30 / max(fontSize, 1)))
        zoom(to: center, scale: wanted) { [weak self] finished in
            if finished { self?.showFocusMarker(on: region) }
        }
    }

    func point(at region: Int) {
        // Only point at shapes the child can see right now. Automatic pointing never moves
        // VoiceOver's focus; only the light bulb (`focus(on:)`) does.
        guard visibleContentRect.contains(labelPoint(of: region)) else { return }
        showFocusMarker(on: region, showsHand: true, movesVoiceOverFocus: false)
    }

    func nearestUnpaintedRegion(of color: Int) -> Int? {
        let visibleCenter = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: contentView)
        let pixelSize = contentView.bounds.width / CGFloat(puzzle.width)
        return puzzle.regions.indices
            .filter { !session.progress.filled[$0] && puzzle.regions[$0].colorIndex == color }
            .min { a, b in
                let pa = labelPoint(of: a), pb = labelPoint(of: b)
                // Prefer close shapes, but give big ones a head start: they're easier to find.
                let da = hypot(pa.x - visibleCenter.x, pa.y - visibleCenter.y) - CGFloat(puzzle.regions[a].labelRadius) * pixelSize * 2
                let db = hypot(pb.x - visibleCenter.x, pb.y - visibleCenter.y) - CGFloat(puzzle.regions[b].labelRadius) * pixelSize * 2
                return da < db
            }
    }

    func snapshot(width: CGFloat) -> UIImage? {
        // Read the buffer, not the layer: the layer's bitmap is refreshed on the next run loop,
        // so it can still miss the shape that was just painted.
        guard let paintImage = buffer.makeImage(), let outlineImage else { return nil }
        let size = CGSize(width: width, height: (width * CGFloat(puzzle.height) / CGFloat(puzzle.width)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Hundreds of outlines would turn a small picture of a big puzzle into a gray mesh.
        let outlineAlpha: CGFloat = session.usesLargePalette ? 0.35 : 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIImage(cgImage: paintImage).draw(in: rect)
            UIImage(cgImage: outlineImage).draw(in: rect, blendMode: .normal, alpha: outlineAlpha)
        }
    }

    // MARK: Drawing

    private func renderAllRegions() {
        buffer.setHighlightTint(session.selectedPaint)
        buffer.render { [session] in session.appearance(of: $0) }
        schedulePaintUpload()
    }

    /// Coalesces many region updates (e.g. during a stroke) into one bitmap upload per frame.
    private func schedulePaintUpload() {
        guard !needsPaintUpload else { return }
        needsPaintUpload = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            needsPaintUpload = false
            let image = buffer.makeImage()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            paintLayer.contents = image
            CATransaction.commit()
        }
    }

    private func zoom(to center: CGPoint, scale: CGFloat, completion: ((Bool) -> Void)? = nil) {
        // The marker sits in screen space, so it can't stay once the picture moves.
        focusMarker?.removeFromSuperview()
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.scrollView.zoom(to: rect, animated: false)
        } completion: { finished in
            completion?(finished)
        }
    }

    private func labelPoint(of region: Int) -> CGPoint {
        let pixelSize = contentView.bounds.width / CGFloat(puzzle.width)
        let r = puzzle.regions[region]
        return CGPoint(x: CGFloat(r.labelX) * pixelSize, y: CGFloat(r.labelY) * pixelSize)
    }

    // MARK: Effects

    private func sparkle(at region: Int) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let center = contentView.convert(labelPoint(of: region), to: effectsView)
        let color = Color(puzzle.palette[puzzle.regions[region].colorIndex])
        let colors = [UIColor(color), .white, UIColor(Theme.yellow)]
        for index in 0..<7 {
            let star = CAShapeLayer()
            let size: CGFloat = index.isMultiple(of: 2) ? 12 : 8
            star.path = Self.starPath(size: size)
            star.fillColor = colors[index % colors.count].cgColor
            star.strokeColor = UIColor(Theme.ink).withAlphaComponent(0.25).cgColor
            star.lineWidth = 1
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.position = center
            effectsView.layer.addSublayer(star)

            let angle = CGFloat(index) / 7 * 2 * .pi + .random(in: -0.3...0.3)
            let distance = CGFloat.random(in: 26...44)
            let end = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: center)
            move.toValue = NSValue(cgPoint: end)
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.toValue = CGFloat.pi * (index.isMultiple(of: 2) ? 1 : -1)
            let group = CAAnimationGroup()
            group.animations = [move, fade, spin]
            group.duration = 0.55

            CATransaction.begin()
            CATransaction.setCompletionBlock { star.removeFromSuperlayer() }
            star.opacity = 0
            star.position = end
            star.add(group, forKey: "sparkle")
            CATransaction.commit()
        }
    }

    /// A pulsing ring around a shape the child should paint next. It is also an accessibility
    /// element, so VoiceOver users can paint the shape by double-tapping it.
    private func showFocusMarker(on region: Int, showsHand: Bool = false, movesVoiceOverFocus: Bool = true) {
        focusMarker?.removeFromSuperview()
        let marker = FocusMarkerView(number: puzzle.regions[region].colorIndex + 1, showsHand: showsHand) { [weak self] in
            self?.session.paint(region: region, isTap: true)
        }
        marker.center = contentView.convert(labelPoint(of: region), to: effectsView)
        effectsView.addSubview(marker)
        focusMarker = marker
        if movesVoiceOverFocus {
            UIAccessibility.post(notification: .layoutChanged, argument: marker)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusMarkerView.lifetime) { [weak marker] in
            marker?.removeFromSuperview()
        }
    }

    private static func starPath(size: CGFloat) -> CGPath {
        let path = UIBezierPath()
        let center = CGPoint(x: size / 2, y: size / 2)
        for i in 0..<10 {
            let radius = i.isMultiple(of: 2) ? size / 2 : size / 4.5
            let angle = CGFloat(i) / 10 * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        return path.cgPath
    }
}

/// The pulsing "paint me!" ring shown by the Find button.
private final class FocusMarkerView: UIView {
    static let lifetime: TimeInterval = 4.2
    private static let ringSize: CGFloat = 80
    private let activate: () -> Void

    /// - Parameter showsHand: Adds a ghost finger that keeps tapping the shape ("tap here!").
    init(number: Int, showsHand: Bool, activate: @escaping () -> Void) {
        self.activate = activate
        super.init(frame: CGRect(x: 0, y: 0, width: Self.ringSize, height: Self.ringSize))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "focusMarker"
        accessibilityLabel = "Shape number \(number)"
        accessibilityHint = "Double-tap to paint it."
        accessibilityTraits = .button

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).cgPath
        ring.frame = bounds
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(Theme.pink).cgColor
        ring.lineWidth = 6
        ring.opacity = 0
        layer.addSublayer(ring)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.2, 0.7, 1]
        let group = CAAnimationGroup()
        group.duration = 0.84
        group.repeatCount = Float(Self.lifetime / group.duration)
        if reduceMotion {
            group.animations = [fade]
            ring.transform = CATransform3DMakeScale(0.8, 0.8, 1)
        } else {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.5
            shrink.toValue = 0.5
            group.animations = [shrink, fade]
        }
        ring.add(group, forKey: "pulse")

        if showsHand {
            let hand = UIImageView(image: UIImage(systemName: "hand.point.up.left.fill"))
            hand.tintColor = .white
            hand.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 38, weight: .bold)
            hand.layer.shadowColor = UIColor(Theme.ink).cgColor
            hand.layer.shadowOpacity = 0.6
            hand.layer.shadowRadius = 3
            hand.layer.shadowOffset = CGSize(width: 0, height: 2)
            hand.sizeToFit()
            // The fingertip rests on the shape's center.
            hand.center = CGPoint(x: bounds.midX + hand.bounds.width * 0.32, y: bounds.midY + hand.bounds.height * 0.42)
            addSubview(hand)
            if !reduceMotion {
                let press = CAKeyframeAnimation(keyPath: "transform")
                press.values = [CATransform3DIdentity, CATransform3DMakeScale(0.85, 0.85, 1), CATransform3DIdentity]
                press.keyTimes = [0, 0.3, 0.6]
                press.duration = 0.84
                press.repeatCount = group.repeatCount
                hand.layer.add(press, forKey: "tap")
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}

/// SwiftUI wrapper for the canvas.
struct PaintCanvas: UIViewRepresentable {
    let session: PaintSession

    func makeUIView(context: Context) -> PaintCanvasView {
        let view = PaintCanvasView(session: session)
        session.canvas = view
        return view
    }

    func updateUIView(_ uiView: PaintCanvasView, context: Context) {}
}

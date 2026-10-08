import SwiftUI

/// Pastel background with soft bubbles drifting slowly upward.
struct BubbleBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Bubble {
        var x: Double
        var size: Double
        var speed: Double
        var phase: Double
        var color: Color
    }

    private let bubbles: [Bubble] = (0..<14).map { index in
        let colors = Theme.rainbow
        // Fixed pseudo-random layout so the background doesn't jump between launches.
        let a = Double((index * 37) % 100) / 100
        let b = Double((index * 61) % 100) / 100
        return Bubble(x: a, size: 40 + b * 90, speed: 0.012 + b * 0.02, phase: Double((index * 23) % 100) / 100, color: colors[index % colors.count])
    }

    var body: some View {
        ZStack {
            Theme.background
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || LaunchOptions.isUITesting)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for bubble in bubbles {
                        let progress = (bubble.phase + time * bubble.speed).truncatingRemainder(dividingBy: 1)
                        let y = size.height + bubble.size - progress * (size.height + bubble.size * 2)
                        let x = bubble.x * size.width + sin(time * 0.5 + bubble.phase * 6) * 18
                        let rect = CGRect(x: x - bubble.size / 2, y: y - bubble.size / 2, width: bubble.size, height: bubble.size)
                        context.fill(Circle().path(in: rect), with: .color(bubble.color.opacity(0.13)))
                        let shine = CGRect(x: rect.minX + bubble.size * 0.22, y: rect.minY + bubble.size * 0.18, width: bubble.size * 0.22, height: bubble.size * 0.16)
                        context.fill(Ellipse().path(in: shine), with: .color(.white.opacity(0.35)))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview {
    BubbleBackground()
}

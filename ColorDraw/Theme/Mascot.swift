import SwiftUI

/// Dotty, the friendly paint drop who cheers children on.
struct Mascot: View {
    enum Mood {
        case happy
        case cheering
    }

    var size: CGFloat = 90
    var mood: Mood = .happy
    var color: Color = Theme.purple

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var bobbing = false
    @State private var blinking = false

    private var reduceMotion: Bool { accessibilityReduceMotion || LaunchOptions.isUITesting }

    var body: some View {
        ZStack {
            DropShape()
                .fill(
                    LinearGradient(colors: [Color(hex: 0x5C9DFF), color], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: color.opacity(0.35), radius: size * 0.06, y: size * 0.04)
            // Shine.
            Ellipse()
                .fill(.white.opacity(0.3))
                .frame(width: size * 0.16, height: size * 0.26)
                .offset(x: -size * 0.2, y: -size * 0.02)
            face
                .offset(y: size * 0.16)
        }
        .frame(width: size * 0.82, height: size)
        .offset(y: bobbing ? -size * 0.04 : size * 0.02)
        .scaleEffect(mood == .cheering && bobbing ? 1.06 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: mood == .cheering ? 0.35 : 1.4).repeatForever(autoreverses: true)) {
                bobbing = true
            }
        }
        .task {
            guard !reduceMotion else { return }
            // Blink every few seconds.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...4.5)))
                withAnimation(.easeInOut(duration: 0.08)) { blinking = true }
                try? await Task.sleep(for: .seconds(0.14))
                withAnimation(.easeInOut(duration: 0.08)) { blinking = false }
            }
        }
        .accessibilityHidden(true)
    }

    private var face: some View {
        VStack(spacing: size * 0.05) {
            HStack(spacing: size * 0.12) {
                eye
                eye
            }
            ZStack {
                // Cheeks.
                HStack(spacing: size * 0.36) {
                    Capsule().fill(Color(hex: 0xFF8FAB).opacity(0.85)).frame(width: size * 0.13, height: size * 0.08)
                    Capsule().fill(Color(hex: 0xFF8FAB).opacity(0.85)).frame(width: size * 0.13, height: size * 0.08)
                }
                .offset(y: -size * 0.03)
                if mood == .cheering {
                    // Big open smile.
                    SmileShape(open: true)
                        .fill(Color(hex: 0x2D2A3E))
                        .frame(width: size * 0.2, height: size * 0.12)
                } else {
                    SmileShape(open: false)
                        .stroke(Color(hex: 0x2D2A3E), style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                        .frame(width: size * 0.18, height: size * 0.07)
                }
            }
        }
    }

    private var eye: some View {
        ZStack {
            Ellipse().fill(.white)
                .frame(width: size * 0.17, height: size * 0.2)
            Ellipse().fill(Color(hex: 0x2D2A3E))
                .frame(width: size * 0.1, height: size * 0.12)
                .offset(y: size * 0.02)
            Circle().fill(.white)
                .frame(width: size * 0.04)
                .offset(x: -size * 0.015, y: -size * 0.005)
        }
        .scaleEffect(y: blinking ? 0.1 : 1)
    }
}

/// A paint drop: a pointy top that swells into a round bottom.
struct DropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        let cx = rect.midX
        let cy = rect.maxY - r
        let k: CGFloat = 0.5523
        var path = Path()
        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: cx + r, y: cy),
            control1: CGPoint(x: cx + r * 0.24, y: rect.minY + (cy - rect.minY) * 0.25),
            control2: CGPoint(x: cx + r, y: cy - r * 0.75)
        )
        path.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx + r, y: cy + k * r), control2: CGPoint(x: cx + k * r, y: cy + r))
        path.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - k * r, y: cy + r), control2: CGPoint(x: cx - r, y: cy + k * r))
        path.addCurve(
            to: CGPoint(x: cx, y: rect.minY),
            control1: CGPoint(x: cx - r, y: cy - r * 0.75),
            control2: CGPoint(x: cx - r * 0.24, y: rect.minY + (cy - rect.minY) * 0.25)
        )
        path.closeSubpath()
        return path
    }
}

private struct SmileShape: Shape {
    var open: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * (open ? 2 : 1.8)))
        if open { path.closeSubpath() }
        return path
    }
}

#Preview {
    HStack {
        Mascot()
        Mascot(size: 140, mood: .cheering)
    }
}

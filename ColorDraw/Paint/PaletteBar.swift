import ColorDrawKit
import SwiftUI

/// The paint pots: one big numbered blob per color. Finished colors get a check mark.
struct PaletteBar: View {
    let session: PaintSession
    @State private var width: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(session.puzzle.palette.indices, id: \.self) { index in
                        Button {
                            session.select(color: index)
                        } label: {
                            PaintPot(
                                number: index + 1,
                                color: session.puzzle.palette[index],
                                remaining: session.progress.remainingByColor[index],
                                total: session.progress.totalByColor[index],
                                isSelected: index == session.selectedColor,
                                wiggle: session.hintTokens[index]
                            )
                        }
                        .buttonStyle(PotButtonStyle())
                        .id(index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .background { WidthReader(width: $contentWidth) }
                // Centered when all the pots fit (e.g. on iPad).
                .frame(minWidth: width)
            }
            // Fade the edges when there are more pots than fit, so children see they can scroll.
            .mask {
                if contentWidth > width + 1 {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .onChange(of: session.selectedColor) { _, color in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo(color, anchor: .center)
                }
            }
            .onChange(of: session.hintTokens) { _, _ in
                guard let color = session.hintedColor else { return }
                withAnimation { proxy.scrollTo(color, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(session.selectedColor, anchor: .center) }
        }
        .background { WidthReader(width: $width) }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(.white)
                .shadow(color: Theme.ink.opacity(0.12), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Reports the width of the view it's placed behind.
private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
        }
    }
}

private struct PotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PaintPot: View {
    let number: Int
    let color: RGBColor
    let remaining: Int
    let total: Int
    let isSelected: Bool
    /// Changing this makes the pot wiggle ("this is the color you need!").
    let wiggle: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let size: CGFloat = 58

    var body: some View {
        let ink: Color = color.prefersDarkText ? Theme.ink : .white
        let done = remaining == 0
        ZStack {
            // Progress ring: fills up as shapes of this color get painted.
            Circle()
                .stroke(Theme.ink.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: total == 0 ? 1 : CGFloat(total - remaining) / CGFloat(total))
                .stroke(Theme.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color(color).gradient)
                .overlay(Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    Ellipse().fill(.white.opacity(0.45))
                        .frame(width: size * 0.26, height: size * 0.16)
                        .rotationEffect(.degrees(-30))
                        .offset(x: size * 0.16, y: size * 0.12)
                }
                .padding(7)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(ink)
            } else {
                Text("\(number)")
                    .font(.system(size: number >= 10 ? 21 : 25, weight: .black, design: .rounded))
                    .foregroundStyle(ink)
                    .shadow(color: (ink == .white ? Color.black : .white).opacity(0.25), radius: 0, y: 1)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .background {
            if isSelected {
                Circle()
                    .fill(Theme.yellow.opacity(0.35))
                    .scaleEffect(1.18)
            }
        }
        .overlay(alignment: .top) {
            if isSelected {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .offset(y: -15)
            }
        }
        .scaleEffect(isSelected ? 1.12 : 1)
        .opacity(done && !isSelected ? 0.55 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isSelected)
        .keyframeAnimator(initialValue: PotWiggle(), trigger: wiggle) { content, wiggle in
            content
                // A glowing halo that lingers, so the hint isn't missed while eyes are on the picture.
                .background {
                    Circle()
                        .stroke(Theme.pink, lineWidth: 5)
                        .scaleEffect(1.22)
                        .opacity(wiggle.glow)
                }
                .rotationEffect(.degrees(wiggle.angle))
                .scaleEffect(wiggle.scale)
        } keyframes: { _ in
            KeyframeTrack(\.angle) {
                if reduceMotion {
                    LinearKeyframe(0, duration: 0.5)
                } else {
                    SpringKeyframe(-16, duration: 0.1)
                    SpringKeyframe(14, duration: 0.12)
                    SpringKeyframe(-10, duration: 0.12)
                    SpringKeyframe(6, duration: 0.12)
                    SpringKeyframe(0, duration: 0.15)
                }
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.2, duration: 0.15)
                SpringKeyframe(1.0, duration: 0.45)
            }
            KeyframeTrack(\.glow) {
                LinearKeyframe(1, duration: 0.15)
                LinearKeyframe(1, duration: 1.5)
                LinearKeyframe(0, duration: 0.4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color \(number), \(color.name)")
        .accessibilityValue(done ? "All done" : "\(remaining) left")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct PotWiggle {
    var angle: Double = 0
    var scale: Double = 1
    var glow: Double = 0
}

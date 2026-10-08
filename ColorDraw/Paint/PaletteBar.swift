import ColorDrawKit
import SwiftUI

/// The paint pots: one big numbered blob per color. Finished colors get a check mark.
struct PaletteBar: View {
    let session: PaintSession

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
                                total: total(of: index),
                                isSelected: index == session.selectedColor,
                                wiggle: session.hint?.color == index ? session.hint?.token ?? 0 : 0
                            )
                        }
                        .buttonStyle(PotButtonStyle())
                        .id(index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)
            }
            .onChange(of: session.selectedColor) { _, color in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo(color, anchor: .center)
                }
            }
            .onChange(of: session.hint?.token) { _, _ in
                guard let color = session.hint?.color else { return }
                withAnimation { proxy.scrollTo(color, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(session.selectedColor, anchor: .center) }
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(.white)
                .shadow(color: Theme.ink.opacity(0.12), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func total(of color: Int) -> Int {
        session.puzzle.regions.reduce(0) { $0 + ($1.colorIndex == color ? 1 : 0) }
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
                .overlay(Circle().stroke(Theme.ink.opacity(0.12), lineWidth: 1.5))
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
        .keyframeAnimator(initialValue: 0.0, trigger: wiggle) { content, angle in
            content.rotationEffect(.degrees(angle))
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-16, duration: 0.1)
                SpringKeyframe(14, duration: 0.12)
                SpringKeyframe(-10, duration: 0.12)
                SpringKeyframe(6, duration: 0.12)
                SpringKeyframe(0, duration: 0.15)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color \(number)")
        .accessibilityValue(done ? "All done" : "\(remaining) left")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

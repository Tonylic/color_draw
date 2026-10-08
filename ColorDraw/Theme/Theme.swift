import ColorDrawKit
import SwiftUI

/// Colors and type for the whole app: soft candy colors and chunky rounded letters.
enum Theme {
    static let ink = Color(hex: 0x4C4560)
    static let softInk = Color(hex: 0x6F6788)
    static let paper = Color(hex: 0xFFFBF5)

    // Candy colors behind white text: deep enough for at least 3:1 contrast.
    static let pink = Color(hex: 0xEC4D8E)
    static let orange = Color(hex: 0xE9771A)
    static let yellowDeep = Color(hex: 0xE5A000)
    static let green = Color(hex: 0x1E9E5E)
    static let blue = Color(hex: 0x2F80E4)
    static let purple = Color(hex: 0x7B57EE)

    /// Bright decoration colors (title letters, confetti, bubbles).
    static let yellow = Color(hex: 0xFFC93C)
    static let rainbow: [Color] = [Color(hex: 0xFF6FA8), Color(hex: 0xFF9F43), yellow, Color(hex: 0x3FC380), Color(hex: 0x4D9DF7), Color(hex: 0x8E6CF7)]

    static let background = LinearGradient(
        colors: [Color(hex: 0xFFF1E0), Color(hex: 0xFFE4F1), Color(hex: 0xE3EEFF)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Rounded system font that still follows Dynamic Type.
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .heavy) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(_ color: RGBColor) {
        self.init(.sRGB, red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }

    /// A darker shade, used for the "3D" bottom edge of buttons.
    func darker(by amount: Double = 0.22) -> Color {
        let resolved = resolve(in: EnvironmentValues())
        return Color(
            .sRGB,
            red: Double(resolved.red) * (1 - amount),
            green: Double(resolved.green) * (1 - amount),
            blue: Double(resolved.blue) * (1 - amount),
            opacity: Double(resolved.opacity)
        )
    }
}

/// A big, squishy candy button: a solid "3D" edge underneath that the button presses into.
struct ChunkyButtonStyle: ButtonStyle {
    var color: Color
    var cornerRadius: CGFloat = 26
    var depth: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.font(.title3))
            .foregroundStyle(.white)
            .shadow(color: color.darker(by: 0.35).opacity(0.5), radius: 0, y: 1.5)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(color.gradient)
                    .overlay(alignment: .top) {
                        // A soft shine across the top.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.white.opacity(0.22))
                            .frame(height: 18)
                            .padding(.horizontal, 10)
                            .padding(.top, 5)
                    }
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(color.darker())
                    .offset(y: pressed ? 2 : depth)
            }
            .offset(y: pressed ? depth - 2 : 0)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: pressed)
    }
}

/// A round floating button with an icon, used on the painting screen.
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 54
    var tint: Color = Theme.ink
    var background: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(background))
            .background(Circle().fill(Color.black.opacity(0.12)).offset(y: configuration.isPressed ? 1 : 4))
            .offset(y: configuration.isPressed ? 3 : 0)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// "Color Draw" written with every letter in a different rainbow color.
struct RainbowTitle: View {
    var text: String
    var style: Font.TextStyle = .largeTitle

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .foregroundStyle(Theme.rainbow[index % Theme.rainbow.count])
                    .rotationEffect(.degrees(letter == " " ? 0 : (index.isMultiple(of: 2) ? -4 : 4)))
            }
        }
        .font(Theme.font(style, weight: .black))
        .shadow(color: .white, radius: 0, x: 0, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}

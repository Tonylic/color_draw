import ColorDrawKit
import SwiftUI

/// The paint tray at the bottom of the painting screen.
///
/// Small palettes (the built-in drawings) show every pot in one row. Photos can have up to 200
/// colors, far too many to scroll through, so their tray never scrolls far:
/// - first a rainbow **All Colors** button that opens the color chart, then
/// - the paint in hand plus the colors whose shapes are closest to the middle of the screen, as
///   many as fit. Zoomed in to paint, those are the numbers the child is looking at.
struct PaletteBar: View {
    let session: PaintSession
    @State private var showsAllColors = false
    @State private var stripWidth: CGFloat = 0

    private static let trayPotSize: CGFloat = 54
    private static let trayPotSpacing: CGFloat = 8

    var body: some View {
        Group {
            if session.usesLargePalette {
                HStack(spacing: 0) {
                    AllColorsButton(colors: session.puzzle.palette) { showsAllColors = true }
                        .padding(.leading, 14)
                        .padding(.trailing, 2)
                    PotStrip(session: session, colors: trayColors, potSize: Self.trayPotSize)
                        .background { WidthReader(width: $stripWidth) }
                }
            } else {
                PotStrip(session: session, colors: Array(session.puzzle.palette.indices), potSize: 58)
            }
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(.white)
                .shadow(color: Theme.ink.opacity(0.12), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showsAllColors) {
            AllColorsSheet(session: session)
        }
    }

    /// The paint in hand, a hinted color, and as many of the colors nearest the middle of the
    /// screen as fit without scrolling — shown in number order.
    private var trayColors: [Int] {
        let capacity = max(3, Int((stripWidth - 28 + Self.trayPotSpacing) / (Self.trayPotSize * 1.12 + Self.trayPotSpacing)))
        var colors: [Int] = [session.selectedColor]
        if let hinted = session.hintedColor, !session.progress.isFinished(color: hinted), !colors.contains(hinted) {
            colors.append(hinted)
        }
        for color in session.visibleColors where colors.count < capacity && !colors.contains(color) {
            colors.append(color)
        }
        return colors.sorted()
    }
}

/// A scrolling row of paint pots.
private struct PotStrip: View {
    let session: PaintSession
    let colors: [Int]
    let potSize: CGFloat
    @State private var width: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(colors, id: \.self) { index in
                        Button {
                            session.select(color: index)
                        } label: {
                            PaintPot(
                                number: index + 1,
                                color: session.puzzle.palette[index],
                                remaining: session.progress.remainingByColor[index],
                                total: session.progress.totalByColor[index],
                                isSelected: index == session.selectedColor,
                                wiggle: session.hintTokens[index],
                                size: potSize
                            )
                        }
                        .buttonStyle(PotButtonStyle())
                        .id(index)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: colors)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .background { WidthReader(width: $contentWidth) }
                // Centered when all the pots fit (e.g. on iPad).
                .frame(minWidth: width)
            }
            .accessibilityIdentifier("palette")
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
                guard let color = session.hintedColor, colors.contains(color) else { return }
                withAnimation { proxy.scrollTo(color, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(session.selectedColor, anchor: .center) }
        }
        .background { WidthReader(width: $width) }
    }
}

/// Opens the chart of all colors: a pot made of a little rainbow of the picture's own paints.
private struct AllColorsButton: View {
    let colors: [RGBColor]
    let action: () -> Void

    private let size: CGFloat = 62

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    // Eight evenly spaced paints from the (rainbow-ordered) palette.
                    let samples = (0..<8).map { colors[$0 * (colors.count - 1) / 7] }
                    ForEach(0..<8, id: \.self) { slice in
                        Circle()
                            .trim(from: CGFloat(slice) / 8, to: CGFloat(slice + 1) / 8)
                            .stroke(Color(samples[slice]), lineWidth: size * 0.22)
                    }
                    .rotationEffect(.degrees(-90))
                    .padding(size * 0.11)
                    Circle()
                        .fill(.white)
                        .padding(size * 0.24)
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: size * 0.26, weight: .bold))
                        .foregroundStyle(Theme.purple)
                }
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.ink.opacity(0.08)).offset(y: 3))
                Text("All")
                    .font(Theme.font(.caption, weight: .black))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .buttonStyle(PotButtonStyle())
        .accessibilityLabel("All colors")
        .accessibilityHint("Shows every color in a chart")
        .accessibilityIdentifier("allColorsButton")
    }
}

/// Shown in the tray when everything on screen is painted.
private struct NothingHereView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.yellow)
            Text("All done here!")
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.softInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Every color in a chart of ten per row, like the hundreds charts children know from school:
/// 37 is in the fourth row. Big palettes are split into pages of 50 (1–50, 51–100, …) so a page
/// fits on screen without scrolling. The rainbow order of the palette makes each page a color
/// gradient, so children can also find a color just by looking for it.
struct AllColorsSheet: View {
    let session: PaintSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideFinishedColors") private var hideFinished = false
    @State private var page = 0

    static let pageSize = 50
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)

    private var pageCount: Int { (session.puzzle.palette.count + Self.pageSize - 1) / Self.pageSize }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("All Colors")
                    .font(Theme.font(.title2, weight: .black))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Toggle(isOn: $hideFinished) {
                    Label("Hide done", systemImage: "checkmark.circle")
                        .font(Theme.font(.subheadline, weight: .bold))
                }
                .toggleStyle(.button)
                .tint(Theme.green)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(RoundIconButtonStyle(size: 40))
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            if pageCount > 1 {
                PageTabs(session: session, pageCount: pageCount, pageSize: Self.pageSize, page: $page)
                    .padding(.horizontal, 12)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(shownColors, id: \.self) { index in
                        ChartPot(
                            number: index + 1,
                            color: session.puzzle.palette[index],
                            isDone: session.progress.isFinished(color: index),
                            isSelected: index == session.selectedColor
                        ) {
                            pick(index)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
                .id(page)
                .transition(.opacity)
            }
            .accessibilityIdentifier("allColors")
            .animation(.easeInOut(duration: 0.2), value: page)
        }
        .background(Theme.paper.ignoresSafeArea())
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        .onAppear { page = session.selectedColor / Self.pageSize }
    }

    private var shownColors: [Int] {
        let first = page * Self.pageSize
        let range = first..<min(first + Self.pageSize, session.puzzle.palette.count)
        return hideFinished ? range.filter { !session.progress.isFinished(color: $0) } : Array(range)
    }

    private func pick(_ index: Int) {
        session.select(color: index)
        // A finished color just wiggles in the tray; there's nothing left to paint with it.
        if !session.progress.isFinished(color: index) { dismiss() }
    }
}

/// Tabs for the pages of the chart, e.g. "1–50 | 51–100 | 101–150 | 151–159", each with a strip
/// of its colors so children can also pick a page by color.
private struct PageTabs: View {
    let session: PaintSession
    let pageCount: Int
    let pageSize: Int
    @Binding var page: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                let first = index * pageSize
                let last = min(first + pageSize, session.puzzle.palette.count) - 1
                let isCurrent = index == page
                Button {
                    page = index
                    Haptics.select()
                } label: {
                    VStack(spacing: 4) {
                        Text("\(first + 1)–\(last + 1)")
                            .font(Theme.font(.subheadline, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // The page's colors as a little rainbow bar.
                        HStack(spacing: 0) {
                            ForEach(Array(stride(from: first, through: last, by: max(1, (last - first) / 9))), id: \.self) { color in
                                Color(session.puzzle.palette[color])
                            }
                        }
                        .frame(height: 6)
                        .clipShape(Capsule())
                    }
                    .foregroundStyle(isCurrent ? .white : Theme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isCurrent ? AnyShapeStyle(Theme.purple.gradient) : AnyShapeStyle(Color.white))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.ink.opacity(isCurrent ? 0 : 0.12), lineWidth: 1.5)
                    )
                }
                .buttonStyle(PotButtonStyle())
                .accessibilityLabel("Colors \(first + 1) to \(last + 1)")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }
}

/// One pot in the color chart: small, but the whole cell is the touch target.
private struct ChartPot: View {
    let number: Int
    let color: RGBColor
    let isDone: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let ink: Color = color.prefersDarkText ? Theme.ink : .white
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(color).gradient)
                    .overlay(Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 1.5))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(ink)
                } else {
                    Text("\(number)")
                        .font(.system(size: number >= 100 ? 12 : 15, weight: .black, design: .rounded))
                        .foregroundStyle(ink)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(3)
            .background {
                if isSelected {
                    Circle().stroke(Theme.ink, lineWidth: 3)
                }
            }
            .opacity(isDone && !isSelected ? 0.4 : 1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PotButtonStyle())
        .accessibilityLabel("Color \(number), \(color.name)")
        .accessibilityValue(isDone ? "All done" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    var size: CGFloat = 58

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .font(.system(size: size * 0.41, weight: .black, design: .rounded))
                    .foregroundStyle(ink)
            } else {
                Text("\(number)")
                    .font(.system(size: size * (number >= 100 ? 0.3 : number >= 10 ? 0.36 : 0.43), weight: .black, design: .rounded))
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

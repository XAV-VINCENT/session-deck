import SwiftUI

/// Dynamic Island look: pure black, white text at a few fixed opacities, saturated status colors.
enum Theme {
    static let hairline = Color.white.opacity(0.08)
    static let text2 = Color.white.opacity(0.64)
    static let text3 = Color.white.opacity(0.42)
    static let text4 = Color.white.opacity(0.26)
    static let rowHover = Color.white.opacity(0.06)
    static let rowSelected = Color.white.opacity(0.1)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private struct DeckClockKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// A fixed time for the spinners and pulses, so recorded frames move at a steady pace.
    var deckClock: Date? {
        get { self[DeckClockKey.self] }
        set { self[DeckClockKey.self] = newValue }
    }
}

/// The state of a session at a glance: a spinner while it runs, a pulsing dot when it needs you.
struct StatusBadge: View {
    let state: SessionState
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            switch state {
            case .running:
                GradientSpinner(color: state.color, lineWidth: max(1.6, size * 0.13))
            case .needsYou:
                PulsingDot(color: state.color, size: size * 0.5)
            case .error:
                Circle().fill(state.color).padding(size * 0.08)
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.85))
            case .review:
                Circle().fill(state.color.opacity(0.2))
                Image(systemName: "eye.fill")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(state.color)
            case .done:
                Circle().fill(state.color.opacity(0.2))
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.46, weight: .heavy))
                    .foregroundStyle(state.color)
            case .idle:
                Circle()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: max(1.2, size * 0.09))
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
    }
}

struct GradientSpinner: View {
    let color: Color
    var lineWidth: CGFloat = 2
    @Environment(\.deckClock) private var clock

    var body: some View {
        TimelineView(.animation) { context in
            let turn = (clock ?? context.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(
                        AngularGradient(colors: [color.opacity(0), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(259)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(turn * 360))
            }
            .padding(lineWidth / 2)
        }
    }
}

struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    @Environment(\.deckClock) private var clock

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = (clock ?? context.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            ZStack {
                Circle()
                    .fill(color.opacity(0.5 * (1 - phase)))
                    .frame(width: size * (1 + phase * 1.4), height: size * (1 + phase * 1.4))
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .shadow(color: color.opacity(0.9), radius: size * 0.4)
            }
        }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .foregroundStyle(Theme.text2)
    }
}

/// A profile's color as a small gradient disc with its initial.
struct ProfileAvatar: View {
    let instance: Instance
    var size: CGFloat = 24

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(LinearGradient(colors: [instance.color, instance.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Text(verbatim: String(instance.label.prefix(1)).uppercased())
                        .font(Theme.rounded(size * 0.5, .bold))
                        .foregroundStyle(.black.opacity(0.75))
                )
                .frame(width: size, height: size)
            Circle()
                .fill(instance.isRunning ? SessionState.done.color : Color(white: 0.4))
                .frame(width: size * 0.32, height: size * 0.32)
                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                .offset(x: 1, y: 1)
        }
        .help(instance.isRunning ? "\(instance.label) is open" : "\(instance.label) is not running")
    }
}

/// The app's mark: a black deck hanging from a notch over a dusk wallpaper. Also the app icon.
struct DeckIcon: View {
    var size: CGFloat = 512
    /// The macOS icon grid leaves a margin around the rounded square; the in-app glyph does not.
    var iconMargin = false

    var body: some View {
        let body = iconMargin ? size * 0.805 : size
        ZStack {
            ZStack(alignment: .top) {
                DeckWallpaper()
                NotchShape(radius: body * 0.1)
                    .fill(Color.black)
                    .frame(width: body * 0.7, height: body * 0.62)
                    .shadow(color: .black.opacity(0.5), radius: body * 0.04, y: body * 0.02)
                VStack(alignment: .leading, spacing: body * 0.055) {
                    iconRow(color: SessionState.needsYou.color, title: 0.3, body: body)
                    iconRow(color: SessionState.running.color, title: 0.24, body: body)
                    iconRow(color: SessionState.done.color, title: 0.27, body: body)
                }
                .padding(.top, body * 0.13)
                .frame(width: body * 0.7, alignment: .leading)
                .padding(.leading, body * 0.12)
            }
            .frame(width: body, height: body)
            .clipShape(RoundedRectangle(cornerRadius: body * 0.225, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: body * 0.225, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, body * 0.006))
            )
            .shadow(color: .black.opacity(iconMargin ? 0.35 : 0), radius: body * 0.03, y: body * 0.015)
        }
        .frame(width: size, height: size)
    }

    private func iconRow(color: Color, title: CGFloat, body: CGFloat) -> some View {
        HStack(alignment: .top, spacing: body * 0.045) {
            Circle()
                .fill(color)
                .frame(width: body * 0.07, height: body * 0.07)
                .shadow(color: color.opacity(0.9), radius: body * 0.02)
            VStack(alignment: .leading, spacing: body * 0.022) {
                Capsule().fill(Color.white.opacity(0.92)).frame(width: body * title, height: body * 0.036)
                Capsule().fill(Color.white.opacity(0.3)).frame(width: body * 0.2, height: body * 0.026)
            }
            .padding(.top, body * 0.012)
        }
    }
}

/// Soft dusk gradient, used behind the icon and in the README shots.
struct DeckWallpaper: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(rgb: 0x0B1030), Color(rgb: 0x1C0F33)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(rgb: 0x3D5BFF, opacity: 0.75), .clear], center: UnitPoint(x: 0.1, y: 0.95), startRadius: 0, endRadius: 520 * scale)
            RadialGradient(colors: [Color(rgb: 0xFF7A45, opacity: 0.6), .clear], center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: 480 * scale)
            RadialGradient(colors: [Color(rgb: 0xB44CFF, opacity: 0.45), .clear], center: UnitPoint(x: 0.6, y: 0.45), startRadius: 0, endRadius: 420 * scale)
        }
    }
}

/// Flat top flush with the screen edge, rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The sides and bottom of `NotchShape`, for a faint rim that never draws along the screen edge.
struct NotchRim: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

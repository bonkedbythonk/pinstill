import SwiftUI

/// Pinstill's look: a gallery wall. The wallpapers are the colour; the chrome around them
/// stays quiet and native.
///
/// - Thumbnails are prints: a thin mat, flat at rest, lifted a little on hover.
/// - One accent, pin red, and one mark made from it: the pin dot. It marks the wallpaper on
///   the desktop and the steps of setup. Nothing else is red except the primary button.
/// - State is plain text coloured by meaning, not a badge or a tinted box.
/// - Sentence case everywhere; tabular digits so counters don't jitter.
enum Theme {
    static let pinRed = Color(red: 0.85, green: 0.27, blue: 0.23)
    static let hairline = Color.primary.opacity(0.1)
    static let mat = Color.primary.opacity(0.06)
    static let warning = Color.orange
}

/// The pin dot: a small red head with a hint of shine.
struct PinDot: View {
    var size: CGFloat = 10
    var filled = true

    var body: some View {
        Circle()
            .fill(filled ? AnyShapeStyle(Theme.pinRed) : AnyShapeStyle(Theme.hairline))
            .overlay(alignment: .topLeading) {
                if filled {
                    Circle()
                        .fill(.white.opacity(0.45))
                        .frame(width: size * 0.32, height: size * 0.32)
                        .offset(x: size * 0.2, y: size * 0.18)
                }
            }
            .frame(width: size, height: size)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

extension View {
    /// Metadata: small, tabular digits.
    func meta(size: CGFloat = 11.5) -> some View {
        font(.system(size: size)).monospacedDigit()
    }
}

/// Primary action: pin red, used once per screen at most.
struct PinButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.pinRed.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension ButtonStyle where Self == PinButtonStyle {
    static var pin: PinButtonStyle { PinButtonStyle() }
}

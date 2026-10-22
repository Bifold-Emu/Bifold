import SwiftUI
import UIKit

/// Bifold's visual language: slate surfaces, one amber action colour, and the hinge — the fold
/// between a 3DS's two screens — as the recurring mark. Light and dark follow the system; the
/// game screen itself is always dark.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Page background.
    static let background = dynamic(0xEEF1F5, 0x18202C)
    /// Cards, lists, sheets.
    static let surface = dynamic(0xFFFFFF, 0x222C3B)
    /// Secondary buttons and wells inside a surface.
    static let raised = dynamic(0xE4E8EF, 0x2B3747)
    /// Separators inside a surface.
    static let separator = dynamic(0xE1E5EC, 0x313C4D)
    /// The one action colour: primary buttons, the selected tab, active toggles.
    static let accent = dynamic(0xE8901A, 0xFFB24A)
    /// Text on the accent colour.
    static let onAccent = Color(UIColor(hex: 0x2B1B00))
    /// Status light (JIT on, connected).
    static let led = dynamic(0x2F86DA, 0x63B3FF)
    static let danger = dynamic(0xD9443A, 0xFF7A6E)
    static let secondaryText = dynamic(0x5D6878, 0x97A3B6)

    /// Hinge metal: light and dark ends of its gradient.
    static let hingeTop = dynamic(0xBCC5D2, 0x5E6A7C)
    static let hingeBottom = dynamic(0x8E99AA, 0x2A3443)
    static let knuckleTop = dynamic(0xF4F6F9, 0xA9B4C4)
    static let knuckleBottom = dynamic(0xA7B1C0, 0x6C788A)

    static let cardRadius: CGFloat = 22
    static let tileRadius: CGFloat = 16
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The fold between two screens: a metal strip with two knuckles.
struct Hinge: View {
    var height: CGFloat = 14
    var knuckleInset: CGFloat = 0.18

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Theme.hingeTop, Theme.hingeBottom], startPoint: .top, endPoint: .bottom)
                let w = min(54, geo.size.width * 0.14)
                ForEach([knuckleInset, 1 - knuckleInset], id: \.self) { f in
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.knuckleTop, Theme.knuckleBottom], startPoint: .top, endPoint: .bottom))
                        .frame(width: w, height: height * 0.68)
                        .position(x: geo.size.width * f, y: height / 2)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Full-width amber button: the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A coloured square icon for settings rows.
struct IconTile: View {
    let systemName: String
    let color: Color
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Small glowing dot.
struct StatusLight: View {
    var color: Color = Theme.led
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 4)
    }
}

extension View {
    /// Page background that runs under the safe areas.
    func pageBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Hide the default grouped-list background (iOS 16+) so the page colour shows through.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Theme.background.ignoresSafeArea())
    }
}

/// A grouped form on the page colour with rows on the surface colour.
struct ThemedForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { Group { content }.listRowBackground(Theme.surface) }
            .tint(Theme.accent)
            .themedList()
    }
}

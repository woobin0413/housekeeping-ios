import SwiftUI

enum Palette {
    static let background = adaptive(light: 0xF7F6F2, dark: 0x171C19)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x242C26)
    static let ink = adaptive(light: 0x24392D, dark: 0xF3F5EF)
    static let secondary = adaptive(light: 0x667369, dark: 0xB4BEB5)
    static let action = adaptive(light: 0x285943, dark: 0xB7D6BE)
    static let actionText = adaptive(light: 0xFFFFFF, dark: 0x173423)
    static let sage = adaptive(light: 0xE9EFE6, dark: 0x303F34)
    static let border = adaptive(light: 0xE4E7DE, dark: 0x3A443C)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1
                )
            })
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(16)
            .foregroundStyle(Palette.actionText)
            .background(Palette.action.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
            .clipShape(.rect(cornerRadius: 18))
            // Keep the pinned action compact without limiting the screen's content text.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer()
    }
}

struct BottomAction<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) { content }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(Palette.background)
    }
}

struct Eyebrow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .tracking(1.8)
            .foregroundStyle(Palette.secondary)
    }
}

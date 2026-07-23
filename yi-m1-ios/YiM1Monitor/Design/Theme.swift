// Design system for YI M1 Monitor (iOS). Same token vocabulary as the macOS app's
// ../yi-m1-remote-control/app/theme.py (approved 2026-07-07: dark "pro-monitor",
// monochrome + one amber accent, red reserved for recording only) - this is the
// SwiftUI-native rendering of the identical values, not a separate design.
import SwiftUI

enum AppColor {
    // Surfaces, darkest (page) to lightest (raised controls).
    static let bg = Color(hex: 0x0c0d0f)
    static let surface = Color(hex: 0x16181b)
    static let surface2 = Color(hex: 0x1e2124)
    static let liveBG = Color(hex: 0x14_15_17)

    // Hairlines.
    static let hairline = Color(hex: 0x2a2d31)
    static let hairlineSoft = Color(hex: 0x1c1f22)

    // Text tiers.
    static let text = Color(hex: 0xf3f4f6)
    static let text2 = Color(hex: 0x9ba1a8)
    static let text3 = Color(hex: 0x63696f)

    // The single accent + reserved semantic colors.
    static let accent = Color(hex: 0xf5a623)
    static let accentDim = Color(hex: 0x8a6320)
    static let record = Color(hex: 0xff3b30)
    static let ok = Color(hex: 0x34c759)
}

enum AppRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 11
    static let lg: CGFloat = 14
}

enum AppSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

enum AppFont {
    static let caption: CGFloat = 11
    static let small: CGFloat = 12
    static let body: CGFloat = 13
    static let value: CGFloat = 14
    static let heading: CGFloat = 16
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Amber-bordered "pill" look shared by the guide toggles and setting chips - the SwiftUI
/// equivalent of theme.py's guide_toggle_qss()/status_chip_qss().
struct PillButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppFont.small, weight: .medium))
            .foregroundStyle(active ? AppColor.accent : AppColor.text2)
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(active ? AppColor.accent : AppColor.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct StatusChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: AppFont.small))
            .foregroundStyle(AppColor.text2)
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.xs + 1)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(AppColor.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }
}

extension View {
    func statusChipStyle() -> some View { modifier(StatusChipStyle()) }
}

// Design system for YI M1 Monitor (iOS). Dark pro-monitor palette with one amber accent.
import SwiftUI
import UIKit

enum AppLayout {
    /// iPhone SE (1st gen) / iPhone 5s class: 320×568 pt in portrait.
    static let isFourInchPhone = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) <= 320
}

enum AppColor {
    static let bg = Color(hex: 0x0c0d0f)
    static let surface = Color(hex: 0x16181b)
    static let surface2 = Color(hex: 0x1e2124)
    static let liveBG = Color(hex: 0x14_15_17)

    static let hairline = Color(hex: 0x2a2d31)
    static let hairlineSoft = Color(hex: 0x1c1f22)

    static let text = Color(hex: 0xf3f4f6)
    static let text2 = Color(hex: 0x9ba1a8)
    static let text3 = Color(hex: 0x63696f)

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
    static let sm: CGFloat = AppLayout.isFourInchPhone ? 6 : 8
    static let md: CGFloat = AppLayout.isFourInchPhone ? 10 : 12
    static let lg: CGFloat = AppLayout.isFourInchPhone ? 12 : 16
    static let xl: CGFloat = AppLayout.isFourInchPhone ? 16 : 20
}

enum AppFont {
    /// Slightly tighter type scale on the 320-pt-wide iPhone SE (1st gen). Chinese labels are
    /// shorter than the old English labels, so this keeps the monitor readable without wasting
    /// live-view area or forcing controls to wrap.
    static let caption: CGFloat = AppLayout.isFourInchPhone ? 10.5 : 11
    static let small: CGFloat = AppLayout.isFourInchPhone ? 11.5 : 12
    static let body: CGFloat = AppLayout.isFourInchPhone ? 12.5 : 13
    static let value: CGFloat = AppLayout.isFourInchPhone ? 13.5 : 14
    static let heading: CGFloat = AppLayout.isFourInchPhone ? 15 : 16
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

struct PillButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppFont.small, weight: .medium))
            .foregroundStyle(active ? AppColor.accent : AppColor.text2)
            .padding(.horizontal, AppLayout.isFourInchPhone ? 4 : AppSpace.sm)
            .padding(.vertical, AppLayout.isFourInchPhone ? 4 : AppSpace.sm)
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
            .padding(.horizontal, AppLayout.isFourInchPhone ? AppSpace.sm : AppSpace.md)
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

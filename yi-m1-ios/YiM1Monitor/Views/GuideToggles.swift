import SwiftUI
import YiM1Core

struct GuideToggles: View {
    @Binding var showCrop: Bool
    @Binding var showThirds: Bool
    @Binding var showDiagonals: Bool
    var cropAlwaysOn: Bool = false

    private var iconFrame: CGFloat { AppLayout.isFourInchPhone ? 28 : 40 }

    var body: some View {
        HStack(spacing: AppLayout.isFourInchPhone ? 4 : AppSpace.sm) {
            cropToggle
            toggle(isOn: $showThirds, systemImage: AppIcon.thirds, label: "三分线")
            diagonalsToggle
        }
    }

    private var cropToggle: some View {
        Button {
            showCrop.toggle()
        } label: {
            Image(systemName: AppIcon.crop)
                .font(.system(size: AppLayout.isFourInchPhone ? 14 : 16))
                .frame(width: iconFrame, height: AppLayout.isFourInchPhone ? 32 : 40)
        }
        .buttonStyle(PillButtonStyle(active: showCrop || cropAlwaysOn))
        .disabled(cropAlwaysOn)
        .accessibilityLabel("裁切范围")
    }

    private func toggle(isOn: Binding<Bool>, systemImage: String, label: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: AppLayout.isFourInchPhone ? 14 : 16))
                .frame(width: iconFrame, height: AppLayout.isFourInchPhone ? 32 : 40)
        }
        .buttonStyle(PillButtonStyle(active: isOn.wrappedValue))
        .accessibilityLabel(label)
    }

    private var diagonalsToggle: some View {
        Button {
            showDiagonals.toggle()
        } label: {
            DiagonalsIcon(color: showDiagonals ? AppColor.accent : AppColor.text2)
                .frame(width: AppLayout.isFourInchPhone ? 14 : 16, height: AppLayout.isFourInchPhone ? 14 : 16)
                .frame(width: iconFrame, height: AppLayout.isFourInchPhone ? 32 : 40)
        }
        .buttonStyle(PillButtonStyle(active: showDiagonals))
        .accessibilityLabel("对角线")
    }
}

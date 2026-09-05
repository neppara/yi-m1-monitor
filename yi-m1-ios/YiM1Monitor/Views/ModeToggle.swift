import SwiftUI
import YiM1Core

struct ModeToggle: View {
    @Binding var mode: CaptureMode
    var iconsOnly: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            segment(.photo, systemImage: mode == .photo ? AppIcon.cameraFill : AppIcon.camera, label: "照片")
            segment(.video, systemImage: mode == .video ? AppIcon.videoFill : AppIcon.video, label: "视频")
        }
        .padding(2)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func segment(_ value: CaptureMode, systemImage: String, label: String) -> some View {
        let active = mode == value
        return Button {
            mode = value
        } label: {
            Group {
                if iconsOnly {
                    Label(label, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                } else {
                    Label(label, systemImage: systemImage)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: AppFont.small, weight: .medium))
            .foregroundStyle(active ? AppColor.text : AppColor.text2)
            .padding(.horizontal, iconsOnly ? AppSpace.md : (AppLayout.isFourInchPhone ? AppSpace.md : AppSpace.lg))
            .padding(.vertical, AppSpace.sm)
            .background(active ? AppColor.hairline : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

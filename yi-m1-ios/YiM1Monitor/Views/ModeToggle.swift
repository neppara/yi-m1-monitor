// Photo/Video segmented toggle - a free switch (confirmed fact #6: both RCDoShooting and
// VideoRecordingStart work interchangeably in one session, so there's no gating logic here).
// Port of main_window.py's mode_toggle_qss()/#modeToggle.
import SwiftUI
import YiM1Core

struct ModeToggle: View {
    @Binding var mode: CaptureMode
    /// Landscape top bar (2026-07-12 user feedback): icons only, no "Photo"/"Video" text -
    /// the row also holds the status chip and fps counter, so width is at a premium there.
    var iconsOnly: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            segment(.photo, systemImage: mode == .photo ? AppIcon.cameraFill : AppIcon.camera, label: "Photo")
            segment(.video, systemImage: mode == .video ? AppIcon.videoFill : AppIcon.video, label: "Video")
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
            .padding(.horizontal, iconsOnly ? AppSpace.md : AppSpace.lg)
            .padding(.vertical, AppSpace.sm)
            .background(active ? AppColor.hairline : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

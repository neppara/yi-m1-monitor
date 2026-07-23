// Crop / Thirds / Diagonals toggles - split out per the user's revision request (previously one
// "Guides" button). Amber when active, matching theme.py's guide_toggle_qss().
import SwiftUI
import YiM1Core

struct GuideToggles: View {
    @Binding var showCrop: Bool
    @Binding var showThirds: Bool
    @Binding var showDiagonals: Bool
    /// Video mode (2026-07-19): the crop there is a fact of the camera (FHD/4K always record
    /// 16:9, unchangeable remotely), so the overlay is permanently on and this toggle locks -
    /// shown active but not tappable. Photo mode keeps it a real toggle.
    var cropAlwaysOn: Bool = false

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            cropToggle
            toggle(isOn: $showThirds, systemImage: AppIcon.thirds, label: "Thirds")
            diagonalsToggle
        }
    }

    private var cropToggle: some View {
        Button {
            showCrop.toggle()
        } label: {
            Image(systemName: AppIcon.crop)
                .font(.system(size: 16))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(PillButtonStyle(active: showCrop || cropAlwaysOn))
        .disabled(cropAlwaysOn)
        .accessibilityLabel("Crop")
    }

    private func toggle(isOn: Binding<Bool>, systemImage: String, label: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(PillButtonStyle(active: isOn.wrappedValue))
        .accessibilityLabel(label)
    }

    private var diagonalsToggle: some View {
        Button {
            showDiagonals.toggle()
        } label: {
            DiagonalsIcon(color: showDiagonals ? AppColor.accent : AppColor.text2)
                .frame(width: 16, height: 16)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(PillButtonStyle(active: showDiagonals))
        .accessibilityLabel("Diagonals")
    }
}

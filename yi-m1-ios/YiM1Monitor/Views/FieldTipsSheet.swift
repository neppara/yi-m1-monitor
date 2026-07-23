// Pre-session checklist (I5, 2026-07-12) - the field rules discovered over the course of this
// project's live-view stability investigation and general on-device use. Purely informational,
// static content; dismissible from the top bar's info button (RootView.fieldTipsButton).
import SwiftUI

struct FieldTipsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Tip: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private let tips: [Tip] = [
        Tip(icon: "antenna.radiowaves.left.and.right.slash",
            text: "Turn Bluetooth OFF in Settings (not just Control Center) before starting - the phone shares one antenna between Bluetooth and Wi-Fi, and Bluetooth staying on measurably stutters the live view."),
        Tip(icon: "wifi.exclamationmark",
            text: "Brief stutters every few minutes are expected and self-recovering - iOS periodically scans for other Wi-Fi networks in the background and there's no way to disable it. The \"Weak link\" chip means this, not an app problem."),
        Tip(icon: "lock.iphone",
            text: "The camera's own screen and physical controls lock while a phone is connected - this is normal for the remote-control session, not a malfunction."),
        Tip(icon: "person.badge.shield.checkmark",
            text: "Only one device can control the camera at a time."),
        Tip(icon: "video.badge.checkmark",
            text: "Set the video format/resolution on the camera itself BEFORE connecting - it can't be changed remotely once a session is active."),
    ]

    var body: some View {
        NavigationStack {
            List(tips) { tip in
                HStack(alignment: .top, spacing: AppSpace.md) {
                    Image(systemName: tip.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(AppColor.accent)
                        .frame(width: 24)
                    Text(tip.text)
                        .font(.system(size: AppFont.body))
                        .foregroundStyle(AppColor.text)
                }
                .padding(.vertical, AppSpace.xs)
                .listRowBackground(AppColor.surface)
            }
            .scrollContentBackground(.hidden)
            .background(AppColor.bg)
            .navigationTitle("For a stable session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

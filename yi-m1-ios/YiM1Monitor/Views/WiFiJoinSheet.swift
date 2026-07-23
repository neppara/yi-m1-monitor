// "Connect to camera Wi-Fi" sheet - the v1 manual-join flow (Part 4.2, no paid developer
// account / no NEHotspotConfiguration entitlement needed). Shows the freshly-randomized
// SSID/password, a copy button, a deep-link into this app's Settings page (the closest iOS
// allows without the Hotspot Configuration entitlement), and a manual "I've connected" nudge -
// the actual detection is CameraSession's reachability poll, kicked off as soon as this sheet
// appears (confirmWiFiJoinInProgress()); the poll auto-dismisses this sheet on success.
import SwiftUI
import YiM1Core

struct WiFiJoinSheet<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    let credentials: WiFiCredentials

    var body: some View {
        VStack(spacing: AppSpace.xl) {
            VStack(spacing: AppSpace.sm) {
                Image(systemName: AppIcon.wifi)
                    .font(.system(size: 32))
                    .foregroundStyle(AppColor.accent)
                Text("Connect to the camera's Wi-Fi")
                    .font(.system(size: AppFont.heading, weight: .semibold))
                    .foregroundStyle(AppColor.text)
                Text("This password is generated fresh each session, so it can't be memorized in advance.")
                    .font(.system(size: AppFont.small))
                    .foregroundStyle(AppColor.text2)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: AppSpace.md) {
                credentialRow(title: "Network", value: credentials.ssid)
                credentialRow(title: "Password", value: credentials.password)
            }
            .padding(AppSpace.lg)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            VStack(spacing: AppSpace.sm) {
                Button {
                    UIPasteboard.general.string = credentials.password
                } label: {
                    Label("Copy password", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(AppColor.accent)

                Button {
                    // Try the private App-Prefs scheme first - it deep-links straight into the
                    // Wi-Fi pane. Apple rejects it in App Store review, but this app is
                    // sideloaded via Xcode (personal team, no review), so it's fine here. The
                    // official openSettingsURLString can only open *this app's* settings page
                    // (user reported landing there and having to navigate back) - kept only as
                    // the fallback in case a future iOS version kills the private scheme.
                    if let wifiURL = URL(string: "App-Prefs:root=WIFI") {
                        UIApplication.shared.open(wifiURL) { success in
                            if !success, let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } label: {
                    Label("Open Wi-Fi Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    session.confirmWiFiJoinInProgress()
                } label: {
                    if case .connecting = session.connectionState {
                        HStack {
                            ProgressView().tint(AppColor.bg)
                            Text("Checking…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("I've connected")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColor.accent)

                Button(role: .cancel) {
                    // Abandons the whole attempt (clears pendingWiFiCredentials, which is what
                    // this sheet's presentation is bound to) - without this there is no way out
                    // of the sheet other than actually joining the camera's Wi-Fi.
                    session.reset()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(AppColor.text2)
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpace.xs)
            }
        }
        .padding(AppSpace.xl)
        .background(AppColor.bg)
        .onAppear {
            session.confirmWiFiJoinInProgress() // start the reachability poll right away
        }
    }

    private func credentialRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text2)
            Spacer()
            Text(value)
                .font(.system(size: AppFont.heading, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColor.text)
        }
    }
}

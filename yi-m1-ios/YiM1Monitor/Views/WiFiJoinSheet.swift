import SwiftUI
import YiM1Core

struct WiFiJoinSheet<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    let credentials: WiFiCredentials

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpace.xl) {
                VStack(spacing: AppSpace.sm) {
                    Image(systemName: AppIcon.wifi)
                        .font(.system(size: AppLayout.isFourInchPhone ? 28 : 32))
                        .foregroundStyle(AppColor.accent)
                    Text("连接相机 Wi-Fi")
                        .font(.system(size: AppFont.heading, weight: .semibold))
                        .foregroundStyle(AppColor.text)
                    Text("密码每次连接都会重新生成，因此不能提前记住。")
                        .font(.system(size: AppFont.small))
                        .foregroundStyle(AppColor.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: AppSpace.md) {
                    credentialRow(title: "网络", value: credentials.ssid)
                    credentialRow(title: "密码", value: credentials.password)
                }
                .padding(AppSpace.lg)
                .background(AppColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

                VStack(spacing: AppSpace.sm) {
                    Button {
                        UIPasteboard.general.string = credentials.password
                    } label: {
                        Label("复制密码", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColor.accent)

                    Button {
                        if let wifiURL = URL(string: "App-Prefs:root=WIFI") {
                            UIApplication.shared.open(wifiURL) { success in
                                if !success, let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    } label: {
                        Label("打开 Wi-Fi 设置", systemImage: "gear")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        session.confirmWiFiJoinInProgress()
                    } label: {
                        if case .connecting = session.connectionState {
                            HStack {
                                ProgressView().tint(AppColor.bg)
                                Text("正在检查…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("我已连接")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.accent)

                    Button(role: .cancel) {
                        session.reset()
                    } label: {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(AppColor.text2)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, AppSpace.xs)
                }
            }
            .padding(AppLayout.isFourInchPhone ? AppSpace.md : AppSpace.xl)
        }
        .background(AppColor.bg)
        .onAppear {
            session.confirmWiFiJoinInProgress()
        }
    }

    private func credentialRow(title: String, value: String) -> some View {
        HStack(spacing: AppSpace.sm) {
            Text(title)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text2)
            Spacer(minLength: AppSpace.sm)
            Text(value)
                .font(.system(size: AppFont.heading, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

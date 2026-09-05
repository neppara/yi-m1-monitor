import SwiftUI
import YiM1Core

struct ConnectionMenu<Session: CameraSessionProtocol, MenuLabel: View>: View {
    @ObservedObject var session: Session
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            Button {
                session.connectViaBLE()
            } label: {
                Label("通过蓝牙连接", systemImage: AppIcon.bluetooth)
            }
            .disabled(isBusy)

            Button {
                session.connectDirect()
            } label: {
                Label("已连接相机 Wi-Fi", systemImage: AppIcon.wifi)
            }
            .disabled(isBusy)

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label("断开连接", systemImage: AppIcon.disconnect)
            }
            .disabled(session.connectionState == .disconnected || session.connectionState == .disconnecting)

            Button {
                session.reset()
            } label: {
                Label("重置连接", systemImage: AppIcon.reset)
            }
        } label: {
            label()
        }
    }

    private var isBusy: Bool {
        switch session.connectionState {
        case .pairing, .awaitingWiFiJoin, .connecting, .connected, .disconnecting: return true
        case .disconnected, .error: return false
        }
    }
}

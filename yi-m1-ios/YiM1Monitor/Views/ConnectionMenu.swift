// Connect (BLE) / Connect (already on camera Wi-Fi) / Disconnect / Reset - port of
// main_window.py's titlebar QMenu (act_connect / act_connect_direct / act_disconnect /
// act_reset).
//
// Reworked 2026-07-12 (I2, top-bar rework): this used to be a separate trailing ellipsis
// button. The status chip truncated its text when connected ("Connected · 75% · 412 shots")
// because the "YI M1 Monitor" title ate the leading width it needed - the fix removes the
// title and makes the status chip itself this menu's tappable label, generic over whatever
// content RootView wants to show (so this file doesn't need to know about statusChip's
// internals).
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
                Label("Connect (Bluetooth)", systemImage: AppIcon.bluetooth)
            }
            .disabled(isBusy)

            Button {
                session.connectDirect()
            } label: {
                Label("Connect (already on camera Wi-Fi)", systemImage: AppIcon.wifi)
            }
            .disabled(isBusy)

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label("Disconnect", systemImage: AppIcon.disconnect)
            }
            .disabled(session.connectionState == .disconnected || session.connectionState == .disconnecting)

            Button {
                session.reset()
            } label: {
                Label("Reset connection", systemImage: AppIcon.reset)
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

import SwiftUI

struct FieldTipsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Tip: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private let tips: [Tip] = [
        Tip(
            icon: "antenna.radiowaves.left.and.right.slash",
            text: "开始拍摄前，请在“设置”里彻底关闭蓝牙（不是只在控制中心断开）。手机的蓝牙和 Wi-Fi 共用 2.4 GHz 天线，蓝牙开启会明显增加实时取景卡顿。"
        ),
        Tip(
            icon: "wifi.exclamationmark",
            text: "偶尔每隔几分钟出现短暂卡顿属于正常现象，并会自行恢复。iOS 会在后台扫描其他 Wi-Fi 网络；“链路较弱”提示指的是这种情况，不代表 App 卡死。"
        ),
        Tip(
            icon: "lock.iphone",
            text: "手机连接期间，相机自身屏幕和部分实体操作会被锁定，这是远程控制会话的正常行为，不是相机故障。"
        ),
        Tip(
            icon: "person.badge.shield.checkmark",
            text: "同一时间只能有一台设备控制相机。使用本 App 前请先断开官方 App。"
        ),
        Tip(
            icon: "video.badge.checkmark",
            text: "视频规格可以在连接后通过下方设置栏调整。4K 固定为 30p；1080p、720p 和隐藏的 240fps 慢动作模式可在支持的选项中切换。"
        ),
    ]

    var body: some View {
        NavigationView {
            List(tips) { tip in
                HStack(alignment: .top, spacing: AppSpace.md) {
                    Image(systemName: tip.icon)
                        .font(.system(size: AppLayout.isFourInchPhone ? 16 : 18))
                        .foregroundStyle(AppColor.accent)
                        .frame(width: 24)
                    Text(tip.text)
                        .font(.system(size: AppFont.body))
                        .foregroundStyle(AppColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, AppSpace.xs)
                .listRowBackground(AppColor.surface)
            }
            .background(AppColor.bg)
            .navigationTitle("稳定连接提示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

import SwiftUI
import YiM1Core

struct ShutterButton: View {
    var mode: CaptureMode
    var isRecording: Bool
    var isEnabled: Bool = true
    var action: () -> Void

    private var size: CGFloat { AppLayout.isFourInchPhone ? 68 : 76 }

    var body: some View {
        Button(action: action) {
            Canvas { context, canvasSize in
                let cx = canvasSize.width / 2
                let cy = canvasSize.height / 2
                let ringColor = isEnabled ? (mode == .photo ? AppColor.text : AppColor.record) : AppColor.text3
                let r = canvasSize.width / 2 - 4

                var ring = Path()
                ring.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                context.stroke(ring, with: .color(ringColor), lineWidth: 3)

                var inner = Path()
                switch mode {
                case .photo:
                    let ir = canvasSize.width * 0.36
                    inner.addEllipse(in: CGRect(x: cx - ir, y: cy - ir, width: 2 * ir, height: 2 * ir))
                case .video:
                    if isRecording {
                        let s = canvasSize.width * 0.30
                        inner.addRoundedRect(
                            in: CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s),
                            cornerSize: CGSize(width: 4, height: 4)
                        )
                    } else {
                        let ir = canvasSize.width * 0.21
                        inner.addEllipse(in: CGRect(x: cx - ir, y: cy - ir, width: 2 * ir, height: 2 * ir))
                    }
                }
                context.fill(inner, with: .color(ringColor))
            }
            .frame(width: size, height: size)
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .photo ? "拍照" : (isRecording ? "停止录像" : "开始录像"))
    }
}

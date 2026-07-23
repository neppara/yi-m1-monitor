// SF Symbols map for the guide/mode/file icons (Part 6: "Icons: SF Symbols, with one custom
// exception"). Diagonals has no matching symbol, so it's hand-drawn with a SwiftUI Path -
// same technique as the macOS ../yi-m1-remote-control/app/icons.py's _diagonals(), just via
// Canvas/Path instead of QPainter.
import SwiftUI

enum AppIcon {
    static let folder = "folder"
    static let folderFill = "folder.fill"
    static let crop = "crop"
    static let thirds = "squareshape.split.3x3"
    static let camera = "camera"
    static let cameraFill = "camera.fill"
    static let video = "video"
    static let videoFill = "video.fill"
    static let bluetooth = "dot.radiowaves.left.and.right"
    static let wifi = "wifi"
    static let disconnect = "xmark.circle"
    static let reset = "arrow.counterclockwise"
    static let settings = "slider.horizontal.3"
    static let trash = "trash"
    static let download = "arrow.down.circle"
    static let rotate = "rotate.right"
    static let peaking = "scope"
}

/// The one hand-drawn icon (no SF Symbol reads as "diagonals of a frame"). Bordered square +
/// both diagonals, stroked to match SF Symbols' default line weight at this size.
struct DiagonalsIcon: View {
    var color: Color = AppColor.text2
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let m = s * 0.12
            let rect = CGRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
            var path = Path()
            path.addRect(rect)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

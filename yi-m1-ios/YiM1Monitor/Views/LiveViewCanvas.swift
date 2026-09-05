import ImageIO
import SwiftUI
import YiM1Core

enum ViewRotation {
    case none
    case cw90
    case ccw90

    func next() -> ViewRotation {
        switch self {
        case .none: return .cw90
        case .cw90: return .ccw90
        case .ccw90: return .none
        }
    }

    var degrees: Double {
        switch self {
        case .none: return 0
        case .cw90: return 90
        case .ccw90: return -90
        }
    }

    var isRotated: Bool { self != .none }
}

private enum LiveFrameDecoding {
    static func decodeImmediately(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

@MainActor
final class LiveFrameDecoder: ObservableObject {
    @Published private(set) var image: UIImage?

    private let queue = DispatchQueue(label: "com.yim1.liveview.decode", qos: .userInteractive)
    private var isDecoding = false
    private var pendingData: Data?
    private var generation = 0

    func decode(_ data: Data) {
        guard !isDecoding else {
            pendingData = data
            return
        }
        isDecoding = true
        decodeNext(data, generation)
    }

    private func decodeNext(_ data: Data, _ expectedGeneration: Int) {
        queue.async { [weak self] in
            let decoded = LiveFrameDecoding.decodeImmediately(data)
            DispatchQueue.main.async {
                guard let self, expectedGeneration == self.generation else { return }
                self.image = decoded
                if let next = self.pendingData {
                    self.pendingData = nil
                    self.decodeNext(next, expectedGeneration)
                } else {
                    self.isDecoding = false
                }
            }
        }
    }

    func clear() {
        generation += 1
        image = nil
        pendingData = nil
        isDecoding = false
    }
}

struct LiveViewCanvas: View {
    var frameData: Data?
    var mode: CaptureMode
    var showCrop: Bool
    var showThirds: Bool
    var showDiagonals: Bool
    var isRecording: Bool
    var imageAspect: String?
    var videoFormat: String?
    var photoReview: PhotoReviewState
    var photoReviewImageData: Data?
    var rotation: ViewRotation = .none
    var peakingOverlay: UIImage?
    var onFocus: (Int, Int) -> Void
    var onNewFrame: ((Data) -> Void)?

    @StateObject private var frameDecoder = LiveFrameDecoder()
    @State private var reviewImage: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppColor.liveBG

                if let rawImage = frameDecoder.image {
                    let liveImage = recordingDisplayImage(rawImage)
                    let fitted = Self.fittedRect(imageSize: displaySize(of: liveImage.size), in: geo.size)
                    rotatedImage(liveImage, fitted: fitted)

                    if let peakingOverlay, shouldShowPeaking {
                        rotatedImage(recordingDisplayImage(peakingOverlay), fitted: fitted)
                            .allowsHitTesting(false)
                    }

                    overlay(fitted: fitted)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .allowsHitTesting(false)
                } else {
                    Text("未连接")
                        .font(.system(size: AppFont.value))
                        .foregroundStyle(AppColor.text3)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: recordingBarsCropApplies)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onEnded { value in
                        let location = value.location
                        guard let rawImage = frameDecoder.image else { return }
                        let liveImage = recordingDisplayImage(rawImage)
                        let fitted = Self.fittedRect(imageSize: displaySize(of: liveImage.size), in: geo.size)
                        guard fitted.contains(location) else { return }
                        let relX = (location.x - fitted.minX) / fitted.width
                        let relY = (location.y - fitted.minY) / fitted.height
                        let sensor = sensorRelativePoint(fromVisual: CGPoint(x: relX, y: relY))
                        onFocus(Int(sensor.x * liveImage.size.width), Int(sensor.y * liveImage.size.height))
                    }
            )
        }
        .background(AppColor.liveBG)
        .clipped()
        .onChange(of: frameData) { newValue in
            guard let newValue else {
                frameDecoder.clear()
                return
            }
            frameDecoder.decode(newValue)
            onNewFrame?(newValue)
        }
        .onChange(of: photoReviewImageData) { newValue in
            reviewImage = newValue.flatMap(UIImage.init(data:))
        }
    }

    private var shouldShowPeaking: Bool {
        switch photoReview {
        case .ready, .downloading: return false
        case .idle, .failed: return true
        }
    }

    private var recordingBarsCropApplies: Bool {
        guard isRecording, mode == .video, let videoFormat else { return false }
        let upper = videoFormat.uppercased()
        return upper.hasPrefix("FHD") || upper.hasPrefix("4K") || upper.hasPrefix("720P")
    }

    private func recordingDisplayImage(_ image: UIImage) -> UIImage {
        guard recordingBarsCropApplies, let cgImage = image.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let contentHeight = width * 9 / 16
        guard contentHeight < height - 2 else { return image }
        let contentRect = CGRect(x: 0, y: (height - contentHeight) / 2, width: width, height: contentHeight)
        guard let cropped = cgImage.cropping(to: contentRect) else { return image }
        return UIImage(cgImage: cropped)
    }

    private func displaySize(of imageSize: CGSize) -> CGSize {
        rotation.isRotated ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
    }

    @ViewBuilder
    private func rotatedImage(_ image: UIImage, fitted: CGRect) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.medium)
            .frame(
                width: rotation.isRotated ? fitted.height : fitted.width,
                height: rotation.isRotated ? fitted.width : fitted.height
            )
            .rotationEffect(.degrees(rotation.degrees))
            .position(x: fitted.midX, y: fitted.midY)
    }

    private func sensorRelativePoint(fromVisual p: CGPoint) -> CGPoint {
        switch rotation {
        case .none: return p
        case .cw90: return CGPoint(x: p.y, y: 1 - p.x)
        case .ccw90: return CGPoint(x: 1 - p.y, y: p.x)
        }
    }

    private func visualCrop(_ c: CropRect) -> CropRect {
        switch rotation {
        case .none: return c
        case .cw90: return CropRect(1 - c.y - c.height, c.x, c.height, c.width)
        case .ccw90: return CropRect(c.y, 1 - c.x - c.width, c.height, c.width)
        }
    }

    @ViewBuilder
    private func overlay(fitted: CGRect) -> some View {
        switch photoReview {
        case .ready:
            reviewOverlay
        case .downloading(let received, let total):
            downloadOverlay(bytesReceived: received, total: total)
        case .idle, .failed:
            guideOverlay
        }
    }

    private var reviewOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let reviewImage {
                GeometryReader { geo in
                    let fitted = Self.fittedRect(imageSize: displaySize(of: reviewImage.size), in: geo.size)
                    rotatedImage(reviewImage, fitted: fitted)
                }
            }
            Text("回放")
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text)
                .padding(8)
        }
    }

    private func downloadOverlay(bytesReceived: Int, total: Int) -> some View {
        VStack(spacing: AppSpace.sm) {
            Text("正在下载照片预览…")
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text)
            ProgressView(value: total > 0 ? Double(bytesReceived) / Double(total) : nil)
                .tint(AppColor.accent)
                .frame(maxWidth: AppLayout.isFourInchPhone ? 180 : 220)
            Text(total > 0
                 ? "\(Int(100 * Double(bytesReceived) / Double(total)))%"
                 : String(format: "%.1f KB", Double(bytesReceived) / 1024))
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guideOverlay: some View {
        Canvas { context, size in
            let fullRect = CGRect(origin: .zero, size: size)
            var guideRect = fullRect
            let cropShown = mode == .video || showCrop

            if isRecording {
                context.draw(
                    Text("● 正在录像 — 当前画面为实际裁切与曝光")
                        .font(.system(size: AppLayout.isFourInchPhone ? 9 : 10))
                        .foregroundColor(AppColor.record),
                    at: CGPoint(x: 8, y: 10),
                    anchor: .topLeading
                )
            } else if cropShown, let cropRect = crop() {
                let rect = cropCGRect(visualCrop(cropRect), in: fullRect)
                if rect != fullRect {
                    guideRect = rect
                    var outside = Path()
                    outside.addRect(fullRect)
                    outside.addRect(rect)
                    context.fill(
                        outside,
                        with: .color(.black.opacity(0.45)),
                        style: FillStyle(eoFill: true)
                    )
                }
                if mode == .photo || rect != fullRect {
                    drawCropOutline(rect, in: &context)
                }
            } else if cropShown, mode == .photo {
                context.draw(
                    Text("尚未读取照片画幅比例")
                        .font(.system(size: AppLayout.isFourInchPhone ? 9 : 10))
                        .foregroundColor(AppColor.accent),
                    at: CGPoint(x: 8, y: fullRect.maxY - 10),
                    anchor: .bottomLeading
                )
            }

            if showThirds {
                var path = Path()
                for i in [1, 2] {
                    let fx = guideRect.minX + guideRect.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: fx, y: guideRect.minY))
                    path.addLine(to: CGPoint(x: fx, y: guideRect.maxY))
                    let fy = guideRect.minY + guideRect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: guideRect.minX, y: fy))
                    path.addLine(to: CGPoint(x: guideRect.maxX, y: fy))
                }
                context.stroke(path, with: .color(AppColor.text.opacity(0.6)), lineWidth: 1)
            }

            if showDiagonals {
                var path = Path()
                path.move(to: CGPoint(x: guideRect.minX, y: guideRect.minY))
                path.addLine(to: CGPoint(x: guideRect.maxX, y: guideRect.maxY))
                path.move(to: CGPoint(x: guideRect.maxX, y: guideRect.minY))
                path.addLine(to: CGPoint(x: guideRect.minX, y: guideRect.maxY))
                context.stroke(path, with: .color(AppColor.text.opacity(0.47)), lineWidth: 1)
            }
        }
    }

    private func crop() -> CropRect? {
        mode == .video
            ? MeasuredCrops.videoCrop(forFormat: videoFormat)
            : MeasuredCrops.photoCrop(forAspect: imageAspect)
    }

    private func cropCGRect(_ crop: CropRect, in fullRect: CGRect) -> CGRect {
        CGRect(
            x: fullRect.minX + crop.x * fullRect.width,
            y: fullRect.minY + crop.y * fullRect.height,
            width: crop.width * fullRect.width,
            height: crop.height * fullRect.height
        )
    }

    private func drawCropOutline(_ rect: CGRect, in context: inout GraphicsContext) {
        var path = Path()
        path.addRect(rect)
        context.stroke(
            path,
            with: .color(AppColor.accent.opacity(0.9)),
            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
        )

        let label = mode == .video
            ? "视频裁切 · \(videoFormat ?? "?")"
            : "照片裁切 · \(imageAspect ?? "?")"
        context.draw(
            Text(label)
                .font(.system(size: AppLayout.isFourInchPhone ? 9 : 10))
                .foregroundColor(AppColor.accent),
            at: CGPoint(x: rect.minX + 6, y: rect.minY + 8),
            anchor: .topLeading
        )
    }

    static func fittedRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

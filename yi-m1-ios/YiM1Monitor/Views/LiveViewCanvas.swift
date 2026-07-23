// Live JPEG + overlays (crop/thirds/diagonals) + tap-to-focus + photo-review/download takeover.
// Port of ../yi-m1-remote-control/app/main_window.py's LiveViewWidget (paintEvent/_draw_crop),
// translated from QPainter to SwiftUI Canvas. Same rules: crop is mode-aware (photo/video),
// thirds/diagonals draw inside the crop rect when it's on else across the whole frame, the crop
// overlay hides while recording (the feed itself already shows the real crop then - macOS fact
// from ARCHITECTURE.md §12), and review/download-progress take over the whole frame.
//
// Rotation: the camera always streams frames in sensor orientation - when it's physically
// mounted sideways (vertical shooting), the preview arrives rotated. `rotation` is a manual,
// user-cycled view transform (requested 2026-07-09): the live image and photo review rotate,
// the guide overlays are drawn in *visual* space with the crop fractions transformed to match
// (so their text labels stay upright), and tap-to-focus inverse-maps back to sensor pixels.
import ImageIO
import SwiftUI
import YiM1Core

/// Manual live-view rotation for vertical shooting. UI-only - nothing about the camera protocol
/// changes; frames are just displayed turned.
enum ViewRotation {
    case none
    case cw90   // camera mounted with its right side down
    case ccw90  // camera mounted with its left side down

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

/// The actual decode work: a plain enum with no captured state and no actor isolation, so it can
/// run on a background `DispatchQueue` without Swift concurrency treating the call as crossing
/// an actor boundary (same reasoning as `FocusPeakingRenderer` - a `static func` on a
/// `@MainActor`-isolated type is itself MainActor-isolated, which would make calling it from a
/// background queue an implicitly-async cross-actor call the compiler warns about).
private enum LiveFrameDecoding {
    /// `UIImage(data:)` is lazy - it defers the actual pixel decode until first drawn, so
    /// decoding "on" a background queue alone isn't enough; the real cost would still land on
    /// the MainActor the first time SwiftUI drew the image. Forcing an immediate, fully-decoded
    /// bitmap via `CGImageSourceCreateImageAtIndex` + `kCGImageSourceShouldCacheImmediately`
    /// moves that cost here instead.
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

/// Decodes live-view JPEG bytes into a `UIImage` off the main thread, with the same mandatory
/// keep-latest frame-dropping `FocusPeakingProcessor` uses. Added 2026-07-11: moving the real
/// decode cost off the MainActor matters because MainActor contention was directly implicated in
/// an on-device stutter/fps-drop bug: `LiveViewReceiver`'s `.bufferingNewest(1)` policy makes the
/// live-view AsyncStream itself drop frames when the MainActor consumer falls behind, so keeping
/// this consumer fast reduces how often that happens.
@MainActor
final class LiveFrameDecoder: ObservableObject {
    @Published private(set) var image: UIImage?

    private let queue = DispatchQueue(label: "com.yim1.liveview.decode", qos: .userInteractive)
    private var isDecoding = false
    private var pendingData: Data?
    /// Bumped by `clear()` so an in-flight background decode can't resurrect the frame it was
    /// working on AFTER the clear - at ~25fps there is almost always a decode mid-flight the
    /// moment a disconnect clears the canvas, and without this guard its completion handler
    /// would land on the MainActor right after `clear()` and repaint the stale last frame
    /// (user-reported on-device 2026-07-12: frozen last frame instead of "Not connected").
    /// Same generation-counter pattern `FocusPeakingProcessor` already uses for the same reason.
    private var generation = 0

    func decode(_ data: Data) {
        guard !isDecoding else {
            pendingData = data // keep-latest: overwrite, don't queue
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
        // The in-flight completion (if any) is now generation-stale and will early-return
        // without ever resetting this - reset it here or the NEXT connection's first
        // decode(_:) would park everything in pendingData forever behind a flight that
        // already landed.
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
    /// Focus-peaking overlay (edges highlighted in the accent color, transparent elsewhere) -
    /// same pixel dimensions as the live frame it was derived from, so it's rendered through the
    /// exact same fitting/rotation path as the live image itself.
    var peakingOverlay: UIImage?
    var onFocus: (Int, Int) -> Void
    /// Fired from the same `onChange(of: frameData)` that feeds `frameDecoder`, instead of RootView
    /// separately re-observing `session.latestFrameData` on its own - two `.onChange` modifiers
    /// watching the same underlying `Data?` doubled the chance of SwiftUI's "tried to update
    /// multiple times per frame" fault when live-view frames arrive in a burst (observed
    /// on-device 2026-07-11). One observer, one dispatch point.
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
                    Text("Not connected")
                        .font(.system(size: AppFont.value))
                        .foregroundStyle(AppColor.text3)
                }
            }
            // Smooths the geometry change when the recording letterbox crop engages/disengages
            // (user feedback 2026-07-12: the switch snapped the image toward the edge for a
            // beat before settling) - the image now eases from the 4:3 preview footprint to
            // the cropped 16:9 one in place, centered the whole way.
            .animation(.easeInOut(duration: 0.25), value: recordingBarsCropApplies)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let rawImage = frameDecoder.image else { return }
                let liveImage = recordingDisplayImage(rawImage)
                let fitted = Self.fittedRect(imageSize: displaySize(of: liveImage.size), in: geo.size)
                guard fitted.contains(location) else { return }
                let relX = (location.x - fitted.minX) / fitted.width
                let relY = (location.y - fitted.minY) / fitted.height
                let sensor = sensorRelativePoint(fromVisual: CGPoint(x: relX, y: relY))
                onFocus(Int(sensor.x * liveImage.size.width), Int(sensor.y * liveImage.size.height))
            }
        }
        .background(AppColor.liveBG)
        .clipped()
        .onChange(of: frameData) { newValue in
            // A nil newValue (e.g. after disconnect) must clear the decoded image too, or the
            // last frame stays frozen on screen indefinitely - this early-returned before,
            // leaking the previous connection's freeze-frame into the next one.
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

    /// Hide peaking while the review/download takeover is showing - those already cover the
    /// whole frame with different content, and the review image isn't the live sensor feed.
    private var shouldShowPeaking: Bool {
        switch photoReview {
        case .ready, .downloading: return false
        case .idle, .failed: return true
        }
    }

    // MARK: - Recording letterbox crop

    /// During 16:9 video recording the camera bakes black letterbox bars INTO the stream (a 4:3
    /// frame with the 16:9 recording content centered inside - visible in the user's 2026-07-12
    /// field screenshots). Cropping them off at display time (user request, same day) both
    /// reclaims the wasted screen space and fixes the guides: thirds/diagonals span the visible
    /// frame during recording, which with the bars included was 4:3, not the real 16:9 capture
    /// area. 2K is deliberately excluded - its measured crop is the full sensor frame, so
    /// whether its recording stream is letterboxed at all is unverified.
    private var recordingBarsCropApplies: Bool {
        guard isRecording, mode == .video, let videoFormat else { return false }
        let upper = videoFormat.uppercased()
        return upper.hasPrefix("FHD") || upper.hasPrefix("4K")
    }

    /// Crops the baked-in letterbox bars (centered 16:9 content region) off a frame when
    /// `recordingBarsCropApplies`; returns the image unchanged otherwise. `CGImage.cropping` is
    /// cheap (it references the same backing pixels, no copy), so doing this per displayed frame
    /// on the MainActor is fine.
    private func recordingDisplayImage(_ image: UIImage) -> UIImage {
        guard recordingBarsCropApplies, let cgImage = image.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let contentHeight = width * 9 / 16
        guard contentHeight < height - 2 else { return image } // already 16:9 (or wider) - nothing to crop
        let contentRect = CGRect(x: 0, y: (height - contentHeight) / 2, width: width, height: contentHeight)
        guard let cropped = cgImage.cropping(to: contentRect) else { return image }
        return UIImage(cgImage: cropped)
    }

    // MARK: - Rotation helpers

    /// The size the image occupies on screen: 90-degree rotations swap width and height.
    private func displaySize(of imageSize: CGSize) -> CGSize {
        rotation.isRotated ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
    }

    /// Renders the image rotated inside `fitted` (which was computed from displaySize).
    /// rotationEffect is purely visual, so the inner frame uses the pre-rotation dimensions
    /// (fitted's, swapped back) and the outer position centers the rotated result.
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

    /// Maps a normalized point in visual (rotated, on-screen) space back to normalized sensor
    /// space, for tap-to-focus. Inverse of the rotation applied to the image.
    private func sensorRelativePoint(fromVisual p: CGPoint) -> CGPoint {
        switch rotation {
        case .none: return p
        case .cw90: return CGPoint(x: p.y, y: 1 - p.x)
        case .ccw90: return CGPoint(x: 1 - p.y, y: p.x)
        }
    }

    /// Transforms a sensor-space crop rect (normalized fractions) into visual space, so the
    /// guide overlay can be drawn unrotated (keeping its text labels upright).
    private func visualCrop(_ c: CropRect) -> CropRect {
        switch rotation {
        case .none: return c
        case .cw90: return CropRect(1 - c.y - c.height, c.x, c.height, c.width)
        case .ccw90: return CropRect(c.y, 1 - c.x - c.width, c.height, c.width)
        }
    }

    // MARK: - Overlays

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
            Text("Review")
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text)
                .padding(8)
        }
    }

    private func downloadOverlay(bytesReceived: Int, total: Int) -> some View {
        VStack(spacing: AppSpace.sm) {
            Text("Downloading photo preview…")
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text)
            ProgressView(value: total > 0 ? Double(bytesReceived) / Double(total) : nil)
                .tint(AppColor.accent)
                .frame(maxWidth: 220)
            Text(total > 0 ? "\(Int(100 * Double(bytesReceived) / Double(total)))%" : String(format: "%.1f KB", Double(bytesReceived) / 1024))
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guideOverlay: some View {
        Canvas { context, size in
            let fullRect = CGRect(origin: .zero, size: size)

            // Guide semantics (revised 2026-07-19 per user feedback): in VIDEO mode the crop is
            // a fact of the camera (FHD/4K always record 16:9 and the format can't be changed
            // remotely), so the crop overlay is ALWAYS shown there and guides follow it - the
            // toggle has no meaning. In PHOTO mode the crop is a choice (the aspect setting),
            // so the toggle governs both the overlay AND what the guides span: crop on ->
            // guides inside the capture area; crop off -> guides across the whole visible
            // frame. 2K is the video exception with no crop at all (4:3 full sensor, measured) -
            // its rect equals the full frame, so nothing extra is drawn.
            var guideRect = fullRect
            let cropShown = mode == .video || showCrop

            if isRecording {
                context.draw(
                    Text("● Recording — live view now shows the actual crop & exposure")
                        .font(.system(size: 10))
                        .foregroundColor(AppColor.record),
                    at: CGPoint(x: 8, y: 10), anchor: .topLeading
                )
            } else if cropShown, let cropRect = crop() {
                let rect = cropCGRect(visualCrop(cropRect), in: fullRect)
                if rect != fullRect {
                    guideRect = rect
                    // Dim everything OUTSIDE the capture area (user request 2026-07-12): the
                    // preview is wider than what actually gets recorded, so the to-be-cropped
                    // margins render darker while the real frame keeps full brightness. Even-odd
                    // fill of (full frame + crop rect) paints exactly the outside band.
                    var outside = Path()
                    outside.addRect(fullRect)
                    outside.addRect(rect)
                    context.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                }
                // The outline draws even when the crop IS the full frame in PHOTO mode (4:3):
                // the toggle is tappable there, and a tap with zero visible change reads as
                // broken (user feedback 2026-07-19). Video has no tappable toggle, so its
                // full-frame case (2K) stays clean.
                if mode == .photo || rect != fullRect {
                    drawCropOutline(rect, in: &context)
                }
            } else if cropShown, mode == .photo {
                context.draw(
                    Text("photo aspect not known yet")
                        .font(.system(size: 10))
                        .foregroundColor(AppColor.accent),
                    at: CGPoint(x: 8, y: fullRect.maxY - 10), anchor: .bottomLeading
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
        mode == .video ? MeasuredCrops.videoCrop(forFormat: videoFormat) : MeasuredCrops.photoCrop(forAspect: imageAspect)
    }

    /// Maps normalized crop fractions into canvas coordinates. Split from the outline drawing
    /// because thirds/diagonals need this rect even when the dashed outline is toggled off.
    private func cropCGRect(_ crop: CropRect, in fullRect: CGRect) -> CGRect {
        CGRect(
            x: fullRect.minX + crop.x * fullRect.width,
            y: fullRect.minY + crop.y * fullRect.height,
            width: crop.width * fullRect.width,
            height: crop.height * fullRect.height
        )
    }

    /// The dashed amber outline + label - drawn only when the Crop toggle is on.
    private func drawCropOutline(_ rect: CGRect, in context: inout GraphicsContext) {
        var path = Path()
        path.addRect(rect)
        context.stroke(path, with: .color(AppColor.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

        let label = mode == .video ? "video crop · \(videoFormat ?? "?")" : "photo crop · \(imageAspect ?? "?")"
        context.draw(
            Text(label).font(.system(size: 10)).foregroundColor(AppColor.accent),
            at: CGPoint(x: rect.minX + 6, y: rect.minY + 8), anchor: .topLeading
        )
    }

    static func fittedRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: containerSize) }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (containerSize.width - width) / 2, y: (containerSize.height - height) / 2, width: width, height: height)
    }
}

// Manual-focus assist: highlights high-contrast (in-focus) edges over live view in the accent
// color. The user shoots a manual-focus lens - this is the highest-value monitor feature, and
// unlike exposure-based tools (histogram/zebras), it isn't invalidated by the live-view preview's
// known auto-exposure quirk (edges are edges regardless of brightness), so it works pre-record.
@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// The actual Core Image pipeline: JPEG bytes -> edge detection -> threshold -> colorize (amber
/// on transparent). Free functions on a plain enum (no captured state, no actor isolation) so
/// they can run on a background DispatchQueue without fighting Swift concurrency's Sendable
/// checking around CIContext.
enum FocusPeakingRenderer {
    static let edgeIntensity: Float = 3.0
    static let edgeThreshold: Float = 0.2

    /// AppColor.accent (#f5a623) as a CIColor - kept independent of Design/Theme.swift's SwiftUI
    /// `Color` (Core Image wants its own color type).
    static let peakColor = CIColor(red: 245.0 / 255, green: 166.0 / 255, blue: 35.0 / 255, alpha: 1)
    private static let clearColor = CIColor(red: 0, green: 0, blue: 0, alpha: 0)

    static func render(_ jpegData: Data, context: CIContext) -> UIImage? {
        guard let ciImage = CIImage(data: jpegData) else { return nil }
        let extent = ciImage.extent

        let edges = CIFilter.edges()
        edges.inputImage = ciImage
        edges.intensity = edgeIntensity
        guard let edgedImage = edges.outputImage else { return nil }

        let thresholdFilter = CIFilter.colorThreshold()
        thresholdFilter.inputImage = edgedImage
        thresholdFilter.threshold = edgeThreshold
        guard let maskImage = thresholdFilter.outputImage else { return nil }

        let amberImage = CIImage(color: peakColor).cropped(to: extent)
        let clearImage = CIImage(color: clearColor).cropped(to: extent)

        // Wherever the (white-on-black) threshold mask is white (an edge), show the amber
        // constant-color image; wherever it's black, show the fully transparent one.
        let blend = CIFilter.blendWithMask()
        blend.inputImage = amberImage
        blend.backgroundImage = clearImage
        blend.maskImage = maskImage

        guard let blended = blend.outputImage?.cropped(to: extent),
              let cgImage = context.createCGImage(blended, from: extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Drives the renderer off incoming live-view frames with mandatory frame-dropping: the ~10-15fps
/// feed easily outruns Core Image's per-frame cost, so a new frame arriving mid-render replaces
/// whatever was queued rather than piling up a backlog.
@MainActor
final class FocusPeakingProcessor: ObservableObject {
    @Published private(set) var overlay: UIImage?

    private let context = CIContext()
    private let queue = DispatchQueue(label: "com.yim1.focuspeaking", qos: .userInitiated)
    private var isProcessing = false
    private var pendingData: Data?
    /// Bumped by clear() so a render that was already in flight when peaking got toggled off
    /// can't paint a stale overlay back in after the fact.
    private var generation = 0

    func process(_ frameData: Data) {
        guard !isProcessing else {
            pendingData = frameData // keep-latest: overwrite, don't queue
            return
        }
        isProcessing = true
        renderNext(frameData)
    }

    private func renderNext(_ data: Data) {
        let ctx = context
        let thisGeneration = generation
        queue.async { [weak self] in
            let result = FocusPeakingRenderer.render(data, context: ctx)
            DispatchQueue.main.async {
                guard let self, self.generation == thisGeneration else { return }
                self.overlay = result
                if let next = self.pendingData {
                    self.pendingData = nil
                    self.renderNext(next)
                } else {
                    self.isProcessing = false
                }
            }
        }
    }

    /// Called when peaking is toggled off (or on disconnect) - drops the overlay immediately and
    /// invalidates any render still in flight.
    func clear() {
        generation += 1
        overlay = nil
        pendingData = nil
        isProcessing = false
    }
}

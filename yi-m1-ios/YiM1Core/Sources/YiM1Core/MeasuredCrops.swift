// Real measured crop rectangles - exact port of yi-m1-remote-control/app/main_window.py's
// MEASURED_VIDEO_CROPS / MEASURED_PHOTO_CROPS (2026-07-07).
//
// Measured empirically via a tripod session: a 4:3 reference photo (full sensor FOV, no crop)
// plus one recording per video resolution and one photo per aspect ratio, each smaller frame
// located within the reference via OpenCV multi-scale template matching (methodology + match
// confidence scores >0.95 in fable research/live-testing-findings.md section 10).
import Foundation

/// (x0, y0, w, h) as fractions of the full 4:3 sensor frame.
public struct CropRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum MeasuredCrops {
    /// Keyed by the resolution PREFIX of the "VideoFormat" metadata field (e.g. "FHD_30" starts
    /// with "FHD"), not the exact string - the framerate suffix was only directly confirmed for
    /// FHD_30 in metadata; prefix matching is robust to variants like "4K_24".
    public static let video: [(prefix: String, rect: CropRect)] = [
        ("2K", CropRect(0.0000, 0.0000, 1.0000, 1.0000)),  // 2048x1536, 4:3 - full sensor, just downscaled
        ("FHD", CropRect(0.0004, 0.1268, 0.9961, 0.7472)), // 1920x1080, 16:9 - same geometry as the 16:9 photo crop
        ("4K", CropRect(0.1294, 0.2230, 0.7409, 0.5558)),  // 3840x2160, 16:9 - real ~74%x56% crop, near-native readout
    ]

    /// Keyed by the EXACT "ImageAspect" value (this setting genuinely changes live via
    /// RCImageAspect, unlike VideoFormat, so exact matching is appropriate and reliable).
    public static let photo: [String: CropRect] = [
        "4:3": CropRect(0.0000, 0.0000, 1.0000, 1.0000),
        "3:2": CropRect(0.0000, 0.0556, 1.0000, 0.8889),
        "16:9": CropRect(0.0000, 0.1247, 1.0000, 0.7510),
        "1:1": CropRect(0.1250, 0.0000, 0.7500, 1.0000),
    ]

    /// Finds the video crop rect for a given VideoFormat metadata value via prefix match, or
    /// nil if unmeasured (callers should fall back to an approximate 16:9 centered guess).
    public static func videoCrop(forFormat format: String?) -> CropRect? {
        guard let format = format?.uppercased() else { return nil }
        return video.first(where: { format.hasPrefix($0.prefix) })?.rect
    }

    public static func photoCrop(forAspect aspect: String?) -> CropRect? {
        guard let aspect else { return nil }
        return photo[aspect]
    }
}

// Lazy, in-memory thumbnail cache for the file browser rows. Not generic over Session itself
// (so a single @StateObject instance works regardless of which concrete session the browser is
// specialized on) - the session is passed per-call instead.
import SwiftUI
import YiM1Core

@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var failedPaths: Set<String> = []
    private var inFlightPaths: Set<String> = []

    func image(for file: CameraFile) -> UIImage? {
        images[file.path]
    }

    func hasFailed(_ file: CameraFile) -> Bool {
        failedPaths.contains(file.path)
    }

    /// Fetches a `.fast` (Thumbnail-quality) preview for `file` unless it's already
    /// cached/failed/in flight. Meant to be driven by `.task(id: file.path)` on each row, so
    /// scrolling a row out of the tree cancels its still-pending fetch automatically - the
    /// `Task.isCancelled` check right before the HTTP call additionally guards against firing a
    /// request that's already been superseded (the camera only handles one request at a time, so
    /// a burst of stale requests would just clog the queue instead of silently failing).
    func load<Session: CameraSessionProtocol>(_ file: CameraFile, session: Session) async {
        // The camera has no thumbnail for video: asking for one makes it ignore the quality
        // parameter and stream the entire clip, which tore down the whole session on macOS
        // before this was fixed (2026-07-24). Skip video entirely - the row shows its icon.
        guard !file.isVideo else { return }
        guard images[file.path] == nil, !failedPaths.contains(file.path), !inFlightPaths.contains(file.path) else { return }
        guard !Task.isCancelled else { return }

        inFlightPaths.insert(file.path)
        defer { inFlightPaths.remove(file.path) }

        do {
            // Thumbnail quality is on-device unverified (see DEVELOPMENT_PLAN.md) - if the camera
            // doesn't honor it, this just falls back to MidThumb-sized data, still correct.
            let data = try await session.fetchFileData(file.path, quality: .fast)
            guard !Task.isCancelled else { return }
            if let image = UIImage(data: data) {
                images[file.path] = image
            } else {
                // Video files likely don't decode as a still image via this quality - cache the
                // failure so we don't retry every time the row scrolls back into view.
                failedPaths.insert(file.path)
            }
        } catch {
            guard !Task.isCancelled else { return }
            failedPaths.insert(file.path)
        }
    }
}

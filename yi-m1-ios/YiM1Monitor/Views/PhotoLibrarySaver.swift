// Saving downloaded camera files into the user's Photos library - used by both FileDetailView
// (single file) and FileBrowserView's selection-mode batch action. Requires
// NSPhotoLibraryAddUsageDescription in Info.plist (declared in project.yml) or the
// authorization request silently fails / the app crashes on the actual write.
import Photos
import YiM1Core

enum PhotoLibrarySaver {
    /// Add-only authorization (iOS 14+) - this app only ever adds files, never reads/enumerates
    /// the user's existing library, so the narrower `.addOnly` level is the correct (and more
    /// privacy-respecting) request over full read/write access.
    static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Downloads `file` at Original quality (via the existing progress-reporting
    /// `downloadFile(to:)`, into a temp file so large videos don't need to sit fully in memory)
    /// and adds it to the Photos library as a photo or video resource per `file.isVideo`.
    static func downloadAndSave<Session: CameraSessionProtocol>(
        _ file: CameraFile,
        session: Session,
        onProgress: @escaping (Double?) -> Void
    ) async throws {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try await session.downloadFile(file.path, quality: .best, to: tmpURL) { received, total in
            onProgress(total > 0 ? Double(received) / Double(total) : nil)
        }

        if file.isVideo {
            try await saveVideo(fileURL: tmpURL)
        } else {
            let data = try Data(contentsOf: tmpURL)
            try await saveImage(data)
        }
    }

    private static func saveImage(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    private static func saveVideo(fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: fileURL, options: nil)
        }
    }
}

// File detail screen - the discoverable replacement for swipe-only actions (user feedback
// 2026-07-11: swipe-to-reveal download/delete was unintuitive). Reached by tapping a row in
// FileBrowserView; shows a MidThumb preview + metadata + explicit Save to Photos / Share /
// Delete buttons.
import SwiftUI
import YiM1Core

struct FileDetailView<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    let file: CameraFile
    /// Called after a successful delete, so the browser list can refresh - this view also
    /// dismisses itself right after (nothing left to show).
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previewImage: UIImage?
    @State private var previewFailed = false
    @State private var isWorking = false
    @State private var workingLabel = ""
    @State private var workingProgress: Double?
    @State private var shareItem: ShareItem?
    @State private var confirmDelete = false
    @State private var resultMessage: String?
    @State private var showResult = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpace.lg) {
                previewArea
                metadataSection
                actionButtons
            }
            .padding(AppSpace.lg)
        }
        .background(AppColor.bg)
        .navigationTitle(file.filename)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPreview() }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert("Delete file?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await performDelete() } }
        } message: {
            Text("Delete \(file.filename) from the camera? This cannot be undone.")
        }
        .alert("Save to Photos", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        .overlay {
            if isWorking { workingOverlay }
        }
    }

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md).fill(AppColor.surface)
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            } else if previewFailed {
                VStack(spacing: AppSpace.sm) {
                    Image(systemName: file.isVideo ? AppIcon.video : AppIcon.camera)
                        .font(.system(size: 32))
                        .foregroundStyle(AppColor.text3)
                    Text(file.isVideo ? "No preview for video" : "No preview available")
                        .font(.system(size: AppFont.caption))
                        .foregroundStyle(AppColor.text3)
                    if file.isVideo {
                        // Says why, so it does not read as a bug. The camera genuinely cannot
                        // render a still for a clip - see FileDetailView.loadPreview.
                        Text("The camera cannot render one.\nDownload the clip to view it.")
                            .font(.system(size: AppFont.caption))
                            .foregroundStyle(AppColor.text3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                ProgressView().tint(AppColor.accent)
            }
        }
        .frame(height: 280)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            metadataRow(label: "Type", value: file.filetype.isEmpty ? "—" : file.filetype)
            if let date = file.date {
                metadataRow(label: "Date", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            metadataRow(label: "Protected", value: file.isProtected ? "Yes" : "No")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpace.md)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(AppColor.text2)
            Spacer()
            Text(value).foregroundStyle(AppColor.text)
        }
        .font(.system(size: AppFont.body))
    }

    private var actionButtons: some View {
        VStack(spacing: AppSpace.sm) {
            Button {
                Task { await saveToPhotos() }
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColor.accent)

            Button {
                Task { await shareFile() }
            } label: {
                Label("Share / Download", systemImage: AppIcon.download)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: AppIcon.trash)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .disabled(isWorking)
    }

    private var workingOverlay: some View {
        VStack(spacing: AppSpace.sm) {
            Text(workingLabel)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text)
            ProgressView(value: workingProgress)
                .tint(AppColor.accent)
                .frame(maxWidth: 220)
        }
        .padding(AppSpace.lg)
        .background(AppColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func loadPreview() async {
        // Video has no preview on this camera, and asking for one is actively harmful: the
        // camera ignores the quality parameter and starts streaming the whole clip, which tore
        // the session down entirely on macOS (2026-07-24). The comment here used to claim video
        // was excluded while nothing actually checked - now it does.
        guard !file.isVideo else {
            previewFailed = true
            return
        }
        do {
            // MidThumb (~228KB) - the same quality the post-shot review uses; it's known to
            // decode fine (occasional "premature end of data" log warnings are harmless, see
            // DEVELOPMENT_PLAN.md).
            let data = try await session.fetchFileData(file.path, quality: .medium)
            if let image = UIImage(data: data) {
                previewImage = image
            } else {
                previewFailed = true
            }
        } catch {
            previewFailed = true
        }
    }

    private func shareFile() async {
        isWorking = true
        workingLabel = "Preparing file…"
        workingProgress = 0
        defer { isWorking = false }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
        do {
            try await session.downloadFile(file.path, quality: .best, to: tmpURL) { received, total in
                Task { @MainActor in
                    workingProgress = total > 0 ? Double(received) / Double(total) : nil
                }
            }
            shareItem = ShareItem(url: tmpURL)
        } catch {
            resultMessage = "Download failed: \(error)"
            showResult = true
        }
    }

    private func saveToPhotos() async {
        isWorking = true
        workingLabel = "Saving to Photos…"
        workingProgress = nil
        defer { isWorking = false }

        guard await PhotoLibrarySaver.requestAuthorization() else {
            resultMessage = "Photos access was denied. Enable it in Settings to save files."
            showResult = true
            return
        }
        do {
            try await PhotoLibrarySaver.downloadAndSave(file, session: session) { progress in
                Task { @MainActor in workingProgress = progress }
            }
            resultMessage = "Saved to Photos."
        } catch {
            resultMessage = "Save failed: \(error)"
        }
        showResult = true
    }

    private func performDelete() async {
        isWorking = true
        workingLabel = "Deleting…"
        workingProgress = nil
        defer { isWorking = false }
        if await session.deleteFiles([file.path]) {
            onDeleted()
            dismiss()
        } else {
            resultMessage = "Delete failed."
            showResult = true
        }
    }
}

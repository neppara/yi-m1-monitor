// Browse/download/delete files on the camera's SD card - port of main_window.py's
// FileBrowserDialog, reworked 2026-07-11 (user feedback: swipe-to-reveal actions were
// unintuitive). Now: thumbnails per row, tap a row -> FileDetailView with explicit
// Save-to-Photos/Share/Delete buttons, and a Select mode for batch delete/save. Swipe actions are
// kept as a shortcut for anyone who already reached for them.
import SwiftUI
import YiM1Core

struct FileBrowserView<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbnails = ThumbnailStore()

    private enum LoadState {
        case loading, loaded, empty, error(String)
    }

    @State private var files: [CameraFile] = []
    @State private var loadState: LoadState = .loading
    @State private var downloadingPath: String?
    @State private var downloadProgress: (received: Int, total: Int) = (0, 0)
    @State private var shareItem: ShareItem?
    @State private var pendingDeletePaths: [String]?
    @State private var editMode: EditMode = .inactive
    @State private var selectedPaths: Set<String> = []
    @State private var isBatchWorking = false
    @State private var batchWorkingLabel = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Camera files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(editMode == .active ? "Done" : "Close") {
                            if editMode == .active {
                                exitSelectionMode()
                            } else {
                                dismiss()
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        if editMode != .active {
                            Button("Select") { editMode = .active }
                            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        if editMode == .active {
                            Button(role: .destructive) {
                                pendingDeletePaths = Array(selectedPaths)
                            } label: {
                                Text("Delete (\(selectedPaths.count))")
                            }
                            .disabled(selectedPaths.isEmpty || isBatchWorking)
                            Spacer()
                            Button {
                                Task { await batchSaveToPhotos() }
                            } label: {
                                Text("Save to Photos (\(selectedPaths.count))")
                            }
                            .disabled(selectedPaths.isEmpty || isBatchWorking)
                        }
                    }
                }
                .background(AppColor.bg)
        }
        .task { await refresh() }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert(pendingDeletePaths?.count == 1 ? "Delete file?" : "Delete files?", isPresented: Binding(
            get: { pendingDeletePaths != nil },
            set: { if !$0 { pendingDeletePaths = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletePaths = nil }
            Button("Delete", role: .destructive) {
                if let paths = pendingDeletePaths { Task { await performDelete(paths) } }
                pendingDeletePaths = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .overlay {
            if downloadingPath != nil { downloadOverlay }
            if isBatchWorking { batchWorkingOverlay }
        }
    }

    private var deleteConfirmationMessage: String {
        guard let paths = pendingDeletePaths else { return "" }
        if paths.count == 1, let file = files.first(where: { $0.path == paths[0] }) {
            return "Delete \(file.filename) from the camera? This cannot be undone."
        }
        return "Delete \(paths.count) files from the camera? This cannot be undone."
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView().tint(AppColor.accent)
        case .empty:
            Text("(no files)").foregroundStyle(AppColor.text3)
        case .error(let message):
            ScrollView { Text(message).foregroundStyle(AppColor.text3).padding() }
        case .loaded:
            List(selection: $selectedPaths) {
                ForEach(files) { file in
                    NavigationLink(destination: FileDetailView(session: session, file: file, onDeleted: {
                        Task { await refresh() }
                    })) {
                        fileRow(file)
                    }
                    .listRowBackground(AppColor.surface)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDeletePaths = [file.path] } label: {
                            Label("Delete", systemImage: AppIcon.trash)
                        }
                        Button { Task { await download(file) } } label: {
                            Label("Download", systemImage: AppIcon.download)
                        }
                        .tint(AppColor.accent)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .scrollContentBackground(.hidden)
        }
    }

    private func fileRow(_ file: CameraFile) -> some View {
        HStack(spacing: AppSpace.md) {
            thumbnailView(file)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename).foregroundStyle(AppColor.text)
                HStack(spacing: 6) {
                    Text(file.filetype).foregroundStyle(AppColor.text3)
                    if let date = file.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(AppColor.text3)
                    }
                }
                .font(.system(size: AppFont.caption))
            }
            Spacer()
            if file.isProtected {
                Image(systemName: "lock.fill").foregroundStyle(AppColor.text3)
            }
        }
    }

    private func thumbnailView(_ file: CameraFile) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(AppColor.surface2)
            if let image = thumbnails.image(for: file) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if thumbnails.hasFailed(file) {
                Image(systemName: file.isVideo ? AppIcon.video : AppIcon.camera)
                    .font(.system(size: 18))
                    .foregroundStyle(AppColor.text3)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: file.path) {
            await thumbnails.load(file, session: session)
        }
    }

    private var downloadOverlay: some View {
        VStack(spacing: AppSpace.sm) {
            Text("Downloading…")
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text)
            ProgressView(value: downloadProgress.total > 0 ? Double(downloadProgress.received) / Double(downloadProgress.total) : nil)
                .tint(AppColor.accent)
                .frame(maxWidth: 220)
        }
        .padding(AppSpace.lg)
        .background(AppColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var batchWorkingOverlay: some View {
        VStack(spacing: AppSpace.sm) {
            Text(batchWorkingLabel)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text)
            ProgressView()
                .tint(AppColor.accent)
        }
        .padding(AppSpace.lg)
        .background(AppColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func exitSelectionMode() {
        editMode = .inactive
        selectedPaths = []
    }

    private func refresh() async {
        loadState = .loading
        switch await session.listFiles() {
        case .ok(let list):
            files = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            loadState = files.isEmpty ? .empty : .loaded
        case .unrecognized(let raw):
            loadState = .error("Unrecognized response shape:\n\(raw)")
        case .httpError(let status, let preview):
            loadState = .error("GetFileList failed (status=\(status)):\n\(preview)")
        case .parseFailure(let preview):
            loadState = .error("Could not parse response:\n\(preview)")
        }
    }

    private func download(_ file: CameraFile) async {
        downloadingPath = file.path
        downloadProgress = (0, 0)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
        do {
            try await session.downloadFile(file.path, quality: .best, to: tmpURL) { received, total in
                Task { @MainActor in downloadProgress = (received, total) }
            }
            downloadingPath = nil
            shareItem = ShareItem(url: tmpURL)
        } catch {
            downloadingPath = nil
            loadState = .error("Download failed: \(error)")
        }
    }

    private func performDelete(_ paths: [String]) async {
        if await session.deleteFiles(paths) {
            selectedPaths.subtract(paths)
            await refresh()
        } else {
            loadState = .error("Delete failed for \(paths.count == 1 ? "the selected file" : "\(paths.count) files")")
        }
    }

    /// Sequential (not parallel) - the camera only handles one HTTP request at a time, so
    /// downloading files concurrently would just queue up anyway; sequential also lets progress
    /// be reported meaningfully as "N of M" instead of several bars moving at once.
    private func batchSaveToPhotos() async {
        let targets = files.filter { selectedPaths.contains($0.path) }
        guard !targets.isEmpty else { return }

        isBatchWorking = true
        batchWorkingLabel = "Saving 0 of \(targets.count)…"
        defer { isBatchWorking = false }

        guard await PhotoLibrarySaver.requestAuthorization() else {
            loadState = .error("Photos access was denied. Enable it in Settings to save files.")
            return
        }

        for (index, file) in targets.enumerated() {
            batchWorkingLabel = "Saving \(index + 1) of \(targets.count)…"
            do {
                try await PhotoLibrarySaver.downloadAndSave(file, session: session) { _ in }
            } catch {
                loadState = .error("Saved \(index) of \(targets.count) - stopped after \(file.filename) failed: \(error)")
                return
            }
        }
        exitSelectionMode()
    }
}

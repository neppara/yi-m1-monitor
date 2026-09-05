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
        NavigationView {
            content
                .navigationTitle("相机文件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(editMode == .active ? "完成" : "关闭") {
                            if editMode == .active {
                                exitSelectionMode()
                            } else {
                                dismiss()
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        if editMode != .active {
                            Button("选择") { editMode = .active }
                            Button { Task { await refresh() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("刷新")
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        if editMode == .active {
                            Button(role: .destructive) {
                                pendingDeletePaths = Array(selectedPaths)
                            } label: {
                                Text("删除（\(selectedPaths.count)）")
                            }
                            .disabled(selectedPaths.isEmpty || isBatchWorking)
                            Spacer()
                            Button {
                                Task { await batchSaveToPhotos() }
                            } label: {
                                Text("存入照片（\(selectedPaths.count)）")
                            }
                            .disabled(selectedPaths.isEmpty || isBatchWorking)
                        }
                    }
                }
                .background(AppColor.bg)
        }
        .navigationViewStyle(.stack)
        .task { await refresh() }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert(pendingDeletePaths?.count == 1 ? "删除文件？" : "删除多个文件？", isPresented: Binding(
            get: { pendingDeletePaths != nil },
            set: { if !$0 { pendingDeletePaths = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeletePaths = nil }
            Button("删除", role: .destructive) {
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
            return "确定从相机中删除 \(file.filename) 吗？此操作无法撤销。"
        }
        return "确定从相机中删除这 \(paths.count) 个文件吗？此操作无法撤销。"
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView().tint(AppColor.accent)
        case .empty:
            Text("暂无文件").foregroundStyle(AppColor.text3)
        case .error(let message):
            ScrollView {
                Text(message)
                    .font(.system(size: AppFont.body))
                    .foregroundStyle(AppColor.text3)
                    .padding()
            }
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
                            Label("删除", systemImage: AppIcon.trash)
                        }
                        Button { Task { await download(file) } } label: {
                            Label("下载", systemImage: AppIcon.download)
                        }
                        .tint(AppColor.accent)
                    }
                }
            }
            .environment(\.editMode, $editMode)
        }
    }

    private func fileRow(_ file: CameraFile) -> some View {
        HStack(spacing: AppSpace.md) {
            thumbnailView(file)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.system(size: AppFont.body))
                    .foregroundStyle(AppColor.text)
                    .lineLimit(1)
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
        let side: CGFloat = AppLayout.isFourInchPhone ? 50 : 56
        return ZStack {
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
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: file.path) {
            await thumbnails.load(file, session: session)
        }
    }

    private var downloadOverlay: some View {
        VStack(spacing: AppSpace.sm) {
            Text("正在下载…")
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text)
            ProgressView(value: downloadProgress.total > 0 ? Double(downloadProgress.received) / Double(downloadProgress.total) : nil)
                .tint(AppColor.accent)
                .frame(maxWidth: AppLayout.isFourInchPhone ? 180 : 220)
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
            ProgressView().tint(AppColor.accent)
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
            loadState = .error("无法识别相机返回的数据：\n\(raw)")
        case .httpError(let status, let preview):
            loadState = .error("读取文件列表失败（状态码 \(status)）：\n\(preview)")
        case .parseFailure(let preview):
            loadState = .error("无法解析相机返回的数据：\n\(preview)")
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
            loadState = .error("下载失败：\(error)")
        }
    }

    private func performDelete(_ paths: [String]) async {
        if await session.deleteFiles(paths) {
            selectedPaths.subtract(paths)
            await refresh()
        } else {
            loadState = .error(paths.count == 1 ? "删除所选文件失败。" : "删除 \(paths.count) 个文件失败。")
        }
    }

    private func batchSaveToPhotos() async {
        let targets = files.filter { selectedPaths.contains($0.path) }
        guard !targets.isEmpty else { return }

        isBatchWorking = true
        batchWorkingLabel = "正在保存 0 / \(targets.count)…"
        defer { isBatchWorking = false }

        guard await PhotoLibrarySaver.requestAuthorization() else {
            loadState = .error("没有“照片”访问权限。请在系统设置中允许后再保存。")
            return
        }

        for (index, file) in targets.enumerated() {
            batchWorkingLabel = "正在保存 \(index + 1) / \(targets.count)…"
            do {
                try await PhotoLibrarySaver.downloadAndSave(file, session: session) { _ in }
            } catch {
                loadState = .error("已保存 \(index) / \(targets.count)，\(file.filename) 保存失败：\(error)")
                return
            }
        }
        exitSelectionMode()
    }
}

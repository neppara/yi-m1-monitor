import SwiftUI
import YiM1Core

struct FileDetailView<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    let file: CameraFile
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
        .alert("删除文件？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await performDelete() } }
        } message: {
            Text("确定从相机中删除 \(file.filename) 吗？此操作无法撤销。")
        }
        .alert("保存到照片", isPresented: $showResult) {
            Button("好", role: .cancel) {}
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
                        .font(.system(size: AppLayout.isFourInchPhone ? 28 : 32))
                        .foregroundStyle(AppColor.text3)
                    Text(file.isVideo ? "视频没有预览图" : "没有可用预览")
                        .font(.system(size: AppFont.caption))
                        .foregroundStyle(AppColor.text3)
                    if file.isVideo {
                        Text("相机无法为视频生成静态预览。\n请下载视频后查看。")
                            .font(.system(size: AppFont.caption))
                            .foregroundStyle(AppColor.text3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                ProgressView().tint(AppColor.accent)
            }
        }
        .frame(height: AppLayout.isFourInchPhone ? 220 : 280)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            metadataRow(label: "类型", value: file.filetype.isEmpty ? "—" : file.filetype)
            if let date = file.date {
                metadataRow(label: "日期", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            metadataRow(label: "保护", value: file.isProtected ? "是" : "否")
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
                Label("保存到照片", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColor.accent)

            Button {
                Task { await shareFile() }
            } label: {
                Label("分享 / 下载", systemImage: AppIcon.download)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: AppIcon.trash)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .font(.system(size: AppFont.body))
        .disabled(isWorking)
    }

    private var workingOverlay: some View {
        VStack(spacing: AppSpace.sm) {
            Text(workingLabel)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text)
            ProgressView(value: workingProgress)
                .tint(AppColor.accent)
                .frame(maxWidth: AppLayout.isFourInchPhone ? 180 : 220)
        }
        .padding(AppSpace.lg)
        .background(AppColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func loadPreview() async {
        guard !file.isVideo else {
            previewFailed = true
            return
        }
        do {
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
        workingLabel = "正在准备文件…"
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
            resultMessage = "下载失败：\(error)"
            showResult = true
        }
    }

    private func saveToPhotos() async {
        isWorking = true
        workingLabel = "正在保存到照片…"
        workingProgress = nil
        defer { isWorking = false }

        guard await PhotoLibrarySaver.requestAuthorization() else {
            resultMessage = "没有“照片”访问权限。请在系统设置中允许后再保存。"
            showResult = true
            return
        }
        do {
            try await PhotoLibrarySaver.downloadAndSave(file, session: session) { progress in
                Task { @MainActor in workingProgress = progress }
            }
            resultMessage = "已保存到照片。"
        } catch {
            resultMessage = "保存失败：\(error)"
        }
        showResult = true
    }

    private func performDelete() async {
        isWorking = true
        workingLabel = "正在删除…"
        workingProgress = nil
        defer { isWorking = false }
        if await session.deleteFiles([file.path]) {
            onDeleted()
            dismiss()
        } else {
            resultMessage = "删除失败。"
            showResult = true
        }
    }
}

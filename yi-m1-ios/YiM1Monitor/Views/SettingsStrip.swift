import SwiftUI
import YiM1Core

struct SettingsStrip<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    @State private var expandedKey: SettingKey?

    private var keys: [SettingKey] { SettingCatalog.keys(forMode: session.mode) }

    var body: some View {
        VStack(spacing: 0) {
            if let key = expandedKey {
                ValueQuickPicker(
                    session: session,
                    key: key,
                    title: ChineseUI.settingTitle(key)
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { expandedKey = nil }
                }
                .id(key)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpace.sm) {
                    ForEach(keys, id: \.self) { key in
                        chip(for: key)
                    }
                    if session.mode == .video {
                        autoRestartChip
                    }
                }
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.sm)
            }
        }
        .onChange(of: session.mode) { _ in expandedKey = nil }
    }

    private func chip(for key: SettingKey) -> some View {
        let isExpanded = expandedKey == key
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedKey = isExpanded ? nil : key
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ChineseUI.settingTitle(key))
                    .font(.system(size: AppFont.caption))
                    .foregroundStyle(isExpanded ? AppColor.accent : AppColor.text3)

                ZStack(alignment: .leading) {
                    Text(widestValueLabel(for: key))
                        .font(.system(size: AppFont.value, weight: .medium))
                        .lineLimit(1)
                        .hidden()
                    Text(displayValue(for: key))
                        .font(.system(size: AppFont.value, weight: .medium))
                        .foregroundStyle(isExpanded ? AppColor.accent : AppColor.text)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, AppLayout.isFourInchPhone ? AppSpace.sm : AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(isExpanded ? AppColor.accent : AppColor.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ChineseUI.settingTitle(key))，当前 \(displayValue(for: key))")
    }

    private func widestValueLabel(for key: SettingKey) -> String {
        let longest = SettingCatalog.options(for: key)
            .map { ChineseUI.settingValue(for: key, rawValue: $0.rawValue) }
            .max(by: { $0.count < $1.count }) ?? ""
        return longest.isEmpty ? "—" : longest
    }

    private func displayValue(for key: SettingKey) -> String {
        guard let raw = session.settingValues[key] else { return "—" }
        return ChineseUI.settingValue(for: key, rawValue: raw)
    }

    private var autoRestartChip: some View {
        let isOn = session.autoRestartRecording
        return Button {
            session.autoRestartRecording.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("自动续录")
                    .font(.system(size: AppFont.caption))
                    .foregroundStyle(isOn ? AppColor.accent : AppColor.text3)
                Text(isOn ? "开" : "关")
                    .font(.system(size: AppFont.value, weight: .medium))
                    .foregroundStyle(isOn ? AppColor.accent : AppColor.text)
            }
            .padding(.horizontal, AppLayout.isFourInchPhone ? AppSpace.sm : AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(isOn ? AppColor.accent : AppColor.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自动续录，\(isOn ? "开" : "关")")
    }
}

private struct ValueQuickPicker<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    let key: SettingKey
    let title: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Text(title)
                .font(.system(size: AppFont.caption))
                .foregroundStyle(AppColor.text3)
                .padding(.leading, AppSpace.xl)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppLayout.isFourInchPhone ? 4 : 6) {
                        ForEach(SettingCatalog.options(for: key)) { option in
                            valuePill(option)
                        }
                    }
                    .padding(.trailing, AppSpace.xl)
                }
                .onAppear {
                    guard let current = session.settingValues[key] else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
        .padding(.top, AppSpace.sm)
        .transition(.opacity)
    }

    private func valuePill(_ option: SettingOption) -> some View {
        let selected = session.settingValues[key] == option.rawValue
        let label = ChineseUI.settingValue(for: key, rawValue: option.rawValue)
        return Button {
            session.setSetting(key, value: option.rawValue)
            dismiss()
        } label: {
            Text(label)
                .font(.system(size: AppFont.small, weight: .medium))
                .foregroundStyle(selected ? AppColor.accent : AppColor.text2)
                .padding(.horizontal, AppLayout.isFourInchPhone ? AppSpace.sm : AppSpace.md)
                .padding(.vertical, AppLayout.isFourInchPhone ? 4 : 5)
                .background(selected ? AppColor.accent.opacity(0.12) : .clear)
                .overlay(Capsule().stroke(selected ? AppColor.accent : AppColor.hairline, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(option.rawValue)
    }
}

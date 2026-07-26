// Mode-aware settings: a horizontal strip of compact chips (label + current value). Reworked
// 2026-07-12 per user feedback ("2 taps, not 4"): tapping a chip no longer opens the old
// multi-level sheet - it expands an inline horizontal VALUE PICKER row right above the strip
// (current value highlighted and auto-scrolled into view); tapping a value applies it and
// collapses the row. Tapping the same chip again just collapses. The old
// SettingsSheet/ValuePickerView (sheet -> list -> picker, up to 4 taps) is gone.
//
// The auto-restart toggle also moved out of the buried sheet into a first-class strip chip
// (video mode): visible on the main screen, one tap to toggle, amber when on.
import SwiftUI
import YiM1Core

/// Chip captions. Deliberately the words a photographer already uses - ISO, Aperture, Shutter,
/// EV and WB are left exactly as they are, because renaming standard terms only makes them
/// harder to find. What was renamed (2026-07-24) is the engineering-flavoured leftovers:
/// "Mode" was too vague, "Quality" actually meant megapixels, "Drive" was an abbreviation, and
/// "Format" was used for BOTH the photo file type and the video resolution.
private let chipTitles: [SettingKey: String] = [
    .exposureMode: "Exposure", .meteringMode: "Metering", .focusMode: "Focus",
    .imageQuality: "Resolution", .imageAspect: "Aspect", .fileFormat: "File type",
    .driveMode: "Drive mode",
    .fNumber: "Aperture", .shutterSpeed: "Shutter", .ev: "EV", .iso: "ISO",
    .whiteBalance: "WB", .colorMode: "Color",
    .videoFormat: "Resolution", .videoEis: "Stabilisation", .audioSwitch: "Audio",
    .audioNoiseReduce: "Mic denoise", .audioVolume: "Mic level",
]

struct SettingsStrip<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session
    @State private var expandedKey: SettingKey?

    private var keys: [SettingKey] { SettingCatalog.keys(forMode: session.mode) }

    var body: some View {
        VStack(spacing: 0) {
            if let key = expandedKey {
                ValueQuickPicker(session: session, key: key, title: chipTitles[key] ?? key.rawValue) {
                    withAnimation(.easeInOut(duration: 0.15)) { expandedKey = nil }
                }
                // Fresh view identity per key: switching straight from one expanded chip to
                // another (without collapsing in between) would otherwise REUSE this view -
                // onAppear wouldn't re-fire and the row would keep the previous setting's
                // scroll position instead of centering the new one's current value.
                .id(key)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpace.sm) {
                    ForEach(keys, id: \.self) { key in
                        chip(for: key)
                    }
                    if session.mode == .video {
                        // There are no read-only video chips left. Format, stabilisation, audio,
                        // mic noise reduction and mic level were ALL filed as "dead commands - 404
                        // despite valid firmware handlers" until 2026-07-24, when it turned out
                        // every one of them was just being sent the wrong parameter name. They are
                        // ordinary settable chips now, built by `chip(for:)` above from
                        // SettingCatalog.videoOnlyKeys.
                        autoRestartChip
                    }
                }
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.sm)
            }
        }
        // Mode switches change the key set - an expanded picker for a key that no longer
        // exists (photo-only setting after switching to video) must not linger.
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
                Text(chipTitles[key] ?? key.rawValue)
                    .font(.system(size: AppFont.caption))
                    .foregroundStyle(isExpanded ? AppColor.accent : AppColor.text3)
                // Sized to the WIDEST value this setting can ever show, so the chip keeps a
                // constant width (2026-07-26). Without this the chip resized as its value
                // changed - EV was the obvious case ("0.0" vs "-5.0") - and every resize
                // shifted the whole strip sideways under the user's finger. The hidden Text
                // is the spacer; ZStack takes the larger of the two.
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
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(AppColor.surface)
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm)
                .stroke(isExpanded ? AppColor.accent : AppColor.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        }
        .buttonStyle(.plain)
    }

    /// Longest label this setting can display - used as an invisible width spacer so the chip
    /// never resizes. Character count is a good enough proxy for width here: the values are
    /// short, same-font strings, and being a pixel or two generous costs nothing.
    private func widestValueLabel(for key: SettingKey) -> String {
        let longest = SettingCatalog.options(for: key)
            .map(\.displayLabel)
            .max(by: { $0.count < $1.count }) ?? ""
        // "—" is shown before the camera's values arrive; never size below that.
        return longest.count >= 1 ? longest : "—"
    }

    private func displayValue(for key: SettingKey) -> String {
        guard let raw = session.settingValues[key] else { return "—" }
        return PrettyLabel.prettyLabel(for: key, rawValue: raw)
    }

    /// Non-interactive variant of `chip` - not a Button, dimmer value text, small lock glyph
    /// next to the title, so it reads as "shown, not settable" rather than an unresponsive
    /// button.
    private func readOnlyChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: AppFont.caption))
                    .foregroundStyle(AppColor.text3)
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(AppColor.text3)
            }
            Text(value)
                .font(.system(size: AppFont.value, weight: .medium))
                .foregroundStyle(AppColor.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    /// One tap toggles - no expansion. Amber while on, so its state reads at a glance from the
    /// main screen (it used to be discoverable only inside the old settings sheet).
    private var autoRestartChip: some View {
        let isOn = session.autoRestartRecording
        return Button {
            session.autoRestartRecording.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-restart")
                    .font(.system(size: AppFont.caption))
                    .foregroundStyle(isOn ? AppColor.accent : AppColor.text3)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: AppFont.value, weight: .medium))
                    .foregroundStyle(isOn ? AppColor.accent : AppColor.text)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(AppColor.surface)
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm)
                .stroke(isOn ? AppColor.accent : AppColor.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        }
        .buttonStyle(.plain)
    }
}

/// The inline horizontal value row that expands above the strip: title on the left, scrollable
/// value pills, current value highlighted and auto-centered on appear. Tapping a value applies
/// it optimistically (same `setSetting` path as before) and collapses the row.
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
                    HStack(spacing: 6) {
                        ForEach(SettingCatalog.options(for: key)) { option in
                            valuePill(option)
                        }
                    }
                    .padding(.trailing, AppSpace.xl)
                }
                .onAppear {
                    // Deferred one runloop: scrollTo straight from onAppear races the row's
                    // own layout on long option lists (WB temperatures, shutter speeds) and
                    // lands at the start instead of on the current value.
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
        return Button {
            session.setSetting(key, value: option.rawValue)
            dismiss()
        } label: {
            Text(option.displayLabel)
                .font(.system(size: AppFont.small, weight: .medium))
                .foregroundStyle(selected ? AppColor.accent : AppColor.text2)
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, 5)
                .background(selected ? AppColor.accent.opacity(0.12) : .clear)
                .overlay(Capsule().stroke(selected ? AppColor.accent : AppColor.hairline, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(option.rawValue)
    }
}

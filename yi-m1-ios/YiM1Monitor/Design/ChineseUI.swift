import Foundation
import YiM1Core

/// Chinese display strings for camera settings. The raw values sent to the camera are never
/// changed here; this is presentation-only so protocol behaviour and YiM1Core tests stay intact.
enum ChineseUI {
    static func settingTitle(_ key: SettingKey) -> String {
        switch key {
        case .exposureMode: return "曝光模式"
        case .meteringMode: return "测光"
        case .focusMode: return "对焦"
        case .imageQuality: return "分辨率"
        case .imageAspect: return "画幅比例"
        case .fileFormat: return "文件格式"
        case .driveMode: return "驱动模式"
        case .fNumber: return "光圈"
        case .shutterSpeed: return "快门"
        case .ev: return "EV"
        case .iso: return "ISO"
        case .whiteBalance: return "白平衡"
        case .colorMode: return "色彩"
        case .videoFormat: return "视频规格"
        case .videoEis: return "防抖"
        case .audioSwitch: return "录音"
        case .audioNoiseReduce: return "麦克风降噪"
        case .audioVolume: return "麦克风音量"
        }
    }

    static func settingValue(for key: SettingKey, rawValue: String) -> String {
        switch key {
        case .exposureMode:
            return [
                "Auto": "自动", "P": "程序 P", "A": "光圈优先 A", "S": "快门优先 S",
                "M": "手动 M", "Scene": "场景"
            ][rawValue] ?? rawValue

        case .meteringMode:
            return ["Multi": "多区", "Spot": "点测光", "CenterWeighted": "中央重点"][rawValue] ?? rawValue

        case .focusMode:
            return ["C-AF": "连续 AF", "S-AF": "单次 AF", "MF": "手动 MF"][rawValue] ?? rawValue

        case .imageQuality:
            return rawValue == "VGA" ? "VGA" : (isAllDigits(rawValue) ? "\(rawValue) MP" : rawValue)

        case .imageAspect:
            return rawValue

        case .fileFormat:
            return [
                "RAW": "RAW", "JPG-S": "JPEG 小", "JPG-M": "JPEG 中", "JPG-L": "JPEG 大",
                "RAWJ-S": "RAW+JPEG 小", "RAWJ-M": "RAW+JPEG 中", "RAWJ-L": "RAW+JPEG 大"
            ][rawValue] ?? rawValue

        case .driveMode:
            return [
                "Single": "单张", "Continuous": "连拍", "2SDelay": "2 秒自拍", "10SDelay": "10 秒自拍"
            ][rawValue] ?? rawValue

        case .fNumber:
            return "f/" + rawValue

        case .shutterSpeed:
            if rawValue == "TIME" { return "T 门" }
            if rawValue == "BULB" { return "B 门" }
            return rawValue

        case .ev:
            return (rawValue.hasPrefix("-") || rawValue.hasPrefix("0")) ? rawValue : "+" + rawValue

        case .iso:
            return rawValue == "Auto" ? "自动" : rawValue

        case .whiteBalance:
            if isAllDigits(rawValue) { return rawValue + "K" }
            return [
                "Auto": "自动", "Sunny": "晴天", "Cloudy": "阴天", "Shadow": "阴影",
                "Incandescent": "白炽灯"
            ][rawValue] ?? rawValue

        case .colorMode:
            return [
                "Standard": "标准", "Portrait": "人像", "Vivid": "鲜艳",
                "NaturalBW": "黑白柔和", "HContrastBW": "黑白高反差"
            ][rawValue] ?? rawValue

        case .videoFormat:
            return [
                "4K_30": "4K 30p", "2K_30": "2K 30p", "FHD_60": "1080 60p",
                "FHD_30": "1080 30p", "FHD_24": "1080 24p ★", "720P_60": "720 60p",
                "720P_30": "720 30p", "720P_24": "720 24p", "VGA_240": "240fps 慢动作 ★"
            ][rawValue] ?? rawValue

        case .videoEis, .audioSwitch, .audioNoiseReduce:
            return rawValue == "ON" ? "开" : (rawValue == "OFF" ? "关" : rawValue)

        case .audioVolume:
            return rawValue == "10" ? "10%（较低）" : rawValue + "%"
        }
    }

    private static func isAllDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}

# YI M1 固件 / iOS App 研究记录（2026-09-06）

> 本文记录 2026-09-05～09-06 ChatGPT 会话中形成的研究方向、已确认事实和待验证假设。
> 
> **重要：** 本文把“仓库已有实机/固件研究已确认的事实”和“本次会话中的新假设/待复核发现”明确分开。没有重新做完整 Ghidra / 二进制调用链复核的内容，不应直接当作可刷写或可安全调用的结论。

## 1. 项目定位

当前目标不再只是把 YI M1 的原机按钮搬到 iPhone，而是把 iPhone App 作为 **M1 的外挂升级模块**，优先补原机短板：

- 原机缺乏可信的实时曝光预览。
- 原机白平衡 / 色偏控制能力有限，用户体验不稳定。
- 原机照片回放和浏览较慢。
- 原机参数调整步骤多、效率低。
- 利用 App 增加峰值、斑马纹、伪色、直方图、包围曝光、预设等原机没有或不好用的功能。

主要目标设备：**iPhone SE 第一代（320×568 pt，A9）**。功能设计必须优先考虑小屏幕、功耗和实时性能。

## 2. 已由仓库研究确认的事实

以下内容在仓库既有研究中已有实机或固件证据。

### 2.1 Live View 与曝光并不总一致

`fable research/live-testing-findings.md` 已记录：

- 在录像开始前，Live View 的亮度可能仍像自动曝光预览，即使用户已经手动设置了较低 ISO / 不同曝光参数。
- 一旦开始真实录像，Live View 会切换到更接近最终记录结果的实际曝光与实际裁切。
- 因此录像前直接基于原始 Live View 做直方图 / 斑马，并不能保证反映最终曝光。

这意味着真正有用的曝光辅助需要：

1. 找到 M1 Preview AE 实际使用的曝光状态；或
2. 用外部测光源（例如 iPhone 摄像头）估算场景 EV，再对 M1 Live View 做软件曝光补偿。

### 2.2 Live View metadata 已知字段

`yi-m1-ios/YiM1Core/Sources/YiM1Core/CameraMetadata.swift` 和实机研究确认，UDP Live View 每帧前 2048 bytes JSON 头中至少存在：

- `ExposureMode`
- `MeteringMode`
- `ImageQuality`
- `ImageAspect`
- `DriveMode`
- `FileFormat`
- `Fnumber` / `FnumberMin` / `FnumberMax`
- `ShutterSpeed`
- `EV`
- `ISOSetting` / `ISOAutoValue`
- `WB`
- `ColorMode`
- `LensStatus`
- `BatteryLevel`
- `FocusMode` / `FocusSupport`
- `VideoFormat`
- `VASwitch` / `VAVol` / `VANR` / `VideoEis`
- `SurplusPhotoCnts`

目前 App 解析器仍保留 `raw` 字典，因此未来如发现更多字段，可以在不破坏兼容性的情况下继续提取。

### 2.3 2.4 GHz Live View 的主要瓶颈不是纯带宽

`fable research/optimization-2026-07-24.md` 的实测：

- Live View 流量约 1.7 MB/s（约 13.6 Mbit/s）。
- 2.4 GHz 的理论带宽足够，实际体验更容易受无线干扰、Bluetooth 共存、iOS Wi-Fi 行为和 UDP 丢包影响。
- 项目已经采用 keep-latest 设计：UI 跟不上时丢旧帧、保最新帧，避免延迟不断累积。

对 iPhone SE1 的策略仍应是：

- JPEG 解码保持后台化。
- 峰值 / 直方图 / 斑马纹等不必每帧全速计算。
- 需要时优先 10～15 Hz 的分析刷新率，而不是强制 30 Hz。

### 2.4 固件平台与隐藏能力

仓库已经确认 M1 是 Xacti ASDK 平台，主固件存在 `.text / .rodata / .data` 等区域，并且已有正确 Ghidra 加载方法。

已确认过的隐藏或额外能力包括：

- `VGA_240` 实机可用，约 240 fps 采集并封装成 30 fps，得到约 8× 慢动作。
- `720P_60 / 720P_30 / 720P_24` 可用。
- 部分更短快门值（如 `1/8000s`）被实机验证可接受。
- `MF-PEAK` 是真实内部 FocusMode 值，但通过现有 Wi-Fi 控制路径应用失败。

详见：

- `fable research/hidden-value-candidates.md`
- `fable research/live-testing-findings.md`
- `fable research/firmware-memory-map.md`

## 3. 本次会话提出的 App 补强路线

### 3.1 iPhone 作为独立测光表

使用 `AVCaptureDevice` 的曝光信息，让 iPhone 摄像头承担独立测光：

- 获取 iPhone 当前曝光时间、ISO、曝光状态。
- 估算场景 EV / EV100。
- 与 M1 当前 `ISO + shutter + aperture` 计算差值。
- UI 显示 `-3 … 0 … +3 EV` 测光标尺。
- 可选“应用推荐曝光”到 M1。

设计上建议 **按需启动 iPhone 摄像头**，测量 0.5～1 秒后锁定结果并关闭，避免 SE1 上长期同时运行：

- iPhone Camera ISP
- M1 Wi-Fi Live View
- JPEG Decode
- Focus Peaking
- Histogram / Zebra / False Color

导致过高功耗和发热。

### 3.2 iPhone 作为白平衡 / 灰卡分析器

两种模式：

**自动环境测量**

- 使用 iPhone AWB / temperature / tint 作为参考。
- 将最近支持的 Kelvin 值发送给 M1。

**灰卡模式**

- 用户把灰卡放入指定 ROI。
- App 分析灰卡区域 RGB 偏差。
- 输出建议 Kelvin + Green/Magenta Tint。
- 如果 M1 最终只能接受 Kelvin，则至少应用 Kelvin，并在 App 端对 Live View 继续做 Tint 监看校正。

### 3.3 软件曝光预览

如果只能拿到 M1 的“自动 Preview”画面，也可以做：

```text
M1 Live View
    +
外部测得的曝光差 ΔEV
    ↓
App 数字曝光校正
    ↓
模拟最终照片 / 视频亮度
```

然后再基于 **校正后的画面** 做：

- Histogram
- Zebra
- False Color
- Shadow / Highlight Warning

### 3.4 快速照片回放

App 端应优先使用较小预览 / thumbnail：

- 拍摄后尽快显示中等尺寸预览。
- 最近若干张预览常驻内存缓存。
- 左右滑动浏览。
- 需要放大时再请求较高分辨率内容。

目标是让 App 回放明显快于原机菜单体验。

### 3.5 SE1 参数 HUD

小屏幕上不应堆叠普通表单，而应做成相机 HUD：

```text
M     1/125     F2.8     ISO400     ±0.0
```

点击某一项后出现横向快速选择；尽量做到单手、一次点击进入参数调整。

## 4. 本次会话中的固件新方向（待完整复核）

以下是在本次会话中围绕 3.1-cn / 3.2-cn 固件形成的重点线索。**这些需要下一轮用完整二进制分析 / Ghidra 重新验证调用链。**

### 4.1 WB：疑似存在二维白平衡内部变量

本次会话中识别到以下名称：

- `wb_adjustment_2axis`
- `wb_adjustment_BA_step`
- `wb_adjustment_GM_step`
- `wb_kelvin`
- `adjgain_r / adjgain_g / adjgain_b`
- `ACQ_WB_R / ACQ_WB_G / ACQ_WB_B`
- `magenta_cacl_gain_r / magenta_cacl_gain_b`
- `g_wb_hosei_*`

如果这些字符串/结构确实属于正常 ISP WB 链，则说明 Xacti 内部可能支持：

- Blue ↔ Amber
- Green ↔ Magenta
- Kelvin

也就是比当前 Wi-Fi UI 暴露的白平衡能力更完整。

**尚未证明：**

- BA / GM 是否进入 M1 正常拍照 / 录像路径。
- 是否存在安全、稳定的 setter。
- 是否能通过 Wi-Fi / 服务接口访问。
- 是否仅服务于 `WB_RAWSIM` / 工厂开发模式。

### 4.2 AE：疑似存在实际采集曝光状态

本次会话重点关注：

- `shutter_acq`
- `sens_acq`
- `Fno`
- `Bv`
- `Tv`
- `Av`
- `Sv`
- `expTime`
- `sens`

目标是验证这些值是否能代表 Preview AE 当前实际使用的曝光，而不是单纯用户设置值。

如果成立，则可实现：

```text
Preview AE 实际曝光
        vs
用户要求的 M1 曝光
        ↓
ΔEV
        ↓
软件曝光预览
```

### 4.3 参数表 / RawSim 线索

本次会话中还识别到一个可能属于 ISP / WB RawSim 的参数注册机制，包含类似：

- `Fno`
- `sens_acq`
- `shutter_acq`
- `cam_exp_program`
- `cam_evmode`
- `cam_scene`
- `cam_wb`
- `wb_adjustment_BA_step`
- `wb_adjustment_GM_step`
- `wb_kelvin`
- HDR shutter / gain 参数

并出现 `WB_RAWSIM`、文本参数解析、`NOT FOUND` 等开发/测试痕迹。

**安全结论：** 在入口、参数范围、持久化行为、恢复机制没有完全确认之前，不应把猜测配置文件直接放入正常使用的相机。

## 5. 3.1-cn ↔ 3.2-cn 差分计划

本次用户提供两份国行固件，计划用于版本差分。

优先比较：

1. AE / Preview 相关函数。
2. WB / 2-axis adjustment 相关函数。
3. Live View metadata builder。
4. HTTP RC 路由与参数 setter。
5. 文件预览 / thumbnail 路径。

目的不是简单统计字节差异，而是借助小版本变化帮助识别未知函数用途。

## 6. 下一步优先级

### P0 — 曝光链

追踪并验证：

```text
shutter_acq
sens_acq
Fno
Bv / Tv / Av / Sv
```

问题：

- 谁写？
- 谁读？
- 更新频率？
- 单位？
- 是否为 Preview AE 实际值？
- 有没有只读导出接口？

### P1 — 白平衡链

追踪：

```text
wb_adjustment_BA_step
wb_adjustment_GM_step
wb_kelvin
```

问题：

- 是否进入正常 still / movie ISP？
- 参数范围与步进？
- 是否需要同时更新 R/B gain？
- 是否存在内部 setter / service API？

### P2 — iPhone 外部测光 / 灰卡

即使 P0/P1 最终无法通过 M1 API 暴露，仍可独立实现：

- iPhone EV meter
- Grey-card WB meter
- Kelvin recommendation
- Tint monitoring correction
- Software exposure preview

因此这条路线不会因固件接口失败而浪费。

## 7. 安全边界

当前阶段建议：

- 可以继续静态分析固件。
- 可以继续做 3.1 / 3.2 差分。
- 可以编写只读 probe / parser。
- 不建议直接刷修改固件。
- 不建议在主力机上随意启用 `IMAGER.SDK` 或未知工厂测试模式。
- 不应在未证明持久化行为之前修改 `.camadj / .camdef` 等校准区域。

---

后续如获得新的 Ghidra 地址、函数调用图、真实 metadata dump 或实机测试结果，应追加到本文或新建日期化研究记录，并把“已确认 / 待验证 / 已否定”分开维护。
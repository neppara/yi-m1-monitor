# ChatGPT 会话摘要（2026-09-05～09-06）

> 这是项目相关对话的**工作摘要**，不是逐字聊天记录，也不包含模型内部推理。
> 目的：把需求、决策、已做改动、后续方向留在仓库里，方便继续开发时快速恢复上下文。

## 1. iOS 15 兼容与构建

用户目标：让 `YiM1Monitor` 能在较老设备上运行，主要目标设备为 **iPhone SE 第一代**。

已完成：

- `project.yml` 最低系统改为 iOS 15。
- `YiM1Core/Package.swift` 最低系统同步改为 iOS 15。
- 将部分 iOS 16/17-only SwiftUI API 替换为 iOS 15 可用实现。
- GitHub Actions 已能成功构建并打包未签名 IPA。
- Workflow 增加 `swift test`，构建前自动跑 `YiM1Core` 测试。
- README 已更新 iOS 15 和未签名 IPA 说明。

## 2. GitHub 托管与直接修改

用户完成了 ChatGPT Codex Connector 的 GitHub App 安装与授权。

当前项目：

```text
neppara/yi-m1-monitor
```

之后 ChatGPT 已能够直接读取和修改 `main` 分支，而不再需要用户手动上传 Swift 文件覆盖。

## 3. 中文 UI + iPhone SE1 适配

用户明确要求：

- 用户界面改为中文。
- 文字与控件要适配 iPhone SE 第一代的小屏幕。

已做方向：

- 主要菜单、连接状态、拍照/录像、文件浏览、参数设置等中文化。
- 相机协议原始值继续保持原样，中文只用于显示层。
- 针对 SE1 压缩字体、间距、工具栏、快门按钮和布局。
- Wi-Fi / 文件浏览等页面优先避免固定大高度和不可滚动布局。

后续 UI 原则：

> 不是简单“把字体缩小”，而是把 SE1 当成专用相机外挂屏幕设计。

## 4. 产品方向：App 不只是遥控器

用户提出：既然已经有 App，就应该补强 YI M1 原机缺失或体验差的功能。

重点痛点：

- 原机没有可信曝光预览。
- 原机白平衡不准 / 调整能力有限。
- 原机预览照片慢。
- 参数调整麻烦。

双方形成共识：

> 项目应从 “YI M1 Remote Control” 逐渐变成 “YI M1 的软件外挂升级模块”。

优先功能方向：

- 曝光模拟预览
- Histogram
- Zebra
- False Color
- Focus Peaking
- 快速照片回放
- 参数 HUD
- 拍摄预设
- 包围曝光
- 隐藏模式 / 固件能力探索

## 5. 2.4 GHz Live View 讨论

用户关心 2.4 GHz 是否会让预览很卡。

结论：

- 现有研究表明纯带宽不是主要问题。
- 更主要的问题是 2.4 GHz 干扰、Bluetooth 共存、UDP 丢包和无线电短暂停顿。
- 项目已经使用 keep-latest 策略，旧帧来不及显示就丢弃，避免延迟不断累积。

因此后续新增图像分析功能时，应避免让 SE1 过载：

- 峰值 / Histogram / Zebra 不必 30 fps 全速计算。
- 10～15 Hz 往往已经足够做辅助分析。
- 图像校正应尽量使用 GPU / Core Image 管线。

## 6. iPhone 摄像头作为辅助传感器

用户提出：白平衡与曝光能否利用 iPhone 摄像头完成。

形成的设计方向：

### 6.1 iPhone 测光表

- iPhone 摄像头自己运行 AE。
- App 获取曝光时间、ISO 等状态。
- 估算场景 EV。
- 与 M1 当前 ISO / 快门 / 光圈比较。
- 输出曝光差值与建议参数。
- 可提供“一键应用曝光”。

### 6.2 iPhone 白平衡计

普通模式：

- 使用 iPhone AWB 的 temperature / tint 作为参考。

灰卡模式：

- 用户把灰卡放入指定区域。
- App 分析 RGB 偏差。
- 输出 Kelvin + Tint。
- Kelvin 可直接映射到 M1 已有的 WB 档位。
- 如果 M1 没有开放 Tint，则至少用于 App 端监看校正。

### 6.3 SE1 功耗策略

不建议长期同时运行：

- iPhone 后摄像头
- M1 Wi-Fi Live View
- JPEG decode
- peaking
- histogram / zebra / false color

更合适的方式：

> 用户按“测光” → iPhone 相机启动约 0.5～1 秒 → 取稳定结果 → 锁定 EV / WB → 关闭 iPhone 相机。

## 7. 固件研究讨论

用户提供了两份国行固件，分别用于 3.1-cn / 3.2-cn 研究。

会话中形成的主要研究方向：

### 曝光

重点追：

```text
shutter_acq
sens_acq
Fno
Bv
Tv
Av
Sv
expTime
sens
```

目标：判断是否能得到 Preview AE 的真实采集曝光，进而做可信的软件曝光预览。

### 白平衡

重点追：

```text
wb_adjustment_2axis
wb_adjustment_BA_step
wb_adjustment_GM_step
wb_kelvin
adjgain_r/g/b
ACQ_WB_R/G/B
```

目标：确认 M1 内部是否存在真正可用于正常拍照 / 录像的 Blue-Amber / Green-Magenta 二维白平衡微调，而不只是工程测试路径。

### 3.1 ↔ 3.2 差分

计划优先比较：

- AE / Preview
- WB / 2-axis adjustment
- Live View metadata builder
- HTTP RC routing / setter
- Preview / thumbnail

## 8. 对固件修改的安全态度

当前没有计划直接刷修改固件。

原则：

- 先做静态分析。
- 先找只读接口。
- 先找现成 setter / service path。
- 未确认前不启用未知工厂模式。
- 不随意修改 calibration 区域。

尤其 `IMAGER.SDK` 等工程模式，在弄清入口和持久化行为之前不应在正常使用的相机上试。

## 9. 后续建议路线

开发与研究可以并行：

```text
A. App 可直接做的功能
   ├─ SE1 参数 HUD
   ├─ 快速回放
   ├─ iPhone EV meter
   ├─ 灰卡 WB
   └─ 软件曝光补偿显示

B. 固件研究
   ├─ Preview AE 实际状态
   ├─ WB BA/GM
   ├─ 隐藏只读接口
   └─ 3.1 / 3.2 函数级差分
```

即使固件最终无法安全暴露 AE / Tint，A 路线仍然能独立成立，因此不会白做。

---

如需继续对话上下文，应先看：

- `fable research/chatgpt-firmware-notes-2026-09-06.md`
- `fable research/live-testing-findings.md`
- `fable research/optimization-2026-07-24.md`
- `fable research/hidden-value-candidates.md`
- `fable research/firmware-memory-map.md`

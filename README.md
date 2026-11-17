# AirLiveTranslate · 耳边译

项目仓库：[MinusJoe/AirLiveTranslate](https://github.com/MinusJoe/AirLiveTranslate)。Xcode 工程及 target 名保持 `AirPodsTranslator`。

原生 iPhone 实验版：双耳自戴，用蓝牙耳机远场采集周围讲话，识别、翻译后向指定耳侧播报。首批候选语言为中文、英语和日语，逐方向检测系统资源。没有云端模型密钥、第三方 SDK 或自建服务依赖。

**当前交付为源码与构建配置，不是已签名 IPA。Windows 环境没有执行 Swift 编译、XCTest 或 AirPods 真机测试。必须通过 Codemagic/macOS 构建和设备验收后，才能确认可安装及实际听译效果。**

用户目标设备：iPhone 17 / iOS 27.0.1 / AirPods Pro 3（实际固件版本待记录）。最低部署 iOS 26.0；编译 SDK 至少 iOS 26.2，耳机远场 API 在 iOS 26.2+ 才尝试使用。

## 实现范围

- SwiftUI 语言选择、双语字幕、状态与错误显示、开始/暂停/结束。
- Apple SpeechAnalyzer/SpeechTranscriber 设备端识别、Apple Translation 翻译、系统 TTS。
- 远场能力按 `isSupported` 和 `isEnabled` 检查；系统不支持时不会假装启用。
- 单耳播放通过独立 PCM 声道处理；实际输出路由不满足条件时阻止该模式。
- 暂停、结束、路由变化和中断使旧会话失效，防止迟到结果继续播报。
- 有界待播队列，防止长时间积压；不会自动摘要冒充完整翻译。
- 原始音频不写文件，字幕只保留内存中最近 200 条；暂停保留、结束清空。无历史记录数据库、分析埋点或网络后端。

这是一版**连续分段听译**，不是零延迟同声传译。较长未结束的话语可能等待最终识别结果。实际支持语言、下载资源、离线状态及延迟以设备为准。首次准备识别/翻译资源可能需要联网。

固定左/右麦克风须由用户在 iOS 的 AirPods 设置里操作；App 不声称能控制每个物理麦克风。固定侧与远场算法的组合没有真机证据。单耳不播放译文也不代表该耳被独立设成通透模式。

## Windows → Codemagic → iPhone

### 1. 使用独立仓库根目录

本仓库已按独立 App 布局组织，`codemagic.yaml` 位于仓库根目录。在 Codemagic 中连接 `MinusJoe/AirLiveTranslate` 并选择 `main` 分支即可读取配置。源码压缩包也按相同根目录结构打包。

提交源码不会自动触发本项目的 Codemagic 工作流。构建需要在 Codemagic 中手动启动；签名私钥只配置在平台的安全签名设置里。

### 2. 先运行无签名验证

在 Codemagic 连接该仓库，选择 `ios-verify`。此工作流不需要 Apple 签名材料，会：

1. 确定性生成 Xcode 工程。
2. 检查 iOS SDK 版本至少为 26.2。
3. 执行 Foundation 核心模块的 `swift test`。
4. 在 iOS 26+ iPhone 模拟器运行 hosted XCTest。
5. 编译真机架构的 Release 版本（不签名）。

工作流产物包括日志、`.xcresult` 和模拟器 `.app`。模拟器 `.app` **不能装到 iPhone，也不能验证耳机远场/声道或端侧模型效果**。默认 `xcode: latest`；首次绿灯后建议在 Codemagic 固定同一个可用 Xcode 版本。

### 3. 构建可直接装到你的 iPhone 的 IPA

使用 `ios-signed`，默认为 **Ad Hoc** 分发：

1. 在 Apple Developer 注册自己的明确 Bundle ID，例如 `com.yourcompany.eartranslate`。
2. 将你的 iPhone UDID 加入设备列表，并生成包含此设备的 Ad Hoc provisioning profile。
3. 在 Codemagic 安全的代码签名设置中上传匹配的 Apple Distribution 证书及私钥（`.p12`）和 provisioning profile。不要放入仓库或聊天。
4. 修改 `codemagic.yaml` 的 `ios_signing.bundle_identifier` 与 `BUNDLE_ID`，两处必须一致。
5. 手动启动 `ios-signed`。它先跑验证，再配置签名并导出 `.ipa`。
6. 使用 Codemagic 构建产物中的安装入口安装；只有 profile 包含的设备才能使用 Ad Hoc 安装。

**证书、有效开发者账户和注册设备不能由源码代替。** 这两个工作流都不自动上传 TestFlight、不发布 App Store、不发送邮件。

如要改为 TestFlight：使用匹配的 App Store profile，把 `distribution_type` 改成 `app_store`。这种 IPA 不能像 Ad Hoc 一样直接安装，需要通过 App Store Connect/TestFlight 分发。上传前还需提供商店隐私信息、截图、应用说明等；本项目没有开启自动发布。

参考：[Codemagic 原生 iOS](https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/)、[签名配置](https://docs.codemagic.io/yaml-code-signing/signing-ios/)。

## 本地 Mac 构建

Xcode 安装后，在本目录执行：

```sh
python3 scripts/generate_project.py
bash scripts/verify_macos.sh
open AirPodsTranslator.xcodeproj
```

真机运行时在 Xcode 的 Signing & Capabilities 选择自己的 Team 与 Bundle ID。也可以先生成定制工程：

```sh
python3 scripts/generate_project.py --bundle-id com.yourcompany.eartranslate --team ABCDE12345 --build-number 1
```

`generate_project.py` 会重写项目构建配置；在 Xcode 修改签名后不要无意用默认参数重新生成。Swift 源码不会被重写。

## 设备验收

先在前台准备语言资源、授权麦克风、确认当前路由，再测试双耳佩戴。根据界面提示确认收音和实际左右出声。请让交谈者知道正在进行语音翻译。

完整清单：[DEVICE_TEST_PLAN.md](docs/DEVICE_TEST_PLAN.md)。特别需要通过：

- 普通录音与远场录音是否确实切换；约 1 米/2 米、前方/侧方、安静/嘈杂环境。
- 同时录放时，仅指定耳侧发声，且不会把译文再次翻译。
- 系统单声道、耳机取下/断开、自动切换设备时明确停止，不外放译文。
- 暂停/结束后不再出现旧字幕或旧译音；切语言后没有前一会话结果。
- 锁屏、来电、Siri、资源下载失败，以及连续 60 分钟耗电/温度/延迟。

## 文件与验证

| 路径 | 用途 |
| --- | --- |
| `Sources/App` | UI 与会话控制 |
| `Sources/Audio` | 路由、收音、PCM 和播放 |
| `Sources/Speech` | 设备端流式识别 |
| `Sources/Core` | 纯 Swift 队列、去重与会话状态 |
| `Tests` | 核心回归测试 |
| `Resources` | 权限、隐私清单、图标 |
| `docs` | 需求、验收、独立审查与设备测试计划 |
| `scripts` | 工程生成、构建验证、源码打包 |

跨平台结构检查（**不代表编译成功**）：

```sh
python3 scripts/generate_project.py
python3 scripts/verify_project.py
python3 scripts/package_source.py
```

纯核心测试可在装有 Swift 6+ 的环境运行 `swift test`；它不编译 SwiftUI/音频/翻译部分。所有 iOS API 与签名必须通过 Xcode 检查。

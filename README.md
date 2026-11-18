# AirLiveTranslate · 耳边译

项目仓库：[MinusJoe/AirLiveTranslate](https://github.com/MinusJoe/AirLiveTranslate)。Xcode 工程及 target 名保持 `AirPodsTranslator`。

原生 iPhone 实验版：双耳自戴，用蓝牙耳机远场采集周围讲话，识别、翻译后向指定耳侧播报。首批候选语言为中文、英语和日语，逐方向检测系统资源。没有云端模型密钥、第三方 SDK 或自建服务依赖。

**当前版本已通过 GitHub Actions 验证：Linux/macOS 各 61 项核心测试、iOS 模拟器 67 项测试、真机架构 Release 无签名编译。** [验证记录](https://github.com/MinusJoe/AirLiveTranslate/actions/runs/44159071571) 对应代码提交 `6470cf06`。当前没有签名 IPA；实际界面交互、AirPods 播音、声学延迟及口音质量仍待实测。

用户目标设备：iPhone 17 / iOS 27.0.1 / AirPods Pro 3（实际固件版本待记录）。最低部署 iOS 26.0；编译 SDK 至少 iOS 26.2，耳机远场 API 在 iOS 26.2+ 才尝试使用。

## 实现范围

0.1.3 启动听译时，在权限、已安装的语言资源和耳机路由就绪后先开启麦克风。看到“已收音 · 识别预热中”即可讲话。模型就绪后从同一个内存队列顺序读取开头与随后说的话。暂存上限为 15 秒、16 MiB 和 4096 块，任一上限触发会明确停止。取消、结束或路由中断会清空暂存。首次下载语言资源期间麦克风保持关闭。

- 简洁首页突出大字实时字幕和开始/暂停；语言、耳机、字幕和听译选项位于独立设置页。首次开始时引导准备资源。
- 轻点有效译文重播：实时中先确认暂停，然后仅播放译文，不请求麦克风，也不自动恢复收音。
- 未播内容补听面板：按原顺序播放当前仍保留的未完整播出译文，使用每条原有目标语言；完整补听另行标记，保留首次播放历史。
- 关键信息高亮：提示常见数字、金额、日期和否定表达，支持在设置中关闭；只改变样式，不改写原文或TTS文本，不代表翻译正确。
- Apple SpeechAnalyzer/SpeechTranscriber 设备端识别、Apple Translation 翻译、系统 TTS。
- 远场能力按 `isSupported` 和 `isEnabled` 检查；系统不支持时不会假装启用。
- 单耳播放通过独立 PCM 声道处理；实际输出路由不满足条件时阻止该模式。
- 暂停、结束、路由变化和中断使旧会话失效，防止迟到结果继续播报。
- 稳定的完整短句在最终结果前提前提交；暂定内容与后续修订明确标注，修订会撤销旧待播并提供短提示。
- 翻译与播报由两个有界工作队列并行处理。自动播速有上限；积压的旧译音标记为仅字幕，并提供“跳到当前”。不把漏播或摘要当作完整翻译。
- 识别地区仅列出设备真正支持的选项；未实现自动语种识别，也没有虚假的术语/口音增强开关。
- 原始音频不写文件，字幕只保留内存中最近 200 条；暂停保留、结束清空。无历史记录数据库、分析埋点或网络后端。

这是一版**实验性增量听译**，不是零延迟同声传译。快速响应支持在长句中提前播出稳定分句。英语、中文和日语分别检查前半段能否独立表达意思、后半段是否已开始新分句，并核对真实音频时间边界。连续讲话时也可以触发。条件未说完、数字仍可能变化或缺少可靠边界时继续等待。设置中可关闭快速响应，以稳健模式进行对照。快速模型输出可能增加识别修订；口音效果和真实出声延迟必须实测。首次准备语言资源可能需要联网。

快语速/口音评估方法见 [PERFORMANCE_EVALUATION.md](docs/PERFORMANCE_EVALUATION.md)，`evaluation/` 包含24条原创人工录音脚本和空结果模板，没有虚构录音或成绩。

## GitHub 自动验证

`.github/workflows/ios-ci.yml` 在 `main`、`codex/**` 推送和 PR 时运行：Linux 执行纯 Swift 核心测试，macOS 执行核心与 iOS hosted 测试、真机架构无签名编译。测试结果以 [Actions](https://github.com/MinusJoe/AirLiveTranslate/actions) 的对应提交记录为准；工作流文件存在不等于运行已通过。签名 IPA 仍使用下方 Codemagic 流程。

固定左/右麦克风须由用户在 iOS 的 AirPods 设置里操作；App 不声称能控制每个物理麦克风。固定侧与远场算法的组合没有真机证据。单耳不播放译文也不代表该耳被独立设成通透模式。

## 重播与补听

1. 轻点已生成的译文。实时听译中会先询问是否暂停；点击正在重播的同一句可停止。
2. 有待补听内容时，首页显示轻量入口。打开面板后可单条播放或按顺序补听；仅打开/关闭面板不会误停仍在进行的实时听译。
3. 每批最多20条、总计12,000字符；单条最多1,800字符。长译文按字符安全边界分块完整播放，不受实时播报的过期规则影响。
4. 关闭面板、进入设置、改变播放设置或耳机路由失效会停止重播。完成后手动点击“继续听译”恢复收音。
5. 已修订的旧译文、空译文和超出单条上限的文本不允许重播。已完整补听的条目移出待补听清单；首次跳过/拥塞累计不会回减。

补听只使用当前内存中的字幕，不保存或回放原始录音。结束会话会清空字幕。高亮使用有限文本规则，可能遗漏或误匹配，不识别人名或验证事实。

## Windows → Codemagic → iPhone

已有自己的签名证书、只需要IPA时，在功能分支选择 `ios-unsigned-ipa`。它使用 iPhoneOS SDK 生成 arm64 Release archive，验证平台后打包 `Payload/*.app` 为 `AirLiveTranslate-unsigned.ipa`。这是真机应用包，需由你另行签名后安装；流程不会读取或上传你的证书。不要把 `ios-verify` 的模拟器 `.app.zip` 改后缀当作真机IPA。

### 1. 使用独立仓库根目录

本仓库已按独立 App 布局组织，`codemagic.yaml` 位于仓库根目录。在 Codemagic 中连接 `MinusJoe/AirLiveTranslate`。PR #1 尚未合并时，请选择 `codex/low-latency-ui` 分支测试本版本；合并后再选择 `main`。源码压缩包按相同根目录结构打包。

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

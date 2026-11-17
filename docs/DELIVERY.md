# 交付与验证状态

交付日期：2026-11-18（Asia/Tokyo）。总体状态：**Partially verified / 部分验证**。

## 本次交付

独立 iOS 源码工程在本地位于 `airpods-translator`，远程以 [AirLiveTranslate](https://github.com/MinusJoe/AirLiveTranslate) 仓库根目录布局交付。最低部署 iOS 26.0，使用至少 iOS 26.2 SDK 编译；iOS 26.2 远场能力均按运行时可用性检查。面向 iPhone 17 / iOS 27.0.1 与 AirPods Pro 3 的双耳自戴场景。

实现 Apple SpeechAnalyzer → TranslationSession → AVSpeechSynthesizer 的设备端链路。功能包含语言资源准备、音频能力检查、实际输入输出显示、麦克风电平、双语字幕、条件性单耳输出、暂停/恢复/结束、显式手机收音备用及错误反馈。

本版按最终识别片段翻译，不会把暂定文字直接播出；长句等待与多语言质量尚待测量。端到端效果、远场与独立单耳输出组合、译音回采、锁屏长时运行没有真机证明。

## 分工与复核

- 需求 agent：需求基线、可验收条件、能力与产品声明边界。
- 开发 agent：7 个 Swift 源文件、纯核心回归测试及修复。
- 核查 agent：公开 API 签名、需求合理性、生命周期/路由/音频处理核查、真机计划与独立报告。
- 主 agent：Xcode 工程、Codemagic、PCM 回归测试、构建脚本、源码打包与交付集成。

审查细节见 [REVIEW.md](REVIEW.md)；需求覆盖见 [ACCEPTANCE.md](ACCEPTANCE.md)。

## 已实际执行

| 检查 | 结果与范围 |
| --- | --- |
| Python 工程生成 | 通过；7 个 Swift 源码、2 个测试文件、49 个 Xcode 对象 |
| 确定性生成 | 通过；重复生成的 `project.pbxproj` SHA256 一致 |
| 工程结构检查 | 通过；源文件存在及入工程、对象引用、shared scheme 测试 target、部署版本 |
| 权限与隐私 plist | Python plist 解析通过；麦克风说明、后台 audio、无追踪声明存在 |
| Codemagic YAML | PyYAML 解析通过；两个工作流，无自动发布步骤 |
| Shell 语法 | Git Bash `-n scripts/verify_macos.sh` 退出 0；没有执行 macOS 构建 |
| Python 脚本语法 | `py_compile` 通过 |
| Swift 源码空白检查 | 通过；此项不是 Swift 语法或类型检查 |
| App 图标 | 1024×1024 无透明 PNG 已生成并目视检查 |

`Tests` 中提供 12 个 XCTest 测试：6 个纯核心测试、6 个 iOS PCM 测试。它们是待执行的测试源码，本机没有 Swift 编译器，不把测试数量当成通过数量。

## 尚未执行

- `swift test`，Swift 类型检查与链接。
- `xcodebuild test` 的模拟器 hosted XCTest。
- iPhone Release 编译、签名、安装。
- Codemagic 实际运行及构建日志核验。
- AirPods 远场、左右物理输出、译音回采、路由变化时的实际行为。
- 六个有向语言对、断网、锁屏、长时稳定性、耗电及真实出声延迟。

初次源码交付后，用户指定了 `MinusJoe/AirLiveTranslate` 作为远程交付仓库。源码上传与构建验证是不同步骤：目前没有连接 Codemagic 账户、没有访问签名私钥，也没有产出可安装 `.ipa`。源码压缩包不含父目录项目代码、私钥、模型资源或构建缓存。

## 下一道验证关卡

1. 在 Codemagic 连接 `MinusJoe/AirLiveTranslate` 仓库。
2. 先运行 `ios-verify`；查看真实编译及 XCTest 结果，有问题按日志修复。
3. 在平台配置匹配的 Apple Distribution 证书、Ad Hoc profile 与测试 iPhone UDID，并修改两处 Bundle ID。
4. 运行 `ios-signed` 导出 IPA，安装后按 [DEVICE_TEST_PLAN.md](DEVICE_TEST_PLAN.md) 验收。

只有第 2 步成功可称为“已通过构建”，第 4 步实际安装后可称“可安装”，设备计划中对应项目通过后才可声明“满足单耳远场听译”。

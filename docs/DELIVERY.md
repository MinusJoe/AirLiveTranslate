# 交付与验证状态

交付日期：2026-11-18（Asia/Tokyo）。总体状态：**Partially verified / 部分验证**。

## 本次交付

独立 iOS 源码工程在本地位于 `airpods-translator`，远程以 [AirLiveTranslate](https://github.com/MinusJoe/AirLiveTranslate) 仓库根目录布局交付。最低部署 iOS 26.0，使用至少 iOS 26.2 SDK 编译；iOS 26.2 远场能力均按运行时可用性检查。面向 iPhone 17 / iOS 27.0.1 与 AirPods Pro 3 的双耳自戴场景。

实现 Apple SpeechAnalyzer → TranslationSession → AVSpeechSynthesizer 的设备端链路。功能包含语言资源准备、音频能力检查、实际输入输出显示、麦克风电平、双语字幕、条件性单耳输出、暂停/恢复/结束、显式手机收音备用及错误反馈。

第二版将首页改为字幕与开始/暂停优先，设置独立成页。快速模式可提前翻译经过多次稳定确认、且有真实音频边界的完整短句；稳健模式等待最终片段。翻译与播报并行，有界积压保留字幕并标记未播，修订会撤销旧待播、必要时播放短提示。地区识别选项来自设备支持列表，不宣称口音准确率已有提升。端到端延迟、远场与独立单耳输出、译音回采及锁屏长时运行仍需真机验证。

## 分工与复核

- 需求 agent：需求基线、可验收条件、能力与产品声明边界。
- 开发 agent：流式分段、独立翻译/播报工作队列、地区识别及回归修复。
- 核查 agent：公开 API 签名、需求合理性、生命周期/路由/音频处理核查、真机计划与独立报告。
- 主 agent：原生首页/设置页、Xcode 工程、GitHub Actions/Codemagic、PCM 回归测试、源码打包与GitHub交付。

审查细节见 [REVIEW.md](REVIEW.md)；需求覆盖见 [ACCEPTANCE.md](ACCEPTANCE.md)。

## 已实际执行

| 检查 | 结果与范围 |
| --- | --- |
| Python 工程生成 | 通过；9 个 Swift 源码、4 个测试文件、57 个 Xcode 对象 |
| 确定性生成 | 通过；重复生成的 `project.pbxproj` SHA256 一致 |
| 工程结构检查 | 通过；源文件存在及入工程、对象引用、shared scheme 测试 target、部署版本 |
| 权限与隐私 plist | Python plist 解析通过；麦克风说明、后台 audio、无追踪声明存在 |
| Codemagic YAML | PyYAML 解析通过；两个工作流，无自动发布步骤 |
| Shell 语法 | Git Bash `-n scripts/verify_macos.sh` 退出 0；没有执行 macOS 构建 |
| Python 脚本语法 | `py_compile` 通过 |
| Swift 源码空白检查 | 通过；此项不是 Swift 语法或类型检查 |
| App 图标 | 1024×1024 无透明 PNG 已生成并目视检查 |

第二版已通过真实云端验证，测试代码包括 28 项纯核心队列/修订/地区匹配测试及 6 项 iOS PCM 测试。

- 首轮 [44147603126](https://github.com/MinusJoe/AirLiveTranslate/actions/runs/44147603126) 发现更正提示会被普通积压挤掉，保留失败断言并修复队列优先级。
- 修复后代码 `c3d8e6ef7b9b91879443a290780e3340a9c12105` 在 [44148400819](https://github.com/MinusJoe/AirLiveTranslate/actions/runs/44148400819) 通过：Linux 核心 28 项、macOS/Xcode 26.6 核心 28 项、iOS hosted XCTest 34 项零失败，以及 Release 真机架构无签名编译。
- 测试后的可选截图最初因模拟器已关闭而未取得；后续构建脚本显式启动模拟器、安装 app、启动后截图。截图只证明模拟器界面，不证明 AirPods 或语言模型效果。

## 尚未执行

- iPhone 签名、安装；Release 架构编译已通过。
- Codemagic 实际运行及构建日志核验。
- AirPods 远场、左右物理输出、译音回采、路由变化时的实际行为。
- 六个有向语言对、断网、锁屏、长时稳定性、耗电及真实出声延迟。

初次源码交付后，用户指定了 `MinusJoe/AirLiveTranslate` 作为远程交付仓库。源码上传与构建验证是不同步骤：目前没有连接 Codemagic 账户、没有访问签名私钥，也没有产出可安装 `.ipa`。源码压缩包不含父目录项目代码、私钥、模型资源或构建缓存。

## 下一道验证关卡

1. 先检查 [GitHub Actions](https://github.com/MinusJoe/AirLiveTranslate/actions) 对应提交的无签名验证，再在 Codemagic 连接仓库。
2. 先运行 `ios-verify`；查看真实编译及 XCTest 结果，有问题按日志修复。
3. 在平台配置匹配的 Apple Distribution 证书、Ad Hoc profile 与测试 iPhone UDID，并修改两处 Bundle ID。
4. 运行 `ios-signed` 导出 IPA，安装后按 [DEVICE_TEST_PLAN.md](DEVICE_TEST_PLAN.md) 验收。

只有第 2 步成功可称为“已通过构建”，第 4 步实际安装后可称“可安装”，设备计划中对应项目通过后才可声明“满足单耳远场听译”。

# 独立核查报告

日期：2026-11-18（Asia/Tokyo）。角色：需求/实现独立核查 agent。

> 第二版增量审查进行中：低延迟提交、识别地区变体、翻译/播报并行和简洁主页。下面第一版问题闭环保留作历史依据；第二版最终结论、CI 证据和新增问题将在交付前更新，不能把第一版静态结论直接用于新实现。

## 结论与证据等级

**Partially verified。** 需求已收敛为合理的实验 MVP；已逐文件审查原生源码、工程生成器、资源清单和 Codemagic 工作流，并对关键 Apple API 查阅官方文档。代码审查发现的问题已反馈开发并逐项复核。

当前不具备 Swift/Xcode/iPhone/AirPods 执行环境。**没有 Swift 编译、XCTest 执行、Codemagic 运行、签名 IPA 安装或真实耳机效果的通过证据。** 本报告不能用于宣称 App 已编译、已安装、已实现物理单耳隔离或达到同传延迟。

最终源码复核已完成，下表的代码问题已关闭；本轮未发现仍需阻断源码交付的已确认缺陷。硬件可行性与 Apple 编译仍是发布前门槛，不能因审查完成而略过。

## 需求合理性

- 用户目标明确：两只耳机都由用户佩戴，采集周围单人讲话，并希望向指定耳侧播放译文。
- 首版采用设备端语音识别、文本翻译、语音合成，避免为可行性原型加入账号、云端密钥和付费系统。
- iOS 26.0 可运行 App，26.2+ 才尝试远场 API；运行时能力判断优先于设备名称或版本推断。
- 固定物理麦克风、远场能力、指定耳侧输出是三个不同条件。现有公开 API 不能证明“左侧物理麦克风独占采集”。
- 单耳能力不足时禁止该模式，用户可以主动选择双耳或手机收音备用；不得静默降级。
- 仅最终识别片段进入翻译，适合作为“连续分段听译”原型。长句可能等待；零延迟、多说话人分离和成熟同传体验不在当前交付保证内。
- 锁屏持续性、离线全链路、六个语言方向质量与能耗需要真机验收，不能由配置项或代码检查推导通过。

## 审查发现与修复闭环

| ID | 严重性 / 置信度 | 证据与问题 | 修复及状态 |
|---|---|---|---|
| R-01 | Medium / High | `PCMConverter` 最初没有以 endOfStream 排空重采样器尾部，逐句销毁可能丢失末尾音频。 | 已增加有界 `finish()`，TTS 和自然识别流结束都送出尾部；代码复核完成，PCM 回归测试待运行。 |
| R-02 | High / High | 旧 `speak` 的 catch 无条件 `stopSpeech()`，取消后迟到的错误可能停止新会话播放。 | 已用 `playbackGeneration == token` 保护旧错误；旧路由通知同样绑定 `routeGeneration`。代码复核完成，竞态真机测试待执行。 |
| R-03 | High / High | 先开启录音再等待识别模型预热，64 个音频块可能在冷启动阶段被撑满。 | 改为延迟采集闭包：模型 prepare/start 完成后才安装 tap 并启动音频。代码复核完成。 |
| R-04 | Medium / High | 每个 TTS 块等完全播放后才排下一块，块间可能出现主线程调度造成的断续。 | 改为最多 4 块预排队并等待完成通知，限制内存同时保持连续性；代码复核完成，实际听感待测试。 |
| R-05 | Medium / High | 仅设置播放器 pan 不能作为物理耳侧隔离的充分证据。 | 使用实际双声道/左右标签及系统单声道状态校验，再明确将非目标 PCM 声道清零；已加入左右隔离和 mono→stereo 回归测试。物理输出仍待测。 |
| R-06 | Medium / High | UI 曾直接表示锁屏后会继续运行；停止后设备状态可能误当当前已启用。 | 锁屏改为待真机验证；非运行快照标为上次检查，支持/尚未检测区分。最终代码复核完成。 |
| R-07 | High / High | configure 与模型预热之间路由可变化，而开始录音时最初仅检查输出，可能先从错误输入录音。 | 在安装 tap 前与 engine.start 后均调用完整 validateRoute，检查输入/输出 UID、单耳能力和远场启用。代码复核完成。 |
| R-08 | High / High | `SpeechRecognizer.start` 的 await stop 后及 await 音频格式查询后存在未检查取消即覆盖共享 generation/analyzer 的窗口。 | 在异步边界后检查取消与代次；configure/start/speak 入口补取消检查，迟到任务不能先破坏新会话。最终代码复核完成。 |
| R-09 | Low / High | 最初 UI 没有需求中要求的实时电平，只显示静态麦克风图标。 | 已加入约 10 Hz RMS 电平并绑定会话代次，停止归零；代码复核完成。 |

以上问题的证据为代码与 API 语义；不是在设备上重现后的故障报告。修复完成不等于所有运行路径已验证。

## 关键实现检查

| 领域 | 静态结论 | 实际验证要求 |
|---|---|---|
| API 可用性 | farFieldInput/farFieldCapture 置于 26.2 availability guard；SpeechAnalyzer/Translation 的基本 API 为 26.0 可用。 | Xcode 使用至少 26.2 SDK 编译；26.0/26.1 测降级提示。 |
| 远场状态 | 查询支持与启用，不能仅以 setCategory 成功判定；输入/输出必须是符合条件的实际路由。 | AirPods 固件/设备实测 capability 与效果。 |
| 本地识别 | SpeechTranscriber + SpeechAnalyzer，临时结果仅用于字幕，最终结果按音频时间范围去重。 | 模型安装、长句、连续讲话、重复相同句子与取消。 |
| 翻译资源 | UI translationTask 仅用于准备/下载；持续翻译使用已安装资源的独立 TranslationSession。 | 模型卸载、下载拒绝、离线与六向语言。 |
| 顺序与积压 | 有界音频流、片段队列和 TTS 排队；超限显式失败，字幕保留未播完标识。 | 快速连续讲话下实际内存与滞后增长。 |
| 停止与恢复 | 会话代次阻止迟到字幕与翻译；取消任务并调用 TranslationSession.cancel，停止合成/播放/录音，旧识别清理后再启动。 | 快速重复开始/停止、权限弹窗和下载中取消。 |
| 单耳输出 | 只有独立左右通道且系统单声道关闭才允许，PCM 非目标声道清零。 | 双耳分别试听，空间音频/左右平衡、同时收音模式变化。 |
| 隐私 | 源码没有录音文件、字幕数据库、自建网络客户端或密钥；字幕限最近 200 条内存，暂停保留、结束清空。 | 设备离线全链路、日志和进程退出检查。Apple 系统服务遥测不等于 App 自建上传。 |
| 构建分发 | 确定性生成 Xcode 工程；核心 SwiftPM 与 iOS hosted XCTest；无签名验证后才签名导出。 | Codemagic 首次绿灯、有效证书/profile/UDID、实际安装。 |

## 测试设计审查

`Tests/SessionCoreTests.swift` 覆盖代次失效、音频范围去重但保留同文不同次讲话、积压拒绝、过期内容、未知/单声道输出和片段字符上限。

`Tests/PCMUtilitiesTests.swift` 使用真实 AVAudioPCMBuffer，覆盖左右清零、双耳保持、单声道拒绝、tap 缓冲区复制独立性、重采样总帧数与尾部结束、mono TTS 上混后目标耳仍有信号。这些测试仅在 iOS hosted 测试目标编译和执行；SwiftPM 核心测试不覆盖 AVFAudio。

尚无自动化模型替身覆盖 ViewModel 与 AudioController 的完整并发状态机；本轮采用针对性代码检查和 `DEVICE_TEST_PLAN.md` 的 LIFE/ROUTE 用例补充。不能将核心 epoch 单测等同于所有取消竞态已经通过。

## 本地执行证据

独立核查 agent 最终执行 `python airpods-translator/scripts/verify_project.py`，退出码 0，结果：7 个 Swift 源文件、2 个测试文件、49 个 Xcode 对象的结构检查通过。这个脚本检查文件引用、scheme、权限、隐私清单及部署配置；不解析 Swift 类型、不执行 XCTest，也不验证蓝牙能力。

协调 agent 另行检查了确定性生成、Python 语法、YAML 解析与 shell 语法；对应状态应以交付说明/实际日志为准。核心和 iOS 回归共 12 个测试声明，当前均未在 Apple 环境执行。

## 发布前必须完成

1. 运行 Codemagic `ios-verify`，保存 Swift 测试、iOS XCTest、无签名 Release 编译日志。
2. 修复实际编译/测试错误后重跑相关检查；不可仅以结构验证脚本通过替代。
3. 配置合法签名，生成并安装 Ad Hoc IPA，或走 TestFlight。
4. 执行 `DEVICE_TEST_PLAN.md` P0 项，尤其远场启用、录放同时的单耳输出、断连不外放、取消不续播、锁屏与串音。
5. 若实际 AirPods 录播路由只提供单声道，必须如实说明此硬件组合不能满足严格单耳目标；不能将双耳回退称为原需求已达成。

## 官方核查资料

- [远场选项](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/farfieldinput)
- [蓝牙麦克风扩展](https://developer.apple.com/documentation/avfaudio/avaudiosessionportdescription/bluetoothmicrophoneextension)
- [麦克风扩展能力类型](https://developer.apple.com/documentation/avfaudio/avaudiosessionportextensionbluetoothmicrophone)
- [音频通道映射](https://developer.apple.com/documentation/avfaudio/routing-audio-to-specific-devices-in-multidevice-sessions)
- [SpeechAnalyzer 生命周期](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber 结果](https://developer.apple.com/documentation/speech/speechtranscriber/result)
- [已安装语言的 TranslationSession](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:))
- [Codemagic iOS 签名](https://docs.codemagic.io/yaml-code-signing/signing-ios/)

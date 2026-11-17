# 独立核查报告

日期：2026-11-18（Asia/Tokyo）。角色：需求/实现独立核查 agent。

## 第二版增量审查

当前结论：**Partially verified：核心回归、iOS hosted XCTest 和无签名真机架构编译已通过；AirPods 真机与声学性能未验证。** 已审查低延迟提交、地区选择、并行翻译/播报、修订处理、简洁主页与设置页。独立核查新增 `Tests/StreamingAdversarialTests.swift`，包含 12 个非声学的合成识别事件/队列对抗用例。最终未发现阻断本轮源码交付的已确认缺陷。

### 真实 CI 证据

- 首轮候选 `f641eac`，GitHub Actions run `44147603126`：协调 agent 读取日志确认 Linux 与 macOS 的核心 Swift 代码真实编译成功；27 个核心测试中，更正提示拥塞测试失败。
- 失败位置是独立测试 `testCongestionCannotSilentlyEvictTheOnlyCorrectionNotice`：普通译音会挤掉唯一更正提示。该提交早于队列优先级修复。修复保留测试断言，优先保留/合并更正提示并剔除普通积压。
- 最终代码候选：`c3d8e6ef7b9b91879443a290780e3340a9c12105`，对应 [GitHub Actions run 44148400819](https://github.com/MinusJoe/AirLiveTranslate/actions/runs/44148400819)。以下结果由协调 agent 读取该次 CI 日志后交付核查记录。
- Linux：28 个核心测试全部通过，包括原失败的更正提示拥塞用例和新增活跃字幕保留用例。
- macOS / Xcode 26.6：28 个核心测试全部通过。
- iOS hosted XCTest：34 个测试、0 失败（28 核心 + 6 PCM），日志 `TEST SUCCEEDED`，记录时间 18:35:23 UTC。
- Release 真机架构无签名编译：`BUILD SUCCEEDED`，记录时间 18:35:55 UTC。
- 这次 CI 没有签名/安装 IPA，没有连接 AirPods，也没有用真人口音语料评测。模拟器测试与 iPhoneOS 编译不能证明耳机远场、单耳隔离、锁屏、声学延迟或口音准确率。

### 第二版发现与闭环

| ID | 问题 / 证据 | 处理与剩余验证 |
|---|---|---|
| V2-01 | `contextualStrings` 对 SpeechTranscriber 无实际提示作用，不能包装为术语或口音增强。[Apple 工程师答复](https://developer.apple.com/forums/thread/811083)与[官方模块文档](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)共同确认。 | 未集成无效开关；仅使用系统真实支持的地区模型和识别速度/精度策略。口音效果须人工语料实测。 |
| V2-02 | 系统可能返回带 script 的 locale，简单字符串匹配会误拒绝 zh-Hans-CN 等同地区模型。 | 按语言代码和地区匹配，传给引擎实际 supported Locale，界面展示实际 identifier；独立测试覆盖且禁止跨地区静默回退。 |
| V2-03 | 普通积压会静默淘汰更正提示，锁屏用户无法知道之前译音已失效。 | notice 置队首、合并为一条、不能被普通片段淘汰，也不被普通过期规则跳过；真实失败后，修复已由 Linux/macOS 核心与 iOS hosted 回归验证。 |
| V2-04 | 原方案对所有修订一律仅保字幕，即使旧片段从未排出音频，也不播放最终正确内容。 | 根据首个音频块是否排队作保守区分：未排音频时播最终正确句一次；可能已入耳时撤销旧音频、保留更正字幕并提示。软件排队不冒充实际声学播放证据。 |
| V2-05 | 超过 200 条字幕时可能滚掉仍在播放的长片段，之后跳到当前会丢失未播完标记和累计计数。 | `CaptionRetention.trim` 保护活动和两条队列中的字幕，优先滚动非活动记录，已增加回归测试。 |
| V2-06 | 早提交文字被引擎以空 volatile 撤回，或当前范围改变，不能当作普通空文本忽略。 | 核心显式返回撤销 ID；VM 撤销待译/待播，停止相关正在播放的片段；final 修订不重复播放旧前缀。 |
| V2-07 | 新 locale 代码使用 macOS 13+ Foundation API，SwiftPM 默认旧部署目标可能无法编译。 | Package 明确 macOS 13；真实 Linux/macOS 核心与 iOS 编译均已成功。 |
| V2-08 | 简洁主页若不显示 provisional/note，用户可能把提前播出的文字当最终结果；prepare→start 还需等待 idle，资源任务也不应绑在会随导航消失的首页。 | 主页条件显示提前译出与修订说明；自动启动同时检查资源就绪和状态；translationTask 放外层 NavigationStack，实际 locale 与快结果精度权衡放设置页。 |

### 第二版静态边界

- 提前提交是启发式：完整句末、至少 3 次稳定和 0.45 秒、可靠音频边界及后续音频。排除了小数与常见缩写，逗号不作为早提交边界。它不是语言学语义正确性证明，晚到否定仍可能推翻已播内容。
- 翻译和 TTS 分为独立有序任务；一个翻译请求按顺序完成并进入有限播报队列，播放器仍串行播报。系统过载时保字幕并明确标未播，识别/翻译本身过载则暂停。
- 会话 epoch、播放 epoch 和底层 audio generation 共同保护取消、跳到当前及修订后的迟到回调。尚无完整硬件状态机自动化，因此真机 LIFE/PIPE 用例仍是必要门槛。
- 识别地区不是任意口音修复；fastResults 本身以准确率换响应速度，稳健模式只保留 volatileResults 并等待最终提交。
- 首 buffer 排队、翻译耗时和等待队列耗时是软件指标，不能当作耳机实际声学延迟。没有证据证明达到 1.5–3 秒或改善了某种口音。

第二版对抗用例及真机要求见 `DEVICE_TEST_PLAN.md` 的 STREAM/PIPE/LOCALE/UI 表。下面是第一版归档，不代表第二版已完成相同运行验证。

第二版本地独立执行 `verify_project.py`：退出码 0，9 个 Swift 源文件、4 个测试文件、57 个 Xcode 对象的结构检查通过。此结果仍不替代 Apple 编译或真机验证。

## 第一版归档：结论与证据等级

**第一版当时的结论为 Partially verified。** 需求收敛为合理的实验 MVP；逐文件审查了原生源码、工程生成器、资源清单和 Codemagic 工作流，并对关键 Apple API 查阅官方文档。代码审查发现的问题已反馈开发并逐项复核。

第一版交付时没有 Swift/Xcode/iPhone/AirPods 执行环境，**当时没有 Swift 编译、XCTest 执行、Codemagic 运行、签名 IPA 安装或真实耳机效果的通过证据。** 第二版已补齐编译与自动化测试证据，见本报告开头；安装、物理单耳隔离与同传延迟依然不能据此宣称通过。

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

## 第一版列出的发布前门槛（历史记录）

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

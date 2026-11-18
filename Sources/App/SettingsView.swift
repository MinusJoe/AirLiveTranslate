import AVKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: TranslationViewModel
    @Binding var showOriginal: Bool
    @Binding var largeCaptions: Bool
    @Binding var highlightInformation: Bool

    var body: some View {
        Form {
            if !model.canConfigure {
                Text("听译进行中，暂停后可更改语言和耳机设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("语言") {
                Picker("对方的语言", selection: $model.source) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.disabled(!model.canConfigure)
                Picker("翻译成", selection: $model.target) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.disabled(!model.canConfigure)
                if model.availableVariants.isEmpty {
                    LabeledContent("识别地区", value: "设备未提供可用地区").foregroundStyle(.secondary)
                } else {
                    Picker("识别地区", selection: $model.sourceVariant) {
                        ForEach(model.availableVariants) { Text($0.name).tag($0) }
                    }.disabled(!model.canConfigure)
                }
                Button(model.resourcesReady ? "语言已准备 · 重新检查" : "准备离线语言") { model.requestPreparation() }
                    .disabled(!model.canConfigure || model.source == model.target)
                if model.source == model.target {
                    Text("请选择不同的原文和译文语言。").font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Picker("收音方式", selection: $model.captureSource) {
                    ForEach(CaptureSource.allCases) { Text($0.name).tag($0) }
                }.disabled(!model.canConfigure)
                Picker("译文播放", selection: $model.outputSide) {
                    Text("双耳").tag(OutputSide.both)
                    if model.snapshot.output.supportsSingleEar || model.outputSide == .left { Text("左耳").tag(OutputSide.left) }
                    if model.snapshot.output.supportsSingleEar || model.outputSide == .right { Text("右耳").tag(OutputSide.right) }
                }.disabled(!model.canConfigure)
                HStack {
                    Button("检查耳机") { model.checkAudio() }.disabled(!model.canConfigure)
                    Spacer()
                    AudioRoutePicker().frame(width: 38, height: 38).accessibilityLabel("选择系统音频输出")
                }
            } header: { Text("耳机") } footer: {
                Text("单耳选项按实际声道能力开放。固定收音侧请在系统 AirPods 设置中调整，远场模式下的物理麦克风分工仍需实测。")
            }
            Section {
                Toggle("快速响应", isOn: $model.lowLatencyEnabled).disabled(!model.canConfigure)
                Toggle("播报跟随语速", isOn: $model.adaptiveRateEnabled).disabled(!model.canConfigure)
            } header: { Text("听译") } footer: {
                Text("开启后，听到明确的下一分句时可先播前半句。语义尚未明确时会继续听。关闭后等识别定稿再播。")
            }
            Section("字幕与声音") {
                Toggle("显示原文", isOn: $showOriginal)
                Toggle("大字字幕", isOn: $largeCaptions)
                Toggle("高亮关键信息", isOn: $highlightInformation)
                HStack {
                    Text("播报速度")
                    Slider(value: $model.speakingRate, in: 0.35...0.6).accessibilityLabel("基础播报速度")
                }.disabled(!model.canConfigure)
            }
            Section {
                NavigationLink("会议纪要 · AI 模型") { MeetingModelSettings() }
                DisclosureGroup("设备与处理状态") {
                    LabeledContent("麦克风权限", value: model.microphonePermission)
                    LabeledContent("输入", value: model.snapshot.inputName)
                    LabeledContent("输出", value: model.snapshot.outputName)
                    LabeledContent("实际识别地区", value: model.actualLocaleIdentifier)
                    Text(model.microphoneActive ? "本次启动检测" : "上次检测结果，当前未收音")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.snapshot.detail).font(.caption).foregroundStyle(.secondary)
                    Text(model.message).font(.footnote)
                    if model.microphoneActive {
                        ProgressView(value: Double(model.inputLevel)) { Text("输入电平").font(.caption) }
                    }
                    LabeledContent("等待翻译", value: "\(model.pendingCount) 段")
                    LabeledContent("等待播报", value: "\(model.pendingSpeechCount) 段")
                    LabeledContent("实时跳过 / 拥塞未播累计", value: "\(model.skippedAudioCount) 段")
                    if let seconds = model.latestMetrics.recognitionLagSeconds {
                        Text("收音进度领先最近识别片尾：\(seconds, specifier: "%.2f") 秒").font(.caption)
                    }
                    if let seconds = model.latestMetrics.commitLagSeconds {
                        Text("最近分句从片尾到提交：约 \(seconds, specifier: "%.2f") 秒").font(.caption)
                    }
                    if let seconds = model.latestMetrics.translationSeconds {
                        Text("最近翻译执行：\(seconds, specifier: "%.2f") 秒").font(.caption)
                    }
                    if let seconds = model.latestMetrics.playbackQueueSeconds {
                        Text("最近播报排队：\(seconds, specifier: "%.2f") 秒").font(.caption)
                    }
                    if let seconds = model.latestMetrics.firstBufferScheduledSeconds {
                        Text("提交到首块音频排队：\(seconds, specifier: "%.2f") 秒").font(.caption)
                    }
                    Text("以上是软件处理耗时，不包含完整语义等待及耳机实际出声延迟。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                NavigationLink("使用说明") { usageHelp }
            }
            Section {
                Text("录音不落盘。暂停保留当前字幕，会议纪要可在结束时查看和导出。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: model.source) { await model.refreshVariants() }
    }

    private var usageHelp: some View {
        List {
            Section("自然讲话，持续听译") {
                Text("先准备常用语言并检查耳机。首页开始按钮会在首次使用时引导准备资源。请让周围参与者知晓正在收音。")
                Text("当前需要指定对方语言，尚未实现语音自动判语种。识别地区只列设备实际支持的选项，不代表所有口音都能准确识别。")
                Text("快速响应依赖稳定片段，仍可能出现修订。否定、数字及长句需要更多上下文，不能保证固定的反应时间。")
            }
            Section("声音与字幕") {
                Text("轻点已有译文可以重播。实时听译中会先询问暂停；重播完成不会自动恢复收音。未播内容可从首页的补听入口按顺序播放。")
                Text("高亮仅提示常见数字、金额、日期和否定表达，不会改写原文，也不保证译文正确。重播使用字幕生成时的目标语言，不保存原声。")
                Text("翻译与播报同时进行。译音跟不上时可能只保留字幕；未播完的内容会有标记。你也可以主动跳到当前讲话。")
                Text("暂停停止收音和播报；继续只处理新的讲话。耳机断连或系统音频中断后，需要手动恢复。")
                Text("单耳静音不等于单耳通透。远场效果、译音回采、口音准确率及锁屏连续性需要在你的设备上验证。")
            }
            Section("隐私与资源") {
                Text("首页保留最近 200 条字幕。会议纪要在内存中单独收录最多一万段定稿文字，可导出到你选择的位置。结束并查看的纪要在下次收音或退出 App 前可重新打开。Apple 智能在本机总结；选择自定义服务并确认后，定稿原文会发到所填地址。")
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .systemTeal
        view.activeTintColor = .systemTeal
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

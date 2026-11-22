import AVKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: TranslationViewModel
    @Binding var showOriginal: Bool
    @Binding var largeCaptions: Bool
    @Binding var highlightInformation: Bool

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(model.source.name) → \(model.target.name)").font(AudioTheme.headline)
            }
            .padding(.top, 10).listRowSeparator(.hidden).surfaceRow()
            if !model.canConfigure {
                Text("听译进行中，暂停后可更改语言和耳机设置。")
                    .font(.footnote).foregroundStyle(AudioTheme.secondary).surfaceRow()
            }
            Section {
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
                    Text("请选择不同的原文和译文语言。").font(.caption).foregroundStyle(AudioTheme.accent)
                }
            } header: { AudioSectionTitle("语言") }
            .surfaceRow()
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
            } header: { AudioSectionTitle("耳机") } footer: {
                Text("单耳选项按实际声道能力开放。固定收音侧请在系统 AirPods 设置中调整，远场模式下的物理麦克风分工仍需实测。")
            }
            .surfaceRow()
            Section {
                Toggle("快速响应", isOn: $model.lowLatencyEnabled).disabled(!model.canConfigure)
                Toggle("播报跟随语速", isOn: $model.adaptiveRateEnabled).disabled(!model.canConfigure)
            } header: { AudioSectionTitle("听译") } footer: {
                Text("开启后，听到明确的下一分句时可先播前半句。语义尚未明确时会继续听。关闭后等识别定稿再播。")
            }
            .surfaceRow()
            Section {
                Toggle("显示原文", isOn: $showOriginal)
                Toggle("大字字幕", isOn: $largeCaptions)
                Toggle("高亮关键信息", isOn: $highlightInformation)
                HStack {
                    Text("播报速度")
                    Slider(value: $model.speakingRate, in: 0.35...0.6).accessibilityLabel("基础播报速度")
                }.disabled(!model.canConfigure)
            } header: { AudioSectionTitle("字幕与声音") }
            .surfaceRow()
            Section {
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
            } header: { AudioSectionTitle("设备与使用说明") }
            .surfaceRow()
            Section {
                Text("录音不落盘。暂停保留当前字幕，会议纪要可在结束时查看和导出。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.surfaceRow()
        }
        .audioList()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: model.source) { await model.refreshVariants() }
    }

    private var usageHelp: some View {
        List {
            Section {
                Text("先准备常用语言并检查耳机。首页开始按钮会在首次使用时引导准备资源。请让周围参与者知晓正在收音。")
                Text("实时听译使用所选原文语言。面对面对话在中文和所选外语之间自动判断；登记我的声纹后，还可尝试跨语言识别佩戴者。")
                Text("快速响应依赖稳定片段，仍可能出现修订。否定、数字及长句需要更多上下文，不能保证固定的反应时间。")
            } header: { AudioSectionTitle("自然讲话，持续听译") }
            .surfaceRow()
            Section {
                Text("轻点已有译文可以重播。实时听译中会先询问暂停；重播完成不会自动恢复收音。未播内容可从首页的补听入口按顺序播放。")
                Text("高亮仅提示常见数字、金额、日期和否定表达，不会改写原文，也不保证译文正确。重播使用字幕生成时的目标语言，不保存原声。")
                Text("翻译与播报同时进行。译音跟不上时可能只保留字幕；未播完的内容会有标记。你也可以主动跳到当前讲话。")
                Text("暂停停止收音和播报；继续只处理新的讲话。耳机断连或系统音频中断后，需要手动恢复。")
                Text("单耳静音不等于单耳通透。远场效果、译音回采、口音准确率及锁屏连续性需要在你的设备上验证。")
            } header: { AudioSectionTitle("声音与字幕") }
            .surfaceRow()
            Section {
                Text("首页保留最近 200 条字幕，纪要最多收录一万段。首页「模型」可查看下载进度，分别配置会议总结、实时和面对面对话的文字服务。启用自定义服务后，相应文字会发到所填地址；音频和声纹留在本机。")
            } header: { AudioSectionTitle("隐私与资源") }
            .surfaceRow()
        }
        .audioList()
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(AudioTheme.accent)
        view.activeTintColor = UIColor(AudioTheme.accent)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

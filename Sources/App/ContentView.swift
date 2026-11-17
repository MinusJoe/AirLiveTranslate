import AVKit
import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var model = TranslationViewModel()
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard
                    settingsCard
                    controls
                    transcript
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("耳边译")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("佩戴与使用说明")
                }
            }
            .sheet(isPresented: $showHelp) { helpSheet }
            .translationTask(model.translationConfiguration) { session in
                await model.prepareResources(using: session)
            }
        }
        .tint(.teal)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.isRunning ? "waveform" : "earbuds")
                    .font(.title2)
                    .foregroundStyle(.teal)
                Text(model.state.rawValue).font(.headline)
                Spacer()
                Text("设备端处理").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if !model.phase.isEmpty {
                Text(model.phase).font(.caption).foregroundStyle(.secondary)
            }
            if model.pendingCount > 0 {
                Text("等待处理：\(model.pendingCount) 个片段").font(.caption).foregroundStyle(.orange)
            }
            if model.isRunning {
                Label("麦克风正在使用", systemImage: "mic.fill").font(.caption).foregroundStyle(.orange)
                ProgressView(value: Double(model.inputLevel))
                    .tint(.teal)
                    .accessibilityLabel("麦克风输入电平")
                    .accessibilityValue("\(Int(model.inputLevel * 100))%")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                languagePicker("对方说", selection: $model.source)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                languagePicker("我听", selection: $model.target)
            }
            .disabled(!model.canConfigure)

            Button(model.resourcesReady ? "语言已准备 · 重新检查" : "准备语言资源") { model.requestPreparation() }
                .buttonStyle(.bordered)
                .disabled(!model.canConfigure || model.source == model.target)

            Divider()
            Picker("收音", selection: $model.captureSource) {
                ForEach(CaptureSource.allCases) { Text($0.name).tag($0) }
            }
            .disabled(!model.canConfigure)
            HStack {
                Button("检查音频") { model.checkAudio() }
                    .buttonStyle(.bordered)
                    .disabled(!model.canConfigure)
                Spacer()
                Text("系统输出").font(.caption).foregroundStyle(.secondary)
                AudioRoutePicker().frame(width: 36, height: 36)
                    .accessibilityLabel("选择系统音频输出")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.isRunning ? "本次启动检查结果" : "上次检查结果（当前未收音）")
                    .fontWeight(.medium)
                Text("麦克风权限：\(model.microphonePermission)")
                Text("输入：\(model.snapshot.inputName)")
                Text("输出：\(model.snapshot.outputName)")
                if model.captureSource == .headset {
                    Text("远场：\(model.snapshot.hasBeenChecked ? (model.snapshot.farFieldSupported ? "支持" : "不支持") : "尚未检测") · 检查时启用：\(model.snapshot.farFieldEnabled ? "是" : "否")")
                }
                Text(model.snapshot.detail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("译文播放").font(.subheadline)
            HStack {
                ForEach(OutputSide.allCases) { side in
                    Button {
                        model.outputSide = side
                    } label: {
                        HStack(spacing: 4) {
                            if model.outputSide == side { Image(systemName: "checkmark") }
                            Text(side.name)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canConfigure || (side != .both && !model.snapshot.output.supportsSingleEar))
                    .accessibilityAddTraits(model.outputSide == side ? [.isSelected] : [])
                }
            }
            Text("单耳选项仅在实际路由提供独立左右声道时开放。固定收音侧请到 AirPods 系统设置操作；远场模式的物理麦克风分工无法保证。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("播报速度").font(.subheadline)
                Slider(value: $model.speakingRate, in: 0.35...0.6)
                    .accessibilityLabel("播报速度")
            }
            .disabled(!model.canConfigure)
            Toggle("周围参与者已知晓正在进行语音翻译", isOn: $model.awarenessConfirmed)
                .font(.caption)
                .disabled(!model.canConfigure)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func languagePicker(_ title: String, selection: Binding<AppLanguage>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
            }
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if model.isRunning || model.isBusy {
                Button { model.stop() } label: {
                    Label(model.isBusy ? "取消" : "暂停", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { model.start() } label: {
                    Label(model.state == .paused ? "恢复听译" : "开始听译", systemImage: "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.resourcesReady || !model.awarenessConfirmed || model.source == model.target)
            }
            Button("结束") { model.end() }.buttonStyle(.bordered)
                .disabled(model.state == .idle && model.captions.isEmpty)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("实时字幕").font(.headline)
                Spacer()
                Button("清空") { model.clearCaptions() }.font(.caption)
                    .disabled(!model.canConfigure || model.captions.isEmpty)
            }
            Text("仅保留内存中最近 200 条。未确定文字会更新，确定后才翻译播报。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.draft.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别中 · 尚未播报").font(.caption).foregroundStyle(.secondary)
                    Text(model.draft).foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
            if model.captions.isEmpty && model.draft.isEmpty {
                ContentUnavailableView("等待讲话", systemImage: "text.bubble",
                                       description: Text("开始后，对方的原文和译文会出现在这里。"))
            }
            ForEach(model.captions.reversed()) { caption in
                VStack(alignment: .leading, spacing: 8) {
                    Text(caption.translated.isEmpty ? "等待译文…" : caption.translated)
                        .font(.title3).fontWeight(.medium)
                    Text(caption.original).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Text(caption.status.rawValue)
                        Spacer()
                        if let seconds = caption.processingSeconds {
                            Text("文本处理 \(seconds, specifier: "%.1f") 秒")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var helpSheet: some View {
        NavigationStack {
            List {
                Section("双耳佩戴") {
                    Text("连接同一副 AirPods，双方知情后开始。先测试约 1 米处单人讲话，再测试远距离和噪声。")
                    Text("耳机远场收音需要 iOS 26.2+ 且耳机路由实际支持。iOS 26.0/26.1 可主动选择手机麦克风。")
                    Text("如需固定左或右麦克风，请打开系统设置 → AirPods → 麦克风。此 App 无法直接控制左右物理麦克风，也无法保证该设置在远场处理中如何生效。")
                }
                Section("播放与连续听译") {
                    Text("单耳播放依赖实际左右声道。关闭系统单声道音频后重新检查；无法确认时请主动选双耳。单耳不播放译文并不等于该耳自动处于通透模式。")
                    Text("本版本按系统确定的语义片段连续翻译。长句可能等待更久，并非零延迟同声传译。多人重叠讲话和译文串音需要真机评估。")
                    Text("暂停会丢弃尚未播完的音频，并把对应字幕标为未播完；结束会清空字幕。恢复只处理新的讲话。来电或耳机变化后需要手动恢复。")
                }
                Section("数据") {
                    Text("音频、识别、翻译与合成在设备端处理；本 App 不保存录音，不上传对话，不将字幕写入文件。语言模型首次下载需要联网。")
                    Text("字幕仅保留内存中最近 200 条。暂停会保留字幕；结束会话、清空或结束 App 进程后无法恢复。系统语言服务可能按 Apple 的政策收集使用与性能指标。")
                }
                Section("版本状态") {
                    Text("实验 MVP。设备能力检测不是远场效果或单耳物理听感的验收证明，请按项目验收清单测试。")
                }
            }
            .navigationTitle("使用说明")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showHelp = false } } }
        }
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

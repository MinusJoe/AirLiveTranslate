import SwiftUI
import Translation

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = TranslationViewModel()
    @State private var showSettings = false
    @State private var showOriginal = true
    @State private var largeCaptions = false
    @State private var askAwareness = false
    @State private var askSkip = false
    @State private var startAfterPreparation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if model.isBusy || model.state == .failed { statusNotice }
                transcript
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(model: model, showOriginal: $showOriginal, largeCaptions: $largeCaptions)
            }
            .confirmationDialog("开始前，请让周围参与者知晓正在进行语音翻译。", isPresented: $askAwareness, titleVisibility: .visible) {
                Button("已告知，开始听译") {
                    model.awarenessConfirmed = true
                    begin()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("在设备端处理，不保存录音；结束会话时清空字幕。")
            }
            .confirmationDialog("跳到当前讲话？", isPresented: $askSkip, titleVisibility: .visible) {
                Button("跳到当前") { model.skipToLive() }
                Button("继续按顺序听", role: .cancel) {}
            } message: {
                Text("停止当前及等待中的旧译音，相关字幕会标记未播完。")
            }
        }
        .tint(accent)
        .translationTask(model.translationConfiguration) { session in
            await model.prepareResources(using: session)
        }
        .task { await model.refreshVariants() }
        .onChange(of: model.resourcesReady) { _, ready in
            if ready { continueAfterPreparationIfReady() }
        }
        .onChange(of: model.state) { _, state in
            if state == .failed || state == .paused { startAfterPreparation = false }
            else if state == .idle { continueAfterPreparationIfReady() }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                Text("耳边译").font(.system(size: 27, weight: .semibold))
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("打开设置")
            }
            HStack(spacing: 8) {
                Text("\(model.source.name) → \(model.target.name)").foregroundStyle(accent)
                Spacer(minLength: 4)
                Label(model.isRunning ? model.outputSide.name : "开始时检查耳机", systemImage: "headphones")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Divider()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var statusNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.isBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if model.state == .failed {
                    Button("查看设置") { showSettings = true }.font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.captions.isEmpty && model.draft.isEmpty {
                        emptyState
                    } else {
                        Text("实时字幕").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.captions) { caption in
                            captionView(caption, latest: caption.id == model.captions.last?.id).id(caption.id)
                        }
                        if !model.draft.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("识别中 · 文字可能修订").font(.caption2).foregroundStyle(.secondary)
                                if showOriginal { Text(model.draft).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 27)
            }
            .onChange(of: model.captions.count) { _, _ in proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            .onChange(of: model.captions.last?.translated) { _, _ in proxy.scrollTo("transcript-bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(accent)
            Text(model.isRunning ? "正在听，请自然讲话" : "听懂，就从这里开始").font(.title3).fontWeight(.medium)
            Text(model.isRunning ? "原文与译文会显示在这里" : "戴好耳机，轻点开始")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    private func captionView(_ caption: Caption, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if latest || caption.status != .complete {
                Text(caption.status.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Text(caption.translated.isEmpty ? "正在组织译文…" : caption.translated)
                .font(.system(size: latest ? (largeCaptions ? 32 : 27) : (largeCaptions ? 23 : 19), weight: latest ? .medium : .regular))
                .foregroundStyle(latest ? Color.primary : Color.secondary)
                .lineSpacing(latest ? 6 : 4)
                .textSelection(.enabled)
            if showOriginal {
                Text(caption.original).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if caption.isProvisional {
                Text("提前译出 · 可能修订").font(.caption2).foregroundStyle(.orange)
            }
            if let note = caption.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if !latest { Divider().padding(.top, 14) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if model.pendingSpeechCount > 2 || model.skippedAudioCount > 0 {
                HStack {
                    Text(model.skippedAudioCount > 0 ? "\(model.skippedAudioCount) 段仅字幕 / 未播完" : "译音正在追赶")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isRunning { Button("跳到当前") { askSkip = true }.font(.caption) }
                }
            }
            HStack(spacing: 7) {
                Image(systemName: model.isRunning ? "waveform" : "pause.circle")
                    .foregroundStyle(model.isRunning ? accent : Color.secondary)
                Text(model.isRunning ? "正在听译" : model.state.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    if model.isRunning || model.isBusy {
                        startAfterPreparation = false
                        model.stop()
                    } else if !model.awarenessConfirmed {
                        askAwareness = true
                    } else { begin() }
                } label: {
                    Label(primaryTitle, systemImage: model.isRunning || model.isBusy ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(accent, in: RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                }
                .buttonStyle(.plain)
                if model.isRunning || model.isBusy || !model.captions.isEmpty {
                    Button {
                        startAfterPreparation = false
                        model.end()
                    } label: {
                        Text("结束").font(.subheadline)
                            .frame(width: 58, height: 60)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
    }

    private var primaryTitle: String {
        if model.isBusy { return "取消准备" }
        if model.isRunning { return "暂停听译" }
        return model.state == .paused ? "继续听译" : "开始听译"
    }

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.43, green: 0.84, blue: 0.81) : Color(red: 0.03, green: 0.50, blue: 0.51)
    }

    private func begin() {
        guard model.source != model.target else { showSettings = true; return }
        if model.resourcesReady { model.start() }
        else {
            startAfterPreparation = true
            model.requestPreparation()
        }
    }

    private func continueAfterPreparationIfReady() {
        guard startAfterPreparation, model.resourcesReady, model.state == .idle else { return }
        startAfterPreparation = false
        model.start()
    }
}

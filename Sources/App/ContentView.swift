import SwiftUI
import Translation

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = TranslationViewModel()
    @StateObject private var meetingPreferences = MeetingModelPreferences()
    @State private var showSettings = false
    @State private var showOriginal = true
    @State private var largeCaptions = false
    @State private var highlightInformation = true
    @State private var showCatchUp = false
    @State private var meetingSheet: MeetingMinutes?
    @State private var savedSummary: MeetingSummaryResult?
    @State private var askEnd = false
    @State private var askReplay = false
    @State private var pendingReplayID: UUID?
    @State private var askAwareness = false
    @State private var askSkip = false
    @State private var showConversation = false
    @State private var partnerToHear: AppLanguage?
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
                SettingsView(model: model, showOriginal: $showOriginal, largeCaptions: $largeCaptions,
                             highlightInformation: $highlightInformation)
            }
            .sheet(isPresented: $showCatchUp, onDismiss: { model.stopReplay() }) {
                CatchUpView(model: model, highlightInformation: highlightInformation,
                            requestReplay: { performReplay($0) })
            }
            .sheet(item: $meetingSheet) { meeting in
                MeetingMinutesView(minutes: meeting, listening: model.isRunning || model.isBusy, savedSummary: $savedSummary)
            }
            .sheet(isPresented: $showConversation, onDismiss: startPartnerTurn) {
                ConversationView(language: ConversationTurn.partnerLanguage(source: model.source, target: model.target),
                                 source: model.captureSource,
                                 chineseVariant: model.sourceVariant.language == .chinese ? model.sourceVariant : .chineseMainland,
                                 rate: Float(model.speakingRate)) { partnerToHear = $0 }
            }
            .confirmationDialog("结束这次听译？", isPresented: $askEnd, titleVisibility: .visible) {
                Button("结束并查看会议纪要") {
                    model.end(keepMinutes: true)
                    meetingSheet = model.readableMinutes
                }
                Button("结束并清空", role: .destructive) { savedSummary = nil; model.end() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("纪要收录已定稿内容。需要留存时，请在纪要页导出。")
            }
            .confirmationDialog("暂停实时听译并重播这句？", isPresented: $askReplay, titleVisibility: .visible) {
                Button("暂停并重播") { performReplay(pendingReplayID) }
                Button("取消", role: .cancel) { pendingReplayID = nil }
            } message: {
                Text("重播只播放已有译文，收音会暂停。结束后由你手动继续听译。")
            }
            .confirmationDialog("开始前，请让周围参与者知晓正在进行语音翻译。", isPresented: $askAwareness, titleVisibility: .visible) {
                Button("已告知，开始听译") {
                    model.awarenessConfirmed = true
                    begin()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("在设备端处理，录音不落盘。已定稿的文字可以导出为会议纪要。")
            }
            .confirmationDialog("跳到当前讲话？", isPresented: $askSkip, titleVisibility: .visible) {
                Button("跳到当前") { model.skipToLive() }
                Button("继续按顺序听", role: .cancel) {}
            } message: {
                Text("停止当前及等待中的旧译音，相关字幕会标记未播完。")
            }
        }
        .tint(accent)
        .environmentObject(meetingPreferences)
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
            if state == .buffering, savedSummary?.meetingID != model.readableMinutes.id { savedSummary = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                Text("耳边译").font(.system(size: 27, weight: .semibold))
                Spacer()
                Button { meetingSheet = model.readableMinutes } label: {
                    Image(systemName: "doc.text").frame(width: 44, height: 44)
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("会议纪要")
                Button { model.stopReplay(); showSettings = true } label: {
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
                Button("面对面对话") {
                    startAfterPreparation = false
                    if model.isRunning || model.isBusy || model.isReplaying {
                        model.stop(reason: "实时听译已暂停，可以说中文回复。")
                    }
                    showConversation = true
                }.buttonStyle(.bordered).controlSize(.small)
                Spacer(minLength: 4)
                Label(model.microphoneActive || model.isReplaying ? model.outputSide.name : "开始时检查耳机", systemImage: "headphones")
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
                        HStack {
                            Text("实时字幕")
                            Spacer()
                            Text("轻点译文重播")
                        }.font(.caption).foregroundStyle(.secondary)
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
            Text(model.microphoneActive ? "正在听，请自然讲话" : "听懂，就从这里开始").font(.title3).fontWeight(.medium)
            Text(model.microphoneActive ? "原文与译文会显示在这里" : "戴好耳机，轻点开始")
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
            if model.canReplay(caption) {
                Button { requestReplay(caption.id) } label: {
                    translatedText(caption, latest: latest)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityLabel(model.replayingCaptionID == caption.id && model.isReplaying
                                    ? "停止重播" : "重播译文：\(caption.translated)")
                .accessibilityHint(model.isRunning ? "会先询问是否暂停实时听译" : "使用这条译文原有的语言播放")
            } else {
                translatedText(caption, latest: latest).textSelection(.enabled)
            }
            if showOriginal {
                HighlightedCaptionText(text: caption.original, enabled: highlightInformation)
                    .equatable().font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if caption.replayStatus != .never {
                Label(caption.replayStatus.rawValue,
                      systemImage: model.replayingCaptionID == caption.id ? "speaker.wave.2.fill" : "arrow.counterclockwise")
                    .font(.caption2).foregroundStyle(accent)
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

    private func translatedText(_ caption: Caption, latest: Bool) -> some View {
        HighlightedCaptionText(text: caption.translated.isEmpty ? "正在组织译文…" : caption.translated,
                               enabled: highlightInformation && !caption.translated.isEmpty)
            .equatable()
            .font(.system(size: latest ? (largeCaptions ? 32 : 27) : (largeCaptions ? 23 : 19), weight: latest ? .medium : .regular))
            .foregroundStyle(latest ? Color.primary : Color.secondary)
            .lineSpacing(latest ? 6 : 4)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if model.pendingSpeechCount > 2 || !model.unheardCaptions.isEmpty {
                HStack {
                    Text(model.unheardCaptions.isEmpty ? "译音正在追赶" : "待补听 \(model.unheardCaptions.count) 段")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.unheardCaptions.isEmpty {
                        Button("补听") { showCatchUp = true }.font(.caption)
                    }
                    if model.isRunning && model.pendingSpeechCount > 2 {
                        Button("跳到当前") { askSkip = true }.font(.caption)
                    }
                }
            }
            HStack(spacing: 7) {
                Image(systemName: model.isReplaying ? "speaker.wave.2" : model.microphoneActive ? "waveform" : "pause.circle")
                    .foregroundStyle(model.microphoneActive || model.isReplaying ? accent : Color.secondary)
                Text(model.isReplaying ? "重播译文 · 收音已暂停" : model.isRunning ? "正在听译" : model.state.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.isRunning && !model.replayMessage.isEmpty {
                Text(model.replayMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button {
                    if model.isReplaying {
                        model.stopReplay()
                    } else if model.isRunning || model.isBusy {
                        startAfterPreparation = false
                        model.stop()
                    } else if !model.awarenessConfirmed {
                        askAwareness = true
                    } else { begin() }
                } label: {
                    Label(primaryTitle, systemImage: model.isReplaying ? "stop.fill" : model.isRunning || model.isBusy ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(accent, in: RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                }
                .buttonStyle(.plain)
                if model.isRunning || model.isBusy || model.isReplaying || !model.captions.isEmpty {
                    Button {
                        startAfterPreparation = false
                        if model.readableMinutes.lines.isEmpty { savedSummary = nil; model.end() }
                        else { askEnd = true }
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
        if model.isReplaying { return "停止重播" }
        if model.state == .buffering { return "暂停收音" }
        if model.isBusy { return "取消准备" }
        if model.isRunning { return "暂停听译" }
        return model.state == .paused ? "继续听译" : "开始听译"
    }

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.43, green: 0.84, blue: 0.81) : Color(red: 0.03, green: 0.50, blue: 0.51)
    }

    private func startPartnerTurn() {
        guard let language = partnerToHear else { return }
        partnerToHear = nil
        if model.source != language { model.source = language }
        if model.target != .chinese { model.target = .chinese }
        if model.awarenessConfirmed { begin() } else { askAwareness = true }
    }

    private func begin() {
        model.stopReplay()
        guard model.source != model.target else { showSettings = true; return }
        if model.resourcesReady { model.start() }
        else {
            startAfterPreparation = true
            model.requestPreparation(forListening: true)
        }
    }

    private func requestReplay(_ id: UUID) {
        guard !model.isBusy else { return }
        if model.isReplaying && model.replayingCaptionID == id {
            model.stopReplay()
        } else if model.isRunning {
            pendingReplayID = id
            askReplay = true
        } else { performReplay(id) }
    }

    private func performReplay(_ id: UUID?) {
        startAfterPreparation = false
        if let id { model.replayCaption(id) }
        else { model.replayUnheard() }
        pendingReplayID = nil
    }

    private func continueAfterPreparationIfReady() {
        guard startAfterPreparation, model.resourcesReady, model.state == .idle else { return }
        startAfterPreparation = false
        model.start()
    }
}

import SwiftUI
import Translation

struct ContentView: View {
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
    @State private var startAfterPreparation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if model.isBusy || model.state == .failed { statusNotice }
                if model.captions.isEmpty && model.draft.isEmpty {
                    ScrollView { emptyState }
                        .defaultScrollAnchor(.center, for: .alignment)
                        .frame(maxWidth: .infinity)
                } else { transcript }
            }
            .audioPage()
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
                MeetingMinutesView(minutes: meeting, listening: model.isRunning || model.isBusy || model.dialogueOwnsAudio, savedSummary: $savedSummary)
            }
            .sheet(isPresented: $showConversation) {
                ConversationView(model: model)
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
        .tint(AudioTheme.accent)
        .environmentObject(meetingPreferences)
        .background { GroupTranslationPreparation(coordinator: model.dialogue) }
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
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                DialogueMark().frame(width: 34, height: 34)
                Text(verbatim: "AirLive").font(.title2.weight(.bold))
                Spacer()
                Button { meetingSheet = model.readableMinutes } label: {
                    Image(systemName: "doc.text").frame(width: 44, height: 44)
                        .background(AudioTheme.surface, in: Circle())
                }
                .foregroundStyle(AudioTheme.text)
                .accessibilityLabel("会议纪要")
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .background(AudioTheme.surface, in: Circle())
                }
                .foregroundStyle(AudioTheme.text)
                .accessibilityLabel("打开设置")
            }
            HStack(spacing: 4) {
                Label("实时听译", systemImage: "waveform")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AudioTheme.accent)
                    .background(AudioTheme.canvas, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityAddTraits(.isSelected)
                Button {
                    showConversation = true
                } label: {
                    Label("面对面对话", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(AudioTheme.secondary)
            }
            .font(.subheadline.weight(.semibold)).padding(4)
            .background(AudioTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                Text(model.source.name).font(.subheadline.weight(.semibold))
                Image(systemName: "arrow.right").font(.caption.weight(.medium)).foregroundStyle(AudioTheme.secondary)
                Text(model.target.name).font(.subheadline.weight(.semibold))
                Spacer()
                Label(model.microphoneActive || model.isReplaying ? model.outputSide.name : "开始时检查耳机", systemImage: "headphones")
                    .font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
            }.padding(.horizontal, 2)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }

    private var statusNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.isBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.circle").foregroundStyle(AudioTheme.accent) }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if model.state == .failed {
                    Button("查看设置") { showSettings = true }.font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AudioTheme.blueWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 22)
        .padding(.top, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("实时字幕").font(.title2.weight(.bold)).foregroundStyle(AudioTheme.text)
                        Spacer()
                        Text("轻点译文重播")
                    }.font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                    ForEach(model.captions) { caption in
                        captionView(caption, latest: caption.id == model.captions.last?.id).id(caption.id)
                    }
                    if !model.draft.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("识别中 · 文字可能修订").font(AudioTheme.meta).foregroundStyle(AudioTheme.accent)
                            if showOriginal { Text(model.draft).font(.subheadline).foregroundStyle(AudioTheme.secondary) }
                        }
                    }
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 27)
            }
            .onChange(of: model.captions.count) { _, _ in proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            .onChange(of: model.captions.last?.translated) { _, _ in proxy.scrollTo("transcript-bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image("ListeningBuds").resizable().scaledToFit()
                .frame(width: 206, height: 136).accessibilityHidden(true)
            Text(model.microphoneActive ? "正在听" : "准备听译")
                .font(.title.weight(.bold)).foregroundStyle(AudioTheme.text)
            Text(model.microphoneActive ? "对方开口后，字幕会显示在这里。" : "戴上耳机，轻点下方开始。")
                .font(.subheadline).foregroundStyle(AudioTheme.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22).padding(.vertical, 20).frame(maxWidth: .infinity)
    }

    private func captionView(_ caption: Caption, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if latest || caption.status != .complete {
                HStack(spacing: 7) {
                    if latest { Image(systemName: "waveform").foregroundStyle(AudioTheme.accent) }
                    Text(caption.status.rawValue).font(AudioTheme.meta).foregroundStyle(latest ? AudioTheme.accent : AudioTheme.secondary)
                }
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
                    .font(.caption).foregroundStyle(AudioTheme.accent)
            }
            if caption.isProvisional {
                Text("提前译出 · 可能修订").font(.caption).foregroundStyle(AudioTheme.accent)
            }
            if let note = caption.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(AudioTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(latest ? 16 : 2)
        .background(latest ? AudioTheme.blueWash : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func translatedText(_ caption: Caption, latest: Bool) -> some View {
        HighlightedCaptionText(text: caption.translated.isEmpty ? "正在组织译文…" : caption.translated,
                               enabled: highlightInformation && !caption.translated.isEmpty)
            .equatable()
            .font(.system(latest ? (largeCaptions ? .largeTitle : .title) : (largeCaptions ? .title2 : .title3),
                          design: .default).weight(latest ? .semibold : .regular))
            .foregroundStyle(AudioTheme.text)
            .lineSpacing(latest ? 6 : 4)
    }

    private var controls: some View {
        VStack(spacing: 10) {
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
                Circle().fill(model.microphoneActive || model.isReplaying ? AudioTheme.accent : AudioTheme.secondary)
                    .frame(width: 7, height: 7)
                Text(model.dialogueOwnsAudio ? "面对面对话使用中" : model.isReplaying ? "重播译文 · 收音已暂停" : model.isRunning ? "正在听译" : model.state.rawValue)
            }
            .font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
            if !model.isRunning && !model.replayMessage.isEmpty {
                Text(model.replayMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button {
                    if model.dialogueOwnsAudio {
                        showConversation = true
                    } else if model.isReplaying {
                        model.stopReplay()
                    } else if model.isRunning || model.isBusy {
                        startAfterPreparation = false
                        model.stop()
                    } else if !model.awarenessConfirmed {
                        askAwareness = true
                    } else { begin() }
                } label: {
                    AudioActionLabel(title: primaryTitle, symbol: model.dialogueOwnsAudio ? "bubble.left.and.bubble.right" : model.isReplaying ? "stop.fill" : model.isRunning || model.isBusy ? "pause.fill" : "play.fill",
                             level: model.inputLevel, listening: model.microphoneActive)
                }
                .buttonStyle(.plain)
                if !model.dialogueOwnsAudio && (model.isRunning || model.isBusy || model.isReplaying || !model.captions.isEmpty) {
                    Button {
                        startAfterPreparation = false
                        if model.readableMinutes.lines.isEmpty { savedSummary = nil; model.end() }
                        else { askEnd = true }
                    } label: {
                        Text("结束").font(.subheadline)
                            .frame(minWidth: 54, minHeight: 56)
                            .padding(.horizontal, 3)
                            .background(AudioTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .foregroundStyle(AudioTheme.text)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 8)
        .background(AudioTheme.canvas)
    }

    private var primaryTitle: String {
        if model.dialogueOwnsAudio { return "返回面对面对话" }
        if model.isReplaying { return "停止重播" }
        if model.state == .buffering { return "暂停收音" }
        if model.isBusy { return "取消准备" }
        if model.isRunning { return "暂停听译" }
        return model.state == .paused ? "继续听译" : "开始听译"
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

private struct GroupTranslationPreparation: View {
    @ObservedObject var coordinator: DialogueCoordinator
    var body: some View {
        Color.clear.allowsHitTesting(false)
            .translationTask(coordinator.configuration) { session in await coordinator.prepare(using: session) }
    }
}

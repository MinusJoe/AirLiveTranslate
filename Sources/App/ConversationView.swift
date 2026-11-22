import SwiftUI
import Translation

struct ConversationView: View {
    @ObservedObject var listener: TranslationViewModel
    @ObservedObject var coordinator: DialogueCoordinator
    @ObservedObject private var reply: ConversationReplyModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStart = false
    @State private var confirmEnroll = false
    @State private var additionalSample = false
    @State private var confirmDelete = false
    @State private var notes: MeetingMinutes?
    @State private var summary: MeetingSummaryResult?

    init(model: TranslationViewModel) {
        listener = model
        coordinator = model.dialogue
        reply = model.dialogue.reply
    }

    var body: some View {
        NavigationStack {
            Group {
                if let editor = coordinator.editor {
                    DialogueEntryEditor(editor: editor, busy: reply.phase != .idle, message: reply.message,
                                        submit: { coordinator.submitEditor(editor.id, text: $0) },
                                        cancel: { coordinator.cancelEditor(editor.id) }).id(editor.id)
                } else {
                    VStack(spacing: 4) {
                        HStack {
                            Picker("对方的语言", selection: Binding(get: { coordinator.language }, set: coordinator.selectLanguage)) {
                                ForEach(AppLanguage.allCases.filter { $0 != .chinese }) { Text($0.name).tag($0) }
                            }.disabled(!coordinator.canConfigureDialogue)
                            Spacer()
                            Menu {
                                Button(coordinator.enrolled ? "重新登记我的声音" : "登记我的声音") { additionalSample = false; confirmEnroll = true }
                                    .disabled(!coordinator.canConfigureDialogue)
                                if coordinator.enrolled {
                                    Button("补录另一种语言") { additionalSample = true; confirmEnroll = true }
                                        .disabled(!coordinator.canConfigureDialogue)
                                    Button("删除我的声纹", role: .destructive) { confirmDelete = true }
                                        .disabled(coordinator.phase != .idle)
                                }
                            } label: {
                                Label(coordinator.enrolled ? "已登记声纹" : "我的声纹", systemImage: "waveform.badge.person.crop")
                                    .font(.subheadline)
                            }
                        }.padding(.horizontal, 20)
                        if coordinator.realtimeBusy {
                            liveTranscript
                        } else {
                            Picker("对话设备", selection: Binding(get: { coordinator.device }, set: coordinator.selectDevice)) {
                                ForEach(DialogueDevice.allCases, id: \.self) { device in
                                    Text(device.rawValue).tag(device)
                                }
                            }
                            .pickerStyle(.segmented).padding(.horizontal, 20)
                            .disabled(!coordinator.canConfigureDialogue)
                            transcript
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                }
            }
            .navigationTitle("面对面对话").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if coordinator.editor == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { notes = coordinator.minutes } label: { Image(systemName: "doc.text") }
                            .accessibilityLabel("对话记录与导出")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("返回") { dismiss() } }
                }
            }
            .audioPage()
        }
        .onAppear { coordinator.open() }
        .sheet(item: $notes) { snapshot in
            MeetingMinutesView(minutes: snapshot, listening: listener.dialogueOwnsAudio || coordinator.realtimeBusy, savedSummary: $summary)
        }
        .interactiveDismissDisabled(coordinator.editor != nil)
        .confirmationDialog("开始连续听译？", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("已告知在场人员，开始") { coordinator.start() }
        } message: {
            Text("请先告知所有参与者。首次需联网下载本机语音和声纹模型。返回其他页面后仍会收音，直到点「结束对话」。新对话会替换上次对话记录。")
        }
        .confirmationDialog("登记我的声音", isPresented: $confirmEnroll, titleVisibility: .visible) {
            Button("开始采样") { coordinator.start(enrollment: true, additional: additionalSample) }
        } message: {
            Text(additionalSample ? "请用另一种语言独自说约五秒。最多保存三段声音特征，样本只存在本机。"
                 : "接下来请独自说约五秒。首次需要下载模型；只在本机钥匙串保存声音特征。重新登记会在成功后替换旧样本。")
        }
        .confirmationDialog("删除本机保存的我的声纹？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除声纹", role: .destructive) { coordinator.removeVoiceprint() }
        }
    }

    private var transcript: some View {
        let latestPartner = coordinator.entries.last(where: { $0.speaker == .partner })?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if coordinator.entries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.3.fill").font(.largeTitle).foregroundStyle(AudioTheme.accent)
                            Text("中文 ⇄ \(coordinator.language.name)").font(AudioTheme.headline)
                            Text(coordinator.device == .phone
                                 ? "把手机放在你们之间。双方译文显示在这里，点喇叭就能用手机播放。"
                                 : "你说的话点喇叭才会外放，对方的中文译音自动送到耳机。")
                                .font(.subheadline).foregroundStyle(AudioTheme.secondary)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 34)
                    }
                    ForEach(coordinator.entries) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(entry.participantLabel ?? (entry.speaker == .me ? "我" : "对方"))
                                if entry.kind == .typed { Text("手动填写") }
                                if case .correction = entry.kind { Text("更正回复") }
                                if entry.supersededBy != nil { Text("已更正") }
                                if entry.correctionLanguage != nil {
                                    Button("更正") { coordinator.beginCorrection(of: entry.id) }
                                        .disabled(!coordinator.canAct)
                                }
                            }.font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.translated.isEmpty ? entry.original : entry.translated)
                                    .font(.title3.weight(.semibold)).textSelection(.enabled)
                                if let destination = entry.playback(in: coordinator.device) {
                                    playbackButton(entry, destination: destination)
                                }
                            }
                            if !entry.translated.isEmpty && entry.translated != entry.original {
                                Text(entry.original).font(.subheadline).foregroundStyle(AudioTheme.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(14)
                        .background(entry.speaker == .me ? AudioTheme.blueWash : AudioTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 15))
                        .frame(maxWidth: .infinity, alignment: entry.speaker == .me ? .trailing : .leading)
                        if entry.id == latestPartner, let question = coordinator.amountQuestion {
                            Button(question.label) { coordinator.ask(question) }.disabled(!coordinator.canAct)
                        }
                    }
                    Color.clear.frame(height: 1).id("group-bottom")
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            .onChange(of: coordinator.entries.last?.id) { _, _ in proxy.scrollTo("group-bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("group-bottom", anchor: .bottom) }
        }
    }

    private func playbackButton(_ entry: DialogueEntry, destination: DialoguePlayback) -> some View {
        let label: String
        let icon: String
        switch destination {
        case .phoneSpeaker(let language):
            label = "用手机扬声器播放\(language.name)译文"
            icon = "speaker.wave.2.fill"
        case .earpiece(let language):
            label = "用耳机播放\(language.name)译文"
            icon = "headphones"
        }
        return Button { coordinator.play(entry) } label: {
            Label(label, systemImage: icon).labelStyle(.iconOnly)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(AudioTheme.accent)
        .accessibilityLabel(label)
        .disabled(!coordinator.canAct)
    }

    /// The primary listener remains the only audio owner; this is a read-only mirror.
    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("实时听译 · \(listener.source.name) → \(listener.target.name)")
                        .font(.headline)
                    ForEach(listener.captions.filter { $0.status != .superseded }) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            if !row.translated.isEmpty { Text(row.translated).font(.title3) }
                            Text(row.original).foregroundStyle(AudioTheme.secondary)
                        }.textSelection(.enabled)
                    }
                    if !listener.draft.isEmpty { Text(listener.draft).foregroundStyle(AudioTheme.secondary) }
                    Color.clear.frame(height: 1).id("live-bottom")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .onAppear { proxy.scrollTo("live-bottom", anchor: .bottom) }
            .onChange(of: listener.captions.last?.translated) { _, _ in proxy.scrollTo("live-bottom", anchor: .bottom) }
            .onChange(of: listener.draft) { _, _ in proxy.scrollTo("live-bottom", anchor: .bottom) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if coordinator.realtimeBusy {
                Text("实时听译正在使用音频。可以浏览此页，开始面对面对话前请先停止实时听译。")
                    .font(.subheadline)
                Button("停止实时听译") { listener.stop(reason: "实时听译已手动停止。") }
            } else {
                if coordinator.phase == .capturing || !coordinator.entries.isEmpty {
                    ScrollView(.horizontal) {
                        HStack { ForEach(DialogueQuestion.allCases) { q in Button(q.label) { coordinator.ask(q) }.buttonStyle(.bordered) } }
                    }.disabled(!coordinator.canAct).scrollIndicators(.hidden)
                }
                if coordinator.canShowTypingFallback { Button("直接递给对方填写") { coordinator.showTypingFallback() } }
                if !coordinator.message.isEmpty {
                    Text(coordinator.message).font(.footnote).foregroundStyle(AudioTheme.secondary)
                }
                if coordinator.phase == .idle && coordinator.entries.isEmpty {
                    Text("请先告知在场人员。首次需联网下载本机模型；切换页面会继续收音，点「结束对话」停止。")
                        .font(.caption).foregroundStyle(AudioTheme.secondary)
                }
                Button {
                    if coordinator.phase == .idle {
                        if coordinator.entries.isEmpty { coordinator.start() } else { confirmStart = true }
                    } else { coordinator.end() }
                } label: {
                    AudioActionLabel(title: coordinator.phase == .idle ? "开始连续对话" :
                                        (coordinator.phase == .capturing ? "结束对话" : "取消"),
                                     symbol: coordinator.phase == .idle ? "mic.fill" : "stop.fill")
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 20).padding(.vertical, 8).background(AudioTheme.canvas)
    }
}

import SwiftUI
import Translation
import UIKit

struct ConversationView: View {
    @StateObject private var coordinator: DialogueCoordinator

    init(model: TranslationViewModel) {
        _coordinator = StateObject(wrappedValue: DialogueCoordinator(listener: model))
    }

    var body: some View {
        DialogueScreen(coordinator: coordinator, listener: coordinator.listener, reply: coordinator.reply)
    }
}

private struct DialogueScreen: View {
    @ObservedObject var coordinator: DialogueCoordinator
    @ObservedObject var listener: TranslationViewModel
    @ObservedObject var reply: ConversationReplyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var activePress: UUID?
    @State private var closed = false
    private var holding: Bool { activePress != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let editor = coordinator.editor {
                    DialogueEntryEditor(editor: editor, busy: reply.phase != .idle, message: reply.message,
                                        submit: { coordinator.submitEditor(editor.id, text: $0) },
                                        cancel: { coordinator.cancelEditor(editor.id) })
                        .id(editor.id)
                } else {
                    conversation
                }
            }
            .navigationTitle(coordinator.editor == nil ? "面对面对话" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(coordinator.editor == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if coordinator.editor == nil {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { close(); dismiss() } }
                }
            }
            .audioPage()
        }
        .onAppear { if !closed { coordinator.open() } }
        .interactiveDismissDisabled(coordinator.editor != nil)
        .onDisappear { close() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && (holding || reply.phase != .idle) { pause() }
        }
        .onChange(of: reply.phase) { _, phase in
            if phase == .idle { activePress = nil }
            if phase == .recording, holding, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: "可以说中文了。说完后激活结束发言按钮。")
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("对方的语言").font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                Spacer(minLength: 0)
                ForEach(AppLanguage.allCases.filter { $0 != .chinese }) { language in
                    let selected = coordinator.language == language
                    Button { coordinator.selectLanguage(language) } label: {
                        Text(language.name).font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AudioTheme.accent : AudioTheme.secondary)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(selected ? AudioTheme.blueWash : Color.clear, in: Capsule())
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .disabled(!coordinator.canChangeLanguage)
            .padding(.horizontal, 20)
            transcript.translationTask(listener.translationConfiguration) { session in
                await listener.prepareResources(using: session)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls.translationTask(reply.configuration) { session in await reply.prepare(using: session) }
        }
    }

    private var transcript: some View {
        let latestPartner = coordinator.entries.last(where: { $0.speaker == .partner })?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    if coordinator.entries.isEmpty && listener.draft.isEmpty && !showReplyDraft {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.largeTitle).symbolRenderingMode(.hierarchical).foregroundStyle(AudioTheme.accent)
                            Text("中文 ⇄ \(coordinator.language.name)").font(AudioTheme.headline)
                            Text("对方说话时听耳机，轮到你时按住下方按钮。")
                                .font(.subheadline).foregroundStyle(AudioTheme.secondary)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 48)
                    }
                    ForEach(coordinator.entries) { entry in
                        bubble(mine: entry.speaker == .me, original: entry.original, translated: entry.translated,
                               provisional: entry.isProvisional, entry: entry)
                        if entry.id == latestPartner, let amount = coordinator.amountQuestion {
                            questionButton(amount).disabled(!coordinator.canBeginReply || holding)
                        }
                    }
                    if !listener.draft.isEmpty && listener.microphoneActive {
                        bubble(mine: false, original: listener.draft, translated: "", provisional: true)
                    }
                    if showReplyDraft {
                        bubble(mine: true, original: reply.original, translated: reply.translated, provisional: reply.phase == .recording)
                    }
                    Color.clear.frame(height: 1).id("dialogue-bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .onAppear { if !coordinator.entries.isEmpty { proxy.scrollTo("dialogue-bottom", anchor: .bottom) } }
            .onChange(of: coordinator.entries.last?.id) { _, _ in proxy.scrollTo("dialogue-bottom", anchor: .bottom) }
            .onChange(of: coordinator.entries.last?.translated) { _, _ in proxy.scrollTo("dialogue-bottom", anchor: .bottom) }
            .onChange(of: listener.draft) { _, _ in proxy.scrollTo("dialogue-bottom", anchor: .bottom) }
            .onChange(of: reply.original) { _, _ in proxy.scrollTo("dialogue-bottom", anchor: .bottom) }
        }
    }

    private var showReplyDraft: Bool {
        guard reply.language == coordinator.language, !reply.original.isEmpty else { return false }
        if reply.phase != .idle { return true }
        return !coordinator.isListeningRequested && !reply.translated.isEmpty && !reply.message.isEmpty
    }

    private func bubble(mine: Bool, original: String, translated: String, provisional: Bool,
                        entry: DialogueEntry? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: mine ? "mic.fill" : "headphones")
                    .foregroundStyle(mine ? AudioTheme.accent : AudioTheme.secondary)
                Text((mine ? "我" : "对方") + (provisional ? " · 识别中" : ""))
                if entry?.kind == .typed { Text("手动填写") }
                if let entry, case .correction = entry.kind { Text("更正回复") }
                if entry?.supersededBy != nil { Text("已更正") }
                if let entry, entry.correctionLanguage != nil {
                    Button("更正") { coordinator.beginCorrection(of: entry.id) }
                        .disabled(!coordinator.canBeginReply || holding)
                        .accessibilityHint("编辑这句中文，在手机上播出更正后的译文。")
                }
            }.font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
            Text(translated.isEmpty ? original : translated)
                .font(.title3.weight(.semibold)).lineSpacing(4)
                .foregroundStyle(AudioTheme.text)
            if !translated.isEmpty { Text(original).font(.subheadline).foregroundStyle(AudioTheme.secondary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(mine ? AudioTheme.blueWash : AudioTheme.surface,
                    in: UnevenRoundedRectangle(topLeadingRadius: mine ? 18 : 5, bottomLeadingRadius: 18,
                                               bottomTrailingRadius: 18, topTrailingRadius: mine ? 5 : 18))
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 28)
        .textSelection(.enabled)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(DialogueQuestion.allCases) { question in questionButton(question) }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(!coordinator.canBeginReply || holding)
            if coordinator.canShowTypingFallback {
                Button("直接递给对方填写") { coordinator.showTypingFallback() }
                    .font(.subheadline)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(statusMessage).font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(sessionIsActive ? "暂停对话" : "开始听对方") {
                    if sessionIsActive { pause() } else { coordinator.startListening() }
                }
                .font(.subheadline.weight(.medium))
            }
            holdToTalk
            Text("松手后手机外放，播完自动继续听对方。")
                .font(.caption).foregroundStyle(AudioTheme.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(AudioTheme.canvas)
    }

    private func questionButton(_ question: DialogueQuestion) -> some View {
        Button { coordinator.ask(question) } label: {
            Text(question.label).font(.subheadline.weight(.medium)).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay { Capsule().strokeBorder(AudioTheme.separator, lineWidth: 1) }
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(AudioTheme.accent)
        .accessibilityLabel("追问，\(question.label)")
        .accessibilityHint(question == .writeNumber ? "用手机播出邀请，随后请对方在屏幕上填写。" : "用手机向对方播出追问，播完继续听。")
    }

    private var holdToTalk: some View {
        let enabled = holding || coordinator.canBeginReply
        return AudioActionLabel(title: holding ? (reply.phase == .recording ? "松开翻译并播放" : "请保持按住") : "按住说中文",
                        symbol: holding ? "waveform" : "mic.fill")
            .opacity(enabled ? 1 : 0.45)
            .overlay {
                ReplyPressSurface(acceptsPress: !holding && coordinator.canBeginReply, onPress: press,
                                  onRelease: release, onCancel: cancelTouch)
                    .accessibilityHidden(true)
            }
            .accessibilityRepresentation {
                Button(holding ? "结束发言并播放译文" : "开始说中文") {
                    if let token = activePress { release(token) } else { press(UUID()) }
                }
                .disabled(!enabled)
                .accessibilityHint("轻点两下开始，再轻点两下结束。译文从手机播出，播完继续听对方。")
            }
    }

    private var sessionIsActive: Bool {
        coordinator.isListeningRequested || listener.isBusy || listener.isRunning || reply.phase != .idle || holding
    }

    private var statusMessage: String {
        if !reply.message.isEmpty && (reply.phase != .idle || !coordinator.isListeningRequested) { return reply.message }
        if listener.isBusy || listener.state == .failed { return listener.message }
        if coordinator.isListeningRequested { return listener.isRunning ? "正在听对方 · 中文送到耳机" : "正在准备听对方…" }
        return "对话已暂停"
    }

    private func press(_ token: UUID) {
        guard !closed, !holding, coordinator.canBeginReply else { return }
        activePress = token
        coordinator.press()
    }

    private func release(_ token: UUID) {
        guard !closed, activePress == token else { return }
        activePress = nil
        coordinator.release()
    }

    private func cancelTouch(_ token: UUID) {
        guard !closed, activePress == token else { return }
        activePress = nil
        // The system resource download sheet can interrupt the first touch.
        // Preparation returns to idle and requires a new press to record.
        if reply.phase != .preparing { coordinator.cancelReply() }
    }

    private func pause() {
        activePress = nil
        coordinator.pause()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        activePress = nil
        coordinator.close()
    }
}

/// Touch-down starts a turn immediately. Keep this control mounted until the
/// finger lifts, including while speech resources or the microphone start up.
private struct ReplyPressSurface: UIViewRepresentable {
    var acceptsPress: Bool
    var onPress: (UUID) -> Void
    var onRelease: (UUID) -> Void
    var onCancel: (UUID) -> Void

    final class TouchControl: UIControl {
        var acceptsPress = false
        var onPress: ((UUID) -> Void)?
        var onRelease: ((UUID) -> Void)?
        var onCancel: ((UUID) -> Void)?
        private var trackingReply: UUID?

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard acceptsPress, trackingReply == nil else { return false }
            let token = UUID()
            trackingReply = token
            onPress?(token)
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { trackingReply != nil }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard let token = trackingReply else { return }
            trackingReply = nil
            if let touch, bounds.contains(touch.location(in: self)) { onRelease?(token) }
            else { onCancel?(token) }
        }

        override func cancelTracking(with event: UIEvent?) {
            guard let token = trackingReply else { return }
            trackingReply = nil
            onCancel?(token)
        }
    }

    func makeUIView(context: Context) -> TouchControl {
        let control = TouchControl()
        control.isAccessibilityElement = false
        control.isMultipleTouchEnabled = false
        return control
    }

    func updateUIView(_ control: TouchControl, context: Context) {
        control.acceptsPress = acceptsPress
        control.onPress = onPress
        control.onRelease = onRelease
        control.onCancel = onCancel
    }
}

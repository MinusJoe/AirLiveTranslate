import SwiftUI

struct DialogueEntryEditor: View {
    let editor: DialogueEditor
    let busy: Bool
    let message: String
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(editor: DialogueEditor, busy: Bool, message: String,
         submit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.editor = editor
        self.busy = busy
        self.message = message
        self.submit = submit
        self.cancel = cancel
        _text = State(initialValue: editor.initialText)
    }

    private var partner: Bool {
        if case .partnerInput = editor.purpose { return true }
        return false
    }
    private var japanese: Bool { editor.language == .japanese }
    private var title: String {
        guard partner else { return "更正我的发言" }
        return japanese ? "こちらに入力してください" : "Please type here"
    }
    private var hint: String {
        guard partner else { return japanese ? "修改中文后，将用日语播出更正。" : "修改中文后，将用英语播出更正。" }
        return japanese ? "金額、時刻、名前、住所など" : "Amount, time, name or address"
    }
    private var confirmLabel: String {
        guard partner else { return "翻译并播报更正" }
        return japanese ? "確定" : "Confirm"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AudioPageTitle(title)
                Text(hint).font(.subheadline).foregroundStyle(AudioTheme.secondary)
                TextField("", text: $text, axis: .vertical)
                    .accessibilityLabel(title)
                    .font(.system(.title2, design: partner ? .monospaced : .default))
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .disabled(busy)
                    .padding(16).frame(minHeight: 100, alignment: .topLeading)
                    .background(AudioTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(focused ? AudioTheme.accent : AudioTheme.separator, lineWidth: focused ? 1.5 : 1)
                    }
                if text.count > ReplayPolicy.maximumCaptionCharacters {
                    Text(partner
                         ? (japanese ? "1,800文字以内で入力してください。" : "Please use 1,800 characters or fewer.")
                         : "请将这句中文控制在 1,800 字以内。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !partner && !message.isEmpty {
                    HStack {
                        if busy { ProgressView() }
                        Text(message).font(.footnote)
                    }
                }
                if partner {
                    Text(japanese ? "確定すると会話に戻り、通訳を再開します。"
                                  : "Tap Confirm to return to the conversation and resume listening.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    focused = false
                    submit(text)
                } label: {
                    AudioActionLabel(title: confirmLabel, symbol: partner ? "checkmark" : "speaker.wave.2.fill", trailingSymbol: "arrow.right")
                }
                .buttonStyle(.plain)
                .opacity(busy || !editor.accepts(text) ? 0.5 : 1)
                .disabled(busy || !editor.accepts(text))
                Button(partner ? (japanese ? "キャンセル" : "Cancel") : "取消") { cancel() }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(22)
        }
        .audioPage()
        .onAppear { focused = true }
    }
}

import SwiftUI
import Translation

struct ConversationView: View {
    let source: CaptureSource
    let chineseVariant: SpeechVariant
    let rate: Float
    let listenToPartner: (AppLanguage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reply = ConversationReplyModel()
    @State private var language: AppLanguage

    init(language: AppLanguage, source: CaptureSource, chineseVariant: SpeechVariant,
         rate: Float, listenToPartner: @escaping (AppLanguage) -> Void) {
        _language = State(initialValue: language)
        self.source = source
        self.chineseVariant = chineseVariant
        self.rate = rate
        self.listenToPartner = listenToPartner
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("对方的语言", selection: $language) {
                    ForEach(AppLanguage.allCases.filter { $0 != .chinese }) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).disabled(reply.phase != .idle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !reply.translated.isEmpty, reply.language == language {
                            Text(reply.translated).font(.largeTitle.weight(.medium)).textSelection(.enabled)
                        }
                        if !reply.original.isEmpty, reply.language == language {
                            Text(reply.original).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if reply.original.isEmpty && reply.message.isEmpty || reply.language != language {
                            Text("你说中文，译文可以展示给对方，也可以用手机扬声器播放。")
                                .foregroundStyle(.secondary)
                        }
                        if !reply.message.isEmpty {
                            Text(reply.message).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if reply.phase == .idle, !reply.translated.isEmpty, reply.language == language {
                    Button { reply.play(rate: rate) } label: {
                        Label("用手机播给对方", systemImage: "speaker.wave.2.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                switch reply.phase {
                case .idle:
                    Button { reply.start(language: language, variant: chineseVariant, source: source) } label: {
                        Label("我说中文", systemImage: "mic.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large)
                    Button { listenToPartner(language); dismiss() } label: {
                        Label("听对方说 · \(language.name) → 中文", systemImage: "headphones").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large)
                case .recording:
                    Button("说完，翻译") { reply.finish() }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    Button("放弃这次发言") { reply.cancel() }.frame(maxWidth: .infinity)
                default:
                    HStack {
                        ProgressView()
                        Spacer()
                        Button(reply.phase == .playing ? "停止播放" : "取消") { reply.cancel() }
                    }
                }
            }
            .padding(24)
            .navigationTitle("面对面对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .translationTask(reply.configuration) { session in await reply.prepare(using: session) }
        }
        .onDisappear { reply.cancel() }
    }
}

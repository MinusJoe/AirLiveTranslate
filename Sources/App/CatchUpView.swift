import SwiftUI

struct CatchUpView: View {
    @ObservedObject var model: TranslationViewModel
    let highlightInformation: Bool
    let requestReplay: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var askPause = false
    @State private var pendingID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("仅显示本次会话仍保留、尚未完整听完的译文。补听会暂停实时收音，结束后由你手动恢复。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !model.replayMessage.isEmpty {
                        Text(model.replayMessage).font(.footnote)
                    }
                    if model.isReplaying {
                        Button("停止重播", role: .destructive) { model.stopReplay() }
                    } else if !model.unheardCaptions.isEmpty {
                        Button("按顺序补听") { request(nil) }
                            .disabled(model.isBusy)
                    }
                }
                Section("待补听 \(model.unheardCaptions.count) 段") {
                    if model.unheardCaptions.isEmpty {
                        ContentUnavailableView("没有待补听内容", systemImage: "checkmark.circle",
                                               description: Text("已补听完成的条目会从这里移除。"))
                    }
                    ForEach(model.unheardCaptions) { caption in
                        Button {
                            if model.replayingCaptionID == caption.id && model.isReplaying { model.stopReplay() }
                            else { request(caption.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(caption.targetLanguage.name).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: model.replayingCaptionID == caption.id ? "stop.circle" : "speaker.wave.2")
                                        .foregroundStyle(.teal)
                                }
                                HighlightedCaptionText(text: caption.translated, enabled: highlightInformation)
                                    .equatable().foregroundStyle(.primary)
                                Text(caption.original).font(.caption).foregroundStyle(.secondary)
                                Text("首次：\(caption.status.rawValue)").font(.caption2).foregroundStyle(.secondary)
                                if caption.replayStatus != .never {
                                    Text("补听：\(caption.replayStatus.rawValue)").font(.caption2).foregroundStyle(.secondary)
                                }
                                if caption.isProvisional {
                                    Text("提前译出 · 可能修订").font(.caption2).foregroundStyle(.orange)
                                }
                                if let note = caption.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canReplay(caption) || model.isBusy)
                        .accessibilityLabel(model.replayingCaptionID == caption.id && model.isReplaying
                                            ? "停止重播" : "补听译文：\(caption.translated)")
                    }
                }
                Section {
                    Text("每批最多 20 段，总计不超过 12,000 字符；超过范围的内容留待下一批。字幕只保留在内存中，结束会话后清空。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("未播内容补听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("暂停实时听译后补听？", isPresented: $askPause, titleVisibility: .visible) {
                Button("暂停并补听") { requestReplay(pendingID) }
                Button("取消", role: .cancel) { pendingID = nil }
            } message: {
                Text("补听只播放已有译文，结束后由你手动恢复实时收音。")
            }
        }
    }

    private func request(_ id: UUID?) {
        if model.isRunning { pendingID = id; askPause = true }
        else { requestReplay(id) }
    }
}

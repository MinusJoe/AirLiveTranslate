import SwiftUI
import UniformTypeIdentifiers

struct MeetingSummaryResult {
    let meetingID: UUID
    let lineCount: Int
    let text: String
    let provider: String
}

private struct MinutesTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: data, as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct MeetingMinutesView: View {
    let minutes: MeetingMinutes
    let listening: Bool
    @Binding var savedSummary: MeetingSummaryResult?
    @EnvironmentObject private var preferences: MeetingModelPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var unavailable = MeetingSummary.unavailableReason
    @State private var request: UUID?
    @State private var progress = ""
    @State private var notice = ""
    @State private var exporting = false
    @State private var document = MinutesTextFile("")
    @State private var askSend = false
    @State private var selectedRemote: MeetingConnection?

    private var summary: String? {
        guard savedSummary?.meetingID == minutes.id, savedSummary?.lineCount == minutes.lines.count else { return nil }
        return savedSummary?.text
    }

    var body: some View {
        NavigationStack {
            List {
                if minutes.lines.isEmpty {
                    ContentUnavailableView("等待会议发言", systemImage: "text.bubble",
                                           description: Text("开始听译后，已定稿的原文和已有译文会出现在这里。"))
                } else {
                    Section("AI 总结") {
                        NavigationLink("模型设置 · " + preferences.provider.rawValue) { MeetingModelSettings() }
                            .disabled(request != nil)
                        if let summary {
                            if let label = savedSummary?.provider { Text("生成来源 · " + label).font(.caption) }
                            Text(summary).textSelection(.enabled)
                        }
                        if preferences.provider == .apple, let unavailable {
                            Text(unavailable).foregroundStyle(.secondary)
                            Button("重新检查本机模型") { self.unavailable = MeetingSummary.unavailableReason }
                        } else if listening {
                            Text("暂停或结束听译后可生成总结。").foregroundStyle(.secondary)
                        } else if request != nil {
                            HStack { ProgressView(); Text(progress); Spacer(); Button("取消") { request = nil } }
                        } else {
                            Button(summary == nil ? "生成 AI 总结" : "重新生成") {
                                notice = ""
                                selectedRemote = preferences.provider == .custom ? preferences.connection : nil
                                if selectedRemote != nil { askSend = true } else { request = UUID() }
                            }
                        }
                        if summary != nil { Text("方括号中的编号对应下方原文。请核对决定、负责人和日期。").font(.caption) }
                    }
                    Section {
                        Button {
                            document = MinutesTextFile(minutes.export(summary: summary))
                            exporting = true
                        } label: { Label("导出到文件", systemImage: "square.and.arrow.up") }
                        if !notice.isEmpty { Text(notice).font(.footnote) }
                    } footer: {
                        Text("当前所见为打开时的记录。导出后可在「文件」中保留。")
                    }
                    Section("定稿记录 · \(minutes.lines.count) 段") {
                        if minutes.omitted > 0 { Text("达到记录上限，另有 \(minutes.omitted) 段未收录。").foregroundStyle(.orange) }
                        ForEach(minutes.lines.indices, id: \.self) { index in
                            let line = minutes.lines[index]
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("[\(index + 1)]")
                                    Text(line.time, format: .dateTime.hour().minute().second())
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(line.original)
                                if !line.translated.isEmpty { Text(line.translated).foregroundStyle(.secondary) }
                            }.textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("会议纪要")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .confirmationDialog("发送定稿原文并生成总结？", isPresented: $askSend, titleVisibility: .visible) {
            Button("发送并生成") { request = UUID() }
            Button("取消", role: .cancel) { selectedRemote = nil }
        } message: {
            if let config = selectedRemote {
                Text("将把这 \(minutes.lines.count) 段文字分批发到 \(config.baseURL)，由 \(config.model) 处理。服务可能计费，并按其政策处理数据。")
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .plainText,
                      defaultFilename: "会议纪要-" + (minutes.lines.first?.time ?? Date()).formatted(.iso8601.year().month().day())) { result in
            switch result {
            case .success: notice = "会议纪要已导出。"
            case .failure(let error): notice = "导出未完成。\(error.localizedDescription)"
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { unavailable = MeetingSummary.unavailableReason } }
        .task(id: request) {
            guard let token = request else { return }
            let remote = selectedRemote
            do {
                let text = try await MeetingSummary.generate(minutes, remote: remote) { index, total in
                    if request == token { progress = "正在整理 \(index) / \(total)" }
                }
                try Task.checkCancellation()
                guard request == token else { return }
                savedSummary = MeetingSummaryResult(meetingID: minutes.id, lineCount: minutes.lines.count,
                                                   text: text, provider: remote?.model ?? "Apple 智能")
            } catch {
                guard !Task.isCancelled, request == token else { return }
                unavailable = MeetingSummary.unavailableReason
                notice = "总结未完成，记录仍可导出。\(error.localizedDescription)"
            }
            if request == token { request = nil }
        }
    }
}

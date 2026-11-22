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
                VStack(alignment: .leading, spacing: 6) {
                    if let date = minutes.lines.first?.time {
                        Text(date, format: .dateTime.year().month().day())
                            .font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                    }
                    AudioPageTitle("会议纪要")
                }.listRowSeparator(.hidden).surfaceRow()
                if minutes.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("等待会议发言").font(.title3)
                        Text("开始听译后，这里会按时间收录定稿发言。").font(.subheadline).foregroundStyle(AudioTheme.secondary)
                    }.padding(.vertical, 16).listRowSeparator(.hidden).surfaceRow()
                } else {
                    Section {
                        NavigationLink("模型设置 · " + preferences.provider.rawValue) { MeetingModelSettings() }
                            .disabled(request != nil)
                        if let summary {
                            if let label = savedSummary?.provider { Text("生成来源 · " + label).font(.caption) }
                            Text(summary).font(.body).lineSpacing(5).textSelection(.enabled)
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
                    } header: { AudioSectionTitle("AI 总结") }
                    .surfaceRow()
                    Section {
                        Button {
                            document = MinutesTextFile(minutes.export(summary: summary))
                            exporting = true
                        } label: { Label("导出到文件", systemImage: "square.and.arrow.up") }
                        if !notice.isEmpty { Text(notice).font(.footnote) }
                    } footer: {
                        Text("当前所见为打开时的记录。导出后可在「文件」中保留。")
                    }.surfaceRow()
                    Section {
                        if minutes.omitted > 0 { Text("达到记录上限，另有 \(minutes.omitted) 段未收录。").foregroundStyle(AudioTheme.accent) }
                        ForEach(minutes.lines.indices, id: \.self) { index in
                            let line = minutes.lines[index]
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("[\(index + 1)]").font(AudioTheme.meta).foregroundStyle(AudioTheme.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        if let participant = line.participant { Text(participant) }
                                        Text(line.time, format: .dateTime.hour().minute().second())
                                    }.font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                                    Text(line.translated.isEmpty ? line.original : line.translated)
                                        .font(.system(.title3, design: .default)).lineSpacing(3)
                                    if !line.translated.isEmpty {
                                        Text(line.original).font(.subheadline).foregroundStyle(AudioTheme.secondary)
                                    }
                                }
                            }.padding(.vertical, 6).textSelection(.enabled)
                        }
                    } header: { AudioSectionTitle("定稿记录 · \(minutes.lines.count) 段") }
                    .surfaceRow()
                }
            }
            .audioList()
            .navigationTitle("")
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

import AVFAudio
import SwiftUI

struct ModelCenterDestination: View {
    @EnvironmentObject private var live: TranslationViewModel
    var body: some View { ModelCenterView(live: live, group: live.dialogue, library: live.modelLibrary) }
}

struct ModelCenterView: View {
    @ObservedObject var live: TranslationViewModel
    @ObservedObject var group: DialogueCoordinator
    @ObservedObject var library: ModelLibrary
    @EnvironmentObject private var preferences: MeetingModelPreferences
    @Environment(\.scenePhase) private var scene
    @State private var minutes: MeetingMinutes?
    @State private var summary: MeetingSummaryResult?
    @State private var intelligenceStatus = "正在检查…"
    @State private var voices: [AppLanguage: String] = [:]

    private var featured: [ModelResource] {
        var resources: [ModelResource] = [.multilingual, .speakers, .speech(live.sourceVariant)]
        if preferences.remote(for: .live) == nil && live.source != live.target {
            resources.append(.translation(live.source, live.target))
        }
        if preferences.remote(for: .dialogue) == nil {
            for kind in [ModelResource.translation(.chinese, group.language), .translation(group.language, .chinese)] {
                if !resources.contains(kind) { resources.append(kind) }
            }
        }
        return resources
    }
    private var others: [ModelResource] {
        let allPairs = AppLanguage.allCases.flatMap { from in
            AppLanguage.allCases.filter { $0 != from }.map { ModelResource.translation(from, $0) }
        }
        return (SpeechVariant.allCases.map(ModelResource.speech) + allPairs).filter { !featured.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(ModelUse.allCases) { use in
                    NavigationLink {
                        MeetingModelSettings(use: use)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(use.title)
                            Text(preferences.remote(for: use)?.model ?? use.localLabel)
                                .font(AudioTheme.meta).foregroundStyle(AudioTheme.secondary)
                        }
                    }
                }
            } header: { AudioSectionTitle("按用途选择模型") } footer: {
                Text("各场景可以分别选本机或自定义服务。自定义服务处理文字，录音和声纹始终留在手机。")
            }.surfaceRow()
            if !live.readableMinutes.lines.isEmpty || !group.minutes.lines.isEmpty {
                Section {
                    if !live.readableMinutes.lines.isEmpty {
                        Button("查看实时听译纪要") { minutes = live.readableMinutes }
                    }
                    if !group.minutes.lines.isEmpty {
                        Button("查看面对面对话纪要") { minutes = group.minutes }
                    }
                } header: { AudioSectionTitle("当前记录") }.surfaceRow()
            }
            Section {
                ForEach(featured, id: \.self) { kind in resourceRow(kind) }
                DisclosureGroup("其他语言资源") { ForEach(others, id: \.self) { kind in resourceRow(kind) } }
            } header: { AudioSectionTitle("本机资源") } footer: {
                Text("可在使用前准备。多人模型的进度包含下载与编译；Apple 翻译包由系统安装，只显示状态。离开此页仍可继续准备。")
            }.surfaceRow()
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple 智能 · 会议总结")
                    Text(intelligenceStatus).font(.footnote).foregroundStyle(AudioTheme.secondary)
                }
                ForEach(AppLanguage.allCases) { lang in
                    LabeledContent("系统朗读 · \(lang.name)", value: voices[lang] ?? "正在检查…")
                }
            } header: { AudioSectionTitle("系统管理") }.surfaceRow()
        }
        .audioList().navigationTitle("模型中心").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $minutes) { snapshot in
            MeetingMinutesView(minutes: snapshot, listening: live.isRunning || live.isBusy || live.dialogueOwnsAudio,
                               savedSummary: $summary, linksToModelCenter: false)
        }
        .task(id: featured) { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scene) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        intelligenceStatus = MeetingSummary.unavailableReason ?? "系统模型可用"
        voices = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map {
            ($0, AVSpeechSynthesisVoice(language: $0.speechLocale)?.name ?? "需在系统设置中准备")
        })
        await library.refresh(featured + others)
    }

    @ViewBuilder private func resourceRow(_ kind: ModelResource) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kind.title).font(.headline)
            switch kind {
            case .multilingual: Text("面对面对话 · 多语种语音转文字").font(.caption)
            case .speakers: Text("面对面对话 · 区分说话人与声纹登记").font(.caption)
            case .speech: Text("实时听译 · 本机语音转文字").font(.caption)
            case .translation: Text("本机文字翻译").font(.caption)
            }
            switch library.states[kind] ?? .checking {
            case .checking: Text("正在检查…").font(.footnote)
            case .installed: Label("已就绪", systemImage: "checkmark.circle").font(.footnote)
            case .unavailable(let reason): Text(reason).font(.footnote)
            case .preparing(let label, let fraction):
                if let fraction {
                    ProgressView(value: fraction, total: 1, label: { Text(label) },
                                 currentValueLabel: { Text(fraction.formatted(.percent.precision(.fractionLength(0)))) })
                } else { HStack { ProgressView(); Text(label) } }
            case .missing: resourceAction("待下载或补齐", kind: kind, label: "准备")
            case .cached: resourceAction("已缓存", kind: kind, label: "检查并准备")
            case .failed(let reason): resourceAction(reason, kind: kind, label: "重试")
            }
        }.padding(.vertical, 5)
    }
    private func resourceAction(_ detail: String, kind: ModelResource, label: String) -> some View {
        HStack {
            Text(detail).font(.footnote).foregroundStyle(AudioTheme.secondary)
            Spacer()
            Button(label) { library.request(kind) }.buttonStyle(.borderless)
                .disabled(library.waitingForOtherPair(kind))
        }
    }
}

import SwiftUI

struct CounterDisplayView: View {
    @ObservedObject var coordinator: DialogueCoordinator
    let returnToList: () -> Void
    let toggleCapture: () -> Void
    @State private var pinnedID: UUID?
    @State private var supplement: Supplement?
    @State private var approvedSupplement: SupplementKey?

    private struct SupplementKey: Equatable {
        let text: CounterText?
        let connection: MeetingConnection?
    }
    private struct SupplementRequest: Equatable {
        let key: SupplementKey
        let allowed: Bool
    }

    private struct Supplement {
        let key: SupplementKey
        var chinese: String?
        var foreign: String?
        var finished = false
    }

    var body: some View {
        let rows = coordinator.entries.filter { $0.supersededBy == nil }
        let index = pinnedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.indices.last
        let row = index.map { rows[$0] }
        let key = row.map { CounterText($0, fallbackPartner: coordinator.language) }
        let selection = SupplementKey(text: key, connection: coordinator.textConnection)
        let extra = supplement?.key == selection ? supplement : nil
        let allowed = selection.connection == nil || coordinator.phase == .capturing || approvedSupplement == selection
        let partner = key?.partner ?? coordinator.language
        VStack(spacing: 0) {
            panel(language: partner, value: key?.foreign ?? extra?.foreign, key: key, finished: !allowed || extra?.finished == true)
                .rotationEffect(.degrees(180))
            VStack(spacing: 3) {
                HStack {
                    Button("退出展示", action: returnToList)
                    Spacer()
                    if let row { DialogueSpeakerLabel(entry: row, coordinator: coordinator) }
                    Spacer()
                    Button(coordinator.phase == .idle ? "开始对话" : (coordinator.phase == .capturing ? "结束对话" : "取消"),
                           action: toggleCapture)
                }.font(.subheadline.weight(.medium))
                HStack {
                    Button { if let index, index > 0 { pinnedID = rows[index - 1].id } } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.disabled((index ?? 0) == 0).accessibilityLabel("上一句")
                    Spacer()
                    Button {
                        pinnedID = pinnedID == nil ? row?.id : nil
                    } label: {
                        Label(pinnedID == nil ? "锁定这句" : "跟随最新", systemImage: pinnedID == nil ? "pin" : "arrow.down.to.line")
                    }.disabled(row == nil)
                    Spacer()
                    if let row, let route = row.playback(in: coordinator.device) {
                        Button { coordinator.play(row) } label: {
                            Image(systemName: routeIcon(route)).frame(width: 44, height: 44)
                        }
                        .disabled(!coordinator.canAct || coordinator.pendingSpeakers[row.id] != nil)
                        .accessibilityLabel(playLabel(route))
                    }
                    Button {
                        if let index, index + 1 < rows.count { pinnedID = rows[index + 1].id }
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }.disabled((index ?? 0) + 1 >= rows.count).accessibilityLabel("下一句")
                }.font(.footnote)
                if !coordinator.message.isEmpty {
                    Text(coordinator.message).font(.caption).foregroundStyle(AudioTheme.secondary)
                }
                if !allowed, let key, key.source != nil, key.chinese == nil || key.foreign == nil,
                   extra?.finished != true, let service = selection.connection {
                    Button("发送此句到 \(service.baseURL) 补译") { approvedSupplement = selection }.font(.caption)
                }
            }.padding(.horizontal, 16).padding(.vertical, 4).background(AudioTheme.surface).layoutPriority(1)
            panel(language: .chinese, value: key?.chinese ?? extra?.chinese, key: key, finished: !allowed || extra?.finished == true)
        }
        .onChange(of: rows.last?.id) { _, _ in
            if let pinnedID, !rows.contains(where: { $0.id == pinnedID }) { self.pinnedID = nil }
        }
        .task(id: SupplementRequest(key: selection, allowed: allowed)) {
            guard allowed, let key, let source = key.source, key.chinese == nil || key.foreign == nil else { return }
            var result = Supplement(key: selection)
            for dest in [AppLanguage.chinese, key.partner] {
                let existing = dest == .chinese ? key.chinese : key.foreign
                if existing != nil { continue }
                // A same-language reply can lack the other reader's language.
                // This supplemental translation is for display only.
                let text = try? await DialogueTextTranslation.translate(key.original, from: source, to: dest, connection: selection.connection)
                guard !Task.isCancelled else { return }
                if dest == .chinese { result.chinese = text } else { result.foreign = text }
            }
            result.finished = true
            supplement = result
        }
    }

    private func panel(language: AppLanguage, value: String?, key: CounterText?, finished: Bool) -> some View {
        let originalOnly = key != nil && value == nil && (key?.source == nil || finished)
        return ScrollView {
            VStack(spacing: 12) {
                Text(originalOnly ? originalLabel(language) : language.name)
                    .font(AudioTheme.meta).foregroundStyle(AudioTheme.accent)
                if let value {
                    Text(value).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                } else if originalOnly, let key {
                    Text(key.original).font(.title2).textSelection(.enabled)
                } else if key != nil {
                    ProgressView()
                } else {
                    Text(language == .chinese ? "等待发言" : language == .japanese ? "発言を待っています" : "Waiting for speech")
                        .font(.title2).foregroundStyle(AudioTheme.secondary)
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(18)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(language.rawValue + (key?.id.uuidString ?? ""))
    }

    private func originalLabel(_ lang: AppLanguage) -> String {
        switch lang {
        case .chinese: return "原文 · 暂无译文"
        case .english: return "Original · Translation unavailable"
        case .japanese: return "原文 · 翻訳なし"
        }
    }

    private func routeIcon(_ route: DialoguePlayback) -> String {
        if case .earpiece = route { return "headphones" }
        return "speaker.wave.2.fill"
    }
    private func playLabel(_ route: DialoguePlayback) -> String {
        switch route {
        case .earpiece(let language): return "用耳机播放\(language.name)"
        case .phoneSpeaker(let language): return "用手机播放\(language.name)"
        }
    }
}

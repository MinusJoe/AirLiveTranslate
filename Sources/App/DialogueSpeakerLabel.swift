import SwiftUI

struct DialogueSpeakerLabel: View {
    let entry: DialogueEntry
    @ObservedObject var coordinator: DialogueCoordinator

    var body: some View {
        let current = entry.participantLabel ?? (entry.speaker == .me ? "我" : "对方")
        if entry.canAssignSpeaker {
            Menu {
                let common = VoiceParty.assignable.filter { party in
                    [.wearer, .guest(0), .guest(1)].contains(party) || coordinator.entries.contains { $0.party == party }
                }
                ForEach(common, id: \.label) { choice in option(choice) }
                let remaining = VoiceParty.assignable.filter { !common.contains($0) }
                if !remaining.isEmpty {
                    Menu("其他说话人") { ForEach(remaining, id: \.label) { choice in option(choice) } }
                }
            } label: {
                HStack(spacing: 4) {
                    if let pending = coordinator.pendingSpeakers[entry.id] { Text("\(pending.label) · 重译中") }
                    else { Text(current); if entry.manuallyAssigned { Text("· 已改") } }
                    Image(systemName: "chevron.down").font(.caption2)
                }.foregroundStyle(AudioTheme.accent).frame(minHeight: 32)
            }
            .disabled(!coordinator.canAct)
            .accessibilityLabel("改正说话人，当前\(current)")
            .accessibilityHint("选择后重新翻译这一句。播过的内容可手动重播。")
        } else { Text(current) }
    }

    @ViewBuilder private func option(_ choice: VoiceParty) -> some View {
        if let source = entry.sourceLanguage {
            Button {
                coordinator.assignSpeaker(entry.id, to: choice, source: source)
            } label: {
                if (coordinator.pendingSpeakers[entry.id] ?? entry.party) == choice { Label(choice.label, systemImage: "checkmark") }
                else { Text(choice.label) }
            }
        } else if let partner = entry.partnerLanguage {
            Menu(choice.label) {
                ForEach([AppLanguage.chinese, partner]) { lang in
                    Button("原文是\(lang.name)") { coordinator.assignSpeaker(entry.id, to: choice, source: lang) }
                }
            }
        }
    }
}

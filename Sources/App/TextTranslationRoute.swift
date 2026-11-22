import Foundation
import Translation

/// The provider and credentials are captured at session start, so a settings
/// change cannot redirect an ongoing conversation to a different service.
@MainActor
final class TextTranslationRoute {
    private let from: AppLanguage
    private let to: AppLanguage
    private let local: TranslationSession?
    private let remote: CustomMeetingModel?

    init(from: AppLanguage, to: AppLanguage, connection: MeetingConnection?, use: ModelUse) throws {
        self.from = from
        self.to = to
        if let connection {
            let key = try MeetingKeychain.read(connection.endpoint(), for: use)
            remote = CustomMeetingModel(connection: connection, key: key, session: CustomMeetingModel.makeSession())
            local = nil
        } else {
            local = TranslationSession(installedSource: Locale.Language(identifier: from.rawValue),
                                       target: Locale.Language(identifier: to.rawValue))
            remote = nil
        }
    }

    func translate(_ text: String) async throws -> String {
        try Task.checkCancellation()
        if from == to { return text }
        if let remote { return try await remote.translate(text, from: from, to: to) }
        guard let local else { throw CancellationError() }
        return try await local.translate(text).targetText
    }

    func cancel() {
        local?.cancel()
        remote?.session.invalidateAndCancel()
    }
}

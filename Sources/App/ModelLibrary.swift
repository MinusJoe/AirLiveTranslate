import Foundation
import Combine
import FluidAudio
import Translation

enum ModelResource: Hashable, Sendable {
    case multilingual, speakers, speech(SpeechVariant), translation(AppLanguage, AppLanguage)
    var title: String {
        switch self {
        case .multilingual: return "SenseVoice Small · FP16"
        case .speakers: return "Pyannote 分段 + WeSpeaker v2"
        case .speech(let variant): return "Apple 语音识别 · " + variant.name
        case .translation(let from, let to): return "Apple 翻译 · \(from.name) → \(to.name)"
        }
    }
}

enum ModelResourceState: Equatable, Sendable {
    case checking, missing, cached, installed, unavailable(String), preparing(String, Double?), failed(String)

    func updated(label: String, fraction: Double?) -> Self {
        guard case .preparing(_, let old) = self else { return self }
        guard let fraction, fraction.isFinite else { return old == nil ? .preparing(label, nil) : self }
        let value = floor(min(1, max(0, fraction)) * 100) / 100
        guard value >= (old ?? 0) else { return self }
        return .preparing(label, value)
    }
}

/// Manual predownloads and normal session startup join the same underlying job.
@MainActor
final class SharedModelLoad<Value: Sendable> {
    private var active: Task<Value, Error>?
    func run(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let active { return try await active.value }
        let task = Task {
            defer { self.active = nil }
            return try await operation()
        }
        active = task
        return try await task.value
    }
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var states: [ModelResource: ModelResourceState] = [:]
    @Published private(set) var translationRequest: TranslationSession.Configuration?
    private var manualPair: ModelResource?
    private var manualStarted = false
    private var versions: [ModelResource: UUID] = [:]
    private let speakerLoad = SharedModelLoad<DiarizerModels>()
    private let recognizerLoad = SharedModelLoad<SenseVoiceManager>()
    private var speechLoads: [SpeechVariant: SharedModelLoad<Void>] = [:]
    private var pairLoads: [ModelResource: SharedModelLoad<Void>] = [:]

    private func begin(_ kind: ModelResource, label: String) -> UUID {
        let id = UUID()
        versions[kind] = id
        states[kind] = .preparing(label, nil)
        return id
    }

    private func progress(_ kind: ModelResource, id: UUID, label: String, fraction: Double?) {
        guard versions[kind] == id, let current = states[kind] else { return }
        let next = current.updated(label: label, fraction: fraction)
        if current != next { states[kind] = next }
    }

    private func finish(_ kind: ModelResource, _ id: UUID, error: Error? = nil) {
        guard versions[kind] == id else { return }
        versions[kind] = UUID()
        states[kind] = error.map { .failed($0.localizedDescription) } ?? .installed
    }

    private func handler(_ kind: ModelResource, _ id: UUID) -> FluidAudio.ProgressHandler {
        { [weak self] update in
            let label: String
            switch update.phase {
            case .listing: label = "正在检查模型文件"
            case .downloading(let completed, let total): label = total > 0 ? "下载文件 \(completed)/\(total)" : "正在检查缓存"
            case .compiling(let name): label = name.isEmpty ? "正在完成准备" : "正在编译 \(name)"
            @unknown default: label = "正在准备"
            }
            Task { @MainActor in self?.progress(kind, id: id, label: label, fraction: update.fractionCompleted) }
        }
    }

    func loadSpeakers() async throws -> DiarizerModels {
        try await speakerLoad.run {
            let id = self.begin(.speakers, label: "正在检查声纹模型")
            do {
                let models = try await DiarizerModels.downloadIfNeeded(progressHandler: self.handler(.speakers, id))
                self.finish(.speakers, id)
                return models
            } catch { self.finish(.speakers, id, error: error); throw error }
        }
    }

    func loadMultilingual() async throws -> SenseVoiceManager {
        try await recognizerLoad.run {
            let id = self.begin(.multilingual, label: "正在检查多语种模型")
            do {
                let manager = try await SenseVoiceManager.load(progressHandler: self.handler(.multilingual, id))
                self.finish(.multilingual, id)
                return manager
            } catch { self.finish(.multilingual, id, error: error); throw error }
        }
    }

    func installSpeech(_ variant: SpeechVariant) async throws {
        let slot = speechLoads[variant] ?? SharedModelLoad<Void>()
        speechLoads[variant] = slot
        try await slot.run {
            let kind = ModelResource.speech(variant)
            let id = self.begin(kind, label: "正在检查系统资源")
            do {
                if !(await SpeechRecognizer.hasInstalledAssets(for: variant)) {
                    try await SpeechRecognizer.installAssets(for: variant) { [weak self] fraction in
                        self?.progress(kind, id: id, label: "系统下载与安装", fraction: fraction)
                    }
                }
                guard await SpeechRecognizer.hasInstalledAssets(for: variant) else {
                    throw PipelineError.message("系统尚未安装这个语音模型。")
                }
                self.finish(kind, id)
            } catch { self.finish(kind, id, error: error); throw error }
        }
    }

    func prepareTranslation(_ session: TranslationSession, from: AppLanguage, to: AppLanguage) async throws {
        let kind = ModelResource.translation(from, to)
        let slot = pairLoads[kind] ?? SharedModelLoad<Void>()
        pairLoads[kind] = slot
        try await slot.run {
            let id = self.begin(kind, label: "等待系统确认或安装")
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard await LanguageAvailability().status(from: .init(identifier: from.rawValue), to: .init(identifier: to.rawValue)) == .installed
                else { throw PipelineError.message("系统尚未完成安装。") }
                self.finish(kind, id)
            } catch { self.finish(kind, id, error: error); throw error }
        }
        try Task.checkCancellation()
    }

    func request(_ kind: ModelResource) {
        if case .preparing = states[kind] { return }
        switch kind {
        case .multilingual: Task { _ = try? await loadMultilingual() }
        case .speakers: Task { _ = try? await loadSpeakers() }
        case .speech(let variant): Task { try? await installSpeech(variant) }
        case .translation(let from, let to):
            guard manualPair == nil else { return }
            manualPair = kind
            _ = begin(kind, label: "等待系统确认")
            manualStarted = false
            translationRequest = .init(source: .init(identifier: from.rawValue), target: .init(identifier: to.rawValue))
        }
    }

    func installRequestedPair(_ session: TranslationSession) async {
        guard case .translation(let from, let to) = manualPair, !manualStarted,
              session.sourceLanguage?.languageCode == Locale.Language(identifier: from.rawValue).languageCode,
              session.targetLanguage?.languageCode == Locale.Language(identifier: to.rawValue).languageCode else { return }
        manualStarted = true
        defer { manualPair = nil; translationRequest = nil }
        do { try await prepareTranslation(session, from: from, to: to) } catch { /* state contains the error */ }
    }

    func refresh(_ kinds: [ModelResource]) async {
        for kind in kinds {
            if case .preparing = states[kind] { continue }
            let version = versions[kind]
            let status: ModelResourceState
            switch kind {
            case .speech(let variant):
                if await SpeechRecognizer.hasInstalledAssets(for: variant) { status = .installed }
                else if await SpeechRecognizer.availableVariants(for: variant.language).contains(variant) { status = .missing }
                else { status = .unavailable("系统不支持此识别地区") }
            case .translation(let from, let to):
                switch await LanguageAvailability().status(from: .init(identifier: from.rawValue), to: .init(identifier: to.rawValue)) {
                case .installed: status = .installed
                case .supported: status = .missing
                default: status = .unavailable("系统不支持这个语言对")
                }
            case .multilingual, .speakers:
                let cached = await Task.detached(priority: .utility) { Self.cached(kind) }.value
                status = cached ? .cached : .missing
            }
            guard !Task.isCancelled else { return }
            if versions[kind] == version {
                if case .failed = states[kind], status == .missing || status == .cached { continue }
                if states[kind] == .installed && status == .cached { continue }
                states[kind] = status
            }
        }
    }

    func waitingForOtherPair(_ kind: ModelResource) -> Bool {
        if case .translation = kind, let manualPair { return manualPair != kind }
        return false
    }

    nonisolated private static func cached(_ kind: ModelResource) -> Bool {
        if kind == .multilingual {
            return SenseVoiceModels.modelsExist(at: MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall))
        }
        let fm = FileManager.default
        let root = DiarizerModels.defaultModelsDirectory()
        return DiarizerModels.requiredModelNames.allSatisfy { name in
            let dir = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: dir.appendingPathComponent("coremldata.bin").path),
                  let contents = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
            return !contents.contains { ($0 as? URL)?.pathExtension == "partial" }
        }
    }
}

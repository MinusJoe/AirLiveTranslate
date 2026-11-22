import AVFAudio
import FluidAudio

/// One microphone FIFO, one ordered consumer. Neither audio nor speaker vectors
/// are sent to model hosting services.
actor GroupSpeechAnalyzer {
    private var asr: SenseVoiceManager?
    private var speakerModels: DiarizerModels?

    func prepare(enrollment: Bool, library: ModelLibrary) async throws {
        if speakerModels == nil { speakerModels = try await library.loadSpeakers() }
        try Task.checkCancellation()
        if !enrollment, asr == nil { asr = try await library.loadMultilingual() }
        try Task.checkCancellation()
    }

    func consume(_ fifo: BufferedMicrophoneAudio, enrollment: Bool,
                 receive: @escaping @MainActor (GroupUtterance) async throws -> Void,
                 register: @escaping @MainActor ([Float]) throws -> Void) async throws {
        guard let speakerModels, let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        else { throw PipelineError.message("声纹模型尚未就绪。") }
        let converter = PCMConverter(to: fmt)
        var reader = fifo.makeReader()
        var windows = UtteranceWindower(enrollment: enrollment)
        var frames = 0
        func ingest(_ pcm: AVAudioPCMBuffer) async throws -> Bool {
            guard let data = pcm.floatChannelData?[0] else { throw PipelineError.message("无法读取对话音频。") }
            frames += Int(pcm.frameLength)
            for clip in windows.append(Array(UnsafeBufferPointer(start: data, count: Int(pcm.frameLength)))) {
                try Task.checkCancellation()
                if try await analyze(clip, speakerModels: speakerModels, enrollment: enrollment, receive: receive, register: register) {
                    return true
                }
            }
            if enrollment && frames > 18 * 16_000 {
                throw PipelineError.message("没有收到足够清晰的独立人声。请在安静处连续说约五秒再试。")
            }
            return false
        }
        while let pcm = try await reader.next() {
            try Task.checkCancellation()
            if let converted = try converter.convert(pcm), try await ingest(converted) { return }
        }
        for pcm in try converter.finish() {
            if try await ingest(pcm) { return }
        }
        if let last = windows.finish() {
            _ = try await analyze(last, speakerModels: speakerModels, enrollment: enrollment, receive: receive, register: register)
        }
    }

    private func analyze(_ audio: [Float], speakerModels: DiarizerModels, enrollment: Bool,
                         receive: @MainActor (GroupUtterance) async throws -> Void,
                         register: @MainActor ([Float]) throws -> Void) async throws -> Bool {
        let diarizer = DiarizerManager(config: DiarizerConfig(minSpeechDuration: 0.35))
        diarizer.initialize(models: speakerModels)
        let intervals = try diarizer.performCompleteDiarization(audio).segments
            .filter { $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite && $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        try Task.checkCancellation()
        let ids = Set(intervals.map(\.speakerId))
        if enrollment {
            guard ids.count == 1, intervals.reduce(0.0, { $0 + Double($1.durationSeconds) }) >= 2.5,
                  let best = intervals.max(by: { $0.durationSeconds < $1.durationSeconds }),
                  let embedding = VoiceGallery.unit(best.embedding) else {
                throw PipelineError.message("登记需要一人独自说话至少三秒。请避开旁人声音后重试。")
            }
            try await register(embedding)
            return true
        }
        // Preserve the whole utterance for a single speaker, including unaligned
        // leading/trailing words. Never assign overlapping words to a known voice.
        let overlap = zip(intervals, intervals.dropFirst()).contains { a, b in
            a.speakerId != b.speakerId && a.endTimeSeconds - b.startTimeSeconds > 0.12
        }
        if ids.count <= 1 || overlap {
            let best = intervals.max { $0.durationSeconds < $1.durationSeconds }
            let vector = !overlap && (best?.durationSeconds ?? 0) >= 0.85 ? best?.embedding : nil
            try await transcribe(audio, embedding: vector, mixed: overlap, receive: receive)
        } else {
            // Partition at speaker transitions. Pad to the midpoint of gaps so no
            // audio between two diarizer boundaries is lost or transcribed twice.
            var start = 0
            for (index, part) in intervals.enumerated() {
                if index + 1 < intervals.count && intervals[index + 1].speakerId == part.speakerId { continue }
                let end = index + 1 == intervals.count ? audio.count :
                    min(audio.count, max(start, Int((part.endTimeSeconds + intervals[index + 1].startTimeSeconds) * 8000)))
                if end - start >= 1600 {
                    try await transcribe(Array(audio[start..<end]), embedding: part.durationSeconds >= 0.85 ? part.embedding : nil,
                                         mixed: false, receive: receive)
                }
                start = end
            }
        }
        return false
    }

    private func transcribe(_ audio: [Float], embedding: [Float]?, mixed: Bool,
                            receive: @MainActor (GroupUtterance) async throws -> Void) async throws {
        guard let asr else { throw PipelineError.message("多语种识别模型尚未就绪。") }
        let result = try await asr.transcribeDetailed(audio: audio)
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, result.language != "nospeech" else { return }
        let scored = result.scores.language.first
        if scored?.tag == "nospeech", (scored?.probability ?? 0) >= 0.60 { return }
        if let event = result.event, event.probability >= 0.9,
           ["BGM", "Laughter", "Applause", "Cough", "Sneeze", "Breath"].contains(event.tag) { return }
        let source: AppLanguage?
        let tag = (scored?.probability ?? 0) >= 0.60 ? scored?.tag : nil
        switch tag {
        case "zh": source = .chinese
        case "en": source = .english
        case "ja": source = .japanese
        default: source = nil
        }
        try await receive(GroupUtterance(text: text, source: source, embedding: embedding, mixed: mixed))
    }
}

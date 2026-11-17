import AVFAudio
import AudioToolbox
import UIKit

struct AudioSnapshot {
    var hasBeenChecked = false
    var inputName = "尚未检查"
    var outputName = "尚未检查"
    var farFieldSupported = false
    var farFieldEnabled = false
    var output = OutputCapability()
    var detail = "连接耳机后，点击检查音频。"
}

@MainActor
final class AudioController {
    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private var captureContinuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?
    private var synthesisContinuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?
    private var playbackCompletionContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var playbackFormat: AVAudioFormat?
    private var expectedInputUID: String?
    private var expectedOutputUID: String?
    private var selectedSource: CaptureSource = .headset
    private var captureRequired = false
    private var selectedSide: OutputSide = .both
    private var playbackGeneration = UUID()
    private var routeGeneration = UUID()
    private(set) var snapshot = AudioSnapshot()

    init() { synthesizer.usesApplicationAudioSession = true }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
    }

    func configure(source: CaptureSource) async throws -> AudioSnapshot {
        try Task.checkCancellation()
        stop()
        snapshot = AudioSnapshot()
        selectedSource = source
        captureRequired = true
        var options: AVAudioSession.CategoryOptions = []
        if source == .headset {
            guard #available(iOS 26.2, *) else {
                throw PipelineError.message("耳机远场收音需要 iOS 26.2 或更新版本。可主动选择手机麦克风备用。")
            }
            options = [.allowBluetoothHFP, .farFieldInput]
        } else {
            options = [.allowBluetoothA2DP]
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        let inputs = session.availableInputs ?? []
        let preferred: AVAudioSessionPortDescription?
        if source == .headset {
            preferred = inputs.first { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
        } else {
            preferred = inputs.first { $0.portType == .builtInMic }
        }
        guard let preferred else {
            throw PipelineError.message(source == .headset ? "没有可用的蓝牙耳机麦克风，请先连接 AirPods。" : "没有可用的手机麦克风。")
        }
        try session.setPreferredInput(preferred)
        // A preference can fail on HFP mono routes. Actual output capability is checked below.
        try? session.setPreferredOutputNumberOfChannels(2)
        for _ in 0..<12 {
            try Task.checkCancellation()
            let route = session.currentRoute
            let inputMatches = route.inputs.contains { $0.uid == preferred.uid }
            var farFieldReady = true
            if source == .headset {
                if #available(iOS 26.2, *) {
                    farFieldReady = route.inputs.first?.bluetoothMicrophoneExtension?.farFieldCapture.isEnabled == true
                }
            }
            if inputMatches && farFieldReady { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        snapshot = inspectRoute()
        guard session.currentRoute.inputs.first?.uid == preferred.uid else {
            throw PipelineError.message("系统没有启用所选麦克风，已停止。请检查音频路由后重试。")
        }
        guard snapshot.output.isHeadphones else {
            throw PipelineError.message("译文输出当前不是耳机，已阻止启动。请用音频输出按钮选择耳机。")
        }
        if source == .headset {
            guard snapshot.farFieldSupported else {
                throw PipelineError.message("当前耳机路由不支持远场收音。可主动选择手机麦克风备用。")
            }
            guard snapshot.farFieldEnabled else {
                throw PipelineError.message("耳机支持远场收音，但系统未启用，已阻止启动。")
            }
        }
        expectedInputUID = session.currentRoute.inputs.first?.uid
        expectedOutputUID = session.currentRoute.outputs.first?.uid

        try configureOutputGraph()
        snapshot.detail = source == .headset ? "耳机远场收音已实际启用" : "已使用你选择的手机麦克风"
        return snapshot
    }

    /// Replay never asks for microphone access, creates an input node, or starts a capture tap.
    func configurePlayback(side: OutputSide, onRouteFailure: @escaping @MainActor (String) -> Void) async throws -> AudioSnapshot {
        try Task.checkCancellation()
        stop()
        snapshot = AudioSnapshot()
        captureRequired = false
        selectedSide = side
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        try? session.setPreferredOutputNumberOfChannels(2)
        for _ in 0..<12 {
            try Task.checkCancellation()
            if inspectRoute().output.isHeadphones { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        snapshot = inspectRoute()
        snapshot.inputName = "未启用（仅播放译文）"
        guard snapshot.output.permits(side) else {
            throw PipelineError.message("当前输出不是耳机，或无法保证指定耳播放。重播已阻止，请检查耳机设置。")
        }
        expectedOutputUID = session.currentRoute.outputs.first?.uid
        expectedInputUID = nil
        try configureOutputGraph()
        try validateRoute()
        engine.prepare()
        try engine.start()
        try validateRoute()
        observeRoute(onFailure: onRouteFailure)
        snapshot.detail = "仅播放已生成译文，麦克风未启用"
        return snapshot
    }

    func start(side: OutputSide, onLevel: @escaping @MainActor (Float) -> Void,
               onRouteFailure: @escaping @MainActor (String) -> Void)
        throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        snapshot = inspectRoute()
        guard snapshot.output.permits(side) else {
            throw PipelineError.message("当前路由不能保证指定耳播放。请主动选择双耳，或更换支持左右声道的路由。")
        }
        selectedSide = side
        try validateRoute()
        let pair = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        captureContinuation = pair.continuation
        let format = inputFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PipelineError.message("麦克风音频格式无效。")
        }
        let meter = InputLevelMeter()
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let copied = PCMUtilities.copy(buffer) else {
                pair.continuation.finish(throwing: PipelineError.message("收音缓冲区分配失败。"))
                return
            }
            if case .dropped = pair.continuation.yield(copied) {
                pair.continuation.finish(throwing: PipelineError.message("收音处理积压，已停止，避免静默丢音。"))
            }
            if let level = meter.measure(buffer) {
                Task { @MainActor in onLevel(level) }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        try validateRoute()
        observeRoute(onFailure: onRouteFailure)
        return pair.stream
    }

    func speak(_ text: String, language: AppLanguage, rate: Float,
               onFirstBufferScheduled: (@MainActor () -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard let playbackFormat else { throw PipelineError.message("音频尚未启动。") }
        try validateRoute()
        guard let voice = AVSpeechSynthesisVoice(language: language.speechLocale) else {
            throw PipelineError.message("没有所选语言的系统语音，请在系统设置中安装对应声音。")
        }
        guard text.count <= 1800 else { throw PipelineError.oversizedSegment }
        let token = UUID()
        playbackGeneration = token
        let pair = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let completions = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        playbackCompletionContinuation = completions.continuation
        var completionIterator = completions.stream.makeAsyncIterator()
        var scheduledCount = 0
        synthesisContinuation = pair.continuation
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = min(max(rate, 0.35), 0.65)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                pair.continuation.finish(throwing: PipelineError.message("系统语音返回了不支持的音频格式。"))
                return
            }
            guard pcm.frameLength > 0 else { pair.continuation.finish(); return }
            guard let copied = PCMUtilities.copy(pcm) else {
                pair.continuation.finish(throwing: PipelineError.message("语音合成缓冲区分配失败。"))
                return
            }
            if case .dropped = pair.continuation.yield(copied) {
                pair.continuation.finish(throwing: PipelineError.message("语音合成积压，已停止播放。"))
            }
        }
        let converter = PCMConverter(to: playbackFormat)
        var emitted = false
        do {
            for try await pcm in pair.stream {
                try Task.checkCancellation()
                guard playbackGeneration == token else { throw CancellationError() }
                try validateRoute()
                guard let converted = try converter.convert(pcm) else { continue }
                try PCMUtilities.isolate(converted, side: selectedSide)
                if !emitted { onFirstBufferScheduled?() }
                emitted = true
                schedule(converted, completion: completions.continuation)
                scheduledCount += 1
                if scheduledCount >= 4 {
                    guard try await completionIterator.next() != nil else { throw CancellationError() }
                    scheduledCount -= 1
                }
            }
            for tail in try converter.finish() {
                try Task.checkCancellation()
                guard playbackGeneration == token else { throw CancellationError() }
                try validateRoute()
                try PCMUtilities.isolate(tail, side: selectedSide)
                if !emitted { onFirstBufferScheduled?() }
                emitted = true
                schedule(tail, completion: completions.continuation)
                scheduledCount += 1
                if scheduledCount >= 4 {
                    guard try await completionIterator.next() != nil else { throw CancellationError() }
                    scheduledCount -= 1
                }
            }
            while scheduledCount > 0 {
                try Task.checkCancellation()
                guard playbackGeneration == token,
                      try await completionIterator.next() != nil else { throw CancellationError() }
                scheduledCount -= 1
            }
            guard emitted else { throw PipelineError.message("系统语音没有生成可播放的声音。") }
        } catch {
            if playbackGeneration == token { stopSpeech() }
            throw error
        }
        if playbackGeneration == token {
            synthesisContinuation = nil
            playbackCompletionContinuation?.finish()
            playbackCompletionContinuation = nil
        }
    }

    func stopSpeech() {
        playbackGeneration = UUID()
        synthesisContinuation?.finish(throwing: CancellationError())
        synthesisContinuation = nil
        synthesizer.stopSpeaking(at: .immediate)
        playbackCompletionContinuation?.finish(throwing: CancellationError())
        playbackCompletionContinuation = nil
        player.stop()
    }

    func stop() {
        routeGeneration = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        stopSpeech()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        captureContinuation?.finish()
        captureContinuation = nil
        playbackFormat = nil
        expectedInputUID = nil
        expectedOutputUID = nil
        captureRequired = false
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, completion: AsyncThrowingStream<Void, Error>.Continuation) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            completion.yield(())
        }
        if !player.isPlaying { player.play() }
    }

    private func configureOutputGraph() throws {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                        channels: snapshot.output.supportsSingleEar ? 2 : 1) else {
            throw PipelineError.message("当前耳机播放格式不可用。")
        }
        playbackFormat = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func inspectRoute() -> AudioSnapshot {
        let route = session.currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        let channels = output?.channels ?? []
        let headphones: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones]
        let hardwareCount = Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
        let stereoLabels = channels.count == 2 && channels[0].channelLabel == kAudioChannelLabel_Left
            && channels[1].channelLabel == kAudioChannelLabel_Right
        var result = AudioSnapshot()
        result.hasBeenChecked = true
        result.inputName = input?.portName ?? "无输入"
        result.outputName = output?.portName ?? "无输出"
        result.output = OutputCapability(channelCount: min(channels.count, hardwareCount),
                                         hasLeftRightLabels: stereoLabels,
                                         systemMono: UIAccessibility.isMonoAudioEnabled,
                                         isHeadphones: route.outputs.count == 1 && output.map { headphones.contains($0.portType) } == true)
        if #available(iOS 26.2, *), let capability = input?.bluetoothMicrophoneExtension?.farFieldCapture {
            result.farFieldSupported = capability.isSupported
            result.farFieldEnabled = capability.isEnabled
        }
        result.detail = result.output.supportsSingleEar ? "检测到独立左右声道；物理听感仍需确认" : "当前路由未确认独立左右声道，仅可选择双耳"
        return result
    }

    private func validateRoute() throws {
        let route = session.currentRoute
        guard (!captureRequired || route.inputs.first?.uid == expectedInputUID), route.outputs.first?.uid == expectedOutputUID,
              inspectRoute().output.permits(selectedSide) else {
            throw PipelineError.message("音频路由已变化，已停止播报。请重新检查耳机。")
        }
        if captureRequired && selectedSource == .headset {
            guard inspectRoute().farFieldEnabled else {
                throw PipelineError.message("远场收音已失效，已停止。")
            }
        }
    }

    private func observeRoute(onFailure: @escaping @MainActor (String) -> Void) {
        let token = routeGeneration
        let center = NotificationCenter.default
        let names: [Notification.Name] = [AVAudioSession.routeChangeNotification,
                                          AVAudioSession.interruptionNotification,
                                          AVAudioSession.mediaServicesWereResetNotification,
                                          .AVAudioEngineConfigurationChange,
                                          UIAccessibility.monoAudioStatusDidChangeNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.routeGeneration == token, self.expectedOutputUID != nil else { return }
                    self.stopSpeech()
                    onFailure("音频设备、系统声道或音频会话发生变化，已暂停。请检查耳机后手动恢复。")
                }
            })
        }
    }
}

/// Used by one serial audio tap; throttles UI metering to roughly 10 Hz.
private final class InputLevelMeter: @unchecked Sendable {
    private var samplesSinceUpdate = 0

    func measure(_ buffer: AVAudioPCMBuffer) -> Float? {
        samplesSinceUpdate += Int(buffer.frameLength)
        guard samplesSinceUpdate >= Int(buffer.format.sampleRate / 10),
              let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return nil }
        samplesSinceUpdate = 0
        var squareSum: Float = 0
        for index in 0..<Int(buffer.frameLength) { squareSum += channel[index] * channel[index] }
        let rms = sqrt(squareSum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.00001))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

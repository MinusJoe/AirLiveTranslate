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
    private var capturedAudio: BufferedMicrophoneAudio?
    private var synthesisContinuation: SpeechPCMProducer.Stream.Continuation?
    private var playbackCompletionContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var ownsActiveSession = false
    private var expectedHardwareOutput: AVAudioFormat?
    private var hasScheduledSpeech = false
    private var tapInstalled = false
    private var playbackFormat: AVAudioFormat?
    private var expectedInputUID: String?
    private var expectedOutputUID: String?
    private var selectedSource: CaptureSource = .headset
    private var captureRequired = false
    private var requiresFarField = false
    private var partnerSpeaker = false
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

    func configure(source: CaptureSource, side: OutputSide = .both, probeStereo: Bool = false,
                   farField: Bool = true) async throws -> AudioSnapshot {
        try Task.checkCancellation()
        let originalOutput = session.currentRoute.outputs.first
        stop()
        selectedSide = side
        snapshot = AudioSnapshot()
        selectedSource = source
        captureRequired = true
        requiresFarField = source == .headset && farField
        var options: AVAudioSession.CategoryOptions = []
        if requiresFarField {
            guard #available(iOS 26.2, *) else {
                throw PipelineError.message("耳机远场收音需要 iOS 26.2 或更新版本。可主动选择手机麦克风备用。")
            }
            options = [.allowBluetoothHFP, .farFieldInput]
        } else if source == .headset {
            options = [.allowBluetoothHFP]
        } else {
            options = [.allowBluetoothA2DP]
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        ownsActiveSession = true
        let bluetoothHint: RoutePortIdentity? = originalOutput.flatMap { port in
            source == .headset && Self.isBluetooth(port) ? Self.identity(port) : nil
        }
        var negotiation = CaptureRouteNegotiation(selectedHeadphones: bluetoothHint)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var triedStereo = false
        var preferenceError: String?
        repeat {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let route = session.currentRoute
            let inputs = (session.availableInputs ?? []).filter { Self.accepts($0, source: source) }
            let active = route.inputs.count == 1 ? route.inputs.first : nil
            let matched = active.flatMap { Self.accepts($0, source: source) ? Self.identity($0) : nil }
            let output = route.outputs.count == 1 ? route.outputs.first : nil
            let selected = negotiation.choose(available: inputs.map(Self.identity), active: matched,
                                              output: output.map(Self.identity))
            if let selected, let port = inputs.first(where: { $0.uid == selected.uid }),
               negotiation.shouldRequest(selected.uid, activeUID: matched?.uid, now: now) {
                do { try session.setPreferredInput(port); preferenceError = nil }
                catch { preferenceError = error.localizedDescription }
            }
            let privateOutput = output.flatMap { Self.isHeadphone($0) ? $0.uid : nil }
            if let selected, matched?.uid == selected.uid, privateOutput != nil,
               (side != .both || probeStereo), !triedStereo {
                triedStereo = true
                requestStereoIfSupported()
            }
            let ok = (!requiresFarField || Self.farFieldEnabled(active)) &&
                (side == .both || (privateOutput != nil && inspectRoute().output.permits(side)))
            if negotiation.ready(input: matched?.uid, output: privateOutput, capabilitiesOK: ok, now: now) {
                expectedInputUID = matched?.uid
                expectedOutputUID = privateOutput
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        try Task.checkCancellation()
        snapshot = inspectRoute()
        if expectedInputUID == nil {
            let reason: String
            if negotiation.target == nil {
                reason = "无法唯一确定所选麦克风。请在系统音频输出中选中所戴耳机，再点“检查耳机”。"
            } else if session.currentRoute.inputs.first?.uid != negotiation.target?.uid {
                reason = "系统未切换到“" + (negotiation.target?.name ?? source.name) + "”。"
            } else if !snapshot.output.isHeadphones {
                reason = "请将系统音频输出切换到耳机。"
            } else if requiresFarField && !snapshot.farFieldEnabled {
                reason = snapshot.farFieldSupported ? "系统尚未启用耳机远场收音。" : "当前耳机路由未提供远场收音。"
            } else if !snapshot.output.permits(side) {
                reason = "当前录放音路由未提供指定耳侧，请在设置中选择双耳后重试。"
            } else {
                reason = "麦克风或耳机路由尚未稳定，请重新检查。"
            }
            let details = [reason, routeSummary(), preferenceError].compactMap { $0 }.joined(separator: " ")
            snapshot.detail = details
            throw PipelineError.message(details)
        }
        try validateRoute()
        try configureOutputGraph()
        snapshot.detail = requiresFarField ? "耳机远场收音已实际启用" : "所选麦克风已启用"
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
        ownsActiveSession = true
        var triedStereo = false
        var previousOutput: String?
        for _ in 0..<50 {
            try Task.checkCancellation()
            let route = session.currentRoute
            if route.outputs.count == 1, let port = route.outputs.first, Self.isHeadphone(port) {
                if side != .both && !triedStereo {
                    triedStereo = true
                    requestStereoIfSupported()
                }
                if previousOutput == port.uid && inspectRoute().output.permits(side) { break }
                previousOutput = port.uid
            } else {
                previousOutput = nil
            }
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
        throws -> BufferedMicrophoneAudio {
        snapshot = inspectRoute()
        guard snapshot.output.permits(side) else {
            throw PipelineError.message("当前路由不能保证指定耳播放。请主动选择双耳，或更换支持左右声道的路由。")
        }
        selectedSide = side
        try validateRoute()
        let format = inputFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PipelineError.message("麦克风音频格式无效。")
        }
        let capture = BufferedMicrophoneAudio(format: format)
        capturedAudio = capture
        let meter = InputLevelMeter()
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let error = capture.append(buffer) {
                Task { @MainActor in onRouteFailure(error.localizedDescription) }
                return
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
        return capture
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
        // Bound producer lead by duration (512 × 80 ms in live mode), independent of
        // the often tiny fragments delivered by AVSpeechSynthesizer.write.
        let pair = SpeechPCMProducer.Stream.makeStream(bufferingPolicy: .bufferingOldest(512))
        let completions = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        playbackCompletionContinuation = completions.continuation
        synthesisContinuation = pair.continuation
        var completionIterator = completions.stream.makeAsyncIterator()
        let producer = SpeechPCMProducer(format: playbackFormat, side: selectedSide, live: captureRequired,
                                         continuation: pair.continuation)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = min(max(rate, 0.35), 0.65)
        synthesizer.write(utterance, toBufferCallback: producer.receive)
        var inFlight = 0
        var started = false
        var scheduledFinalBuffer = false
        do {
            for try await packet in pair.stream {
                try Task.checkCancellation()
                guard playbackGeneration == token else { throw CancellationError() }
                try validateRoute()
                player.scheduleBuffer(packet.buffer, completionCallbackType: packet.completionType) { _ in
                    completions.continuation.yield(())
                }
                if packet.isFinal { scheduledFinalBuffer = true }
                hasScheduledSpeech = true
                if !player.isPlaying { player.play() }
                if !started {
                    started = true
                    onFirstBufferScheduled?()
                }
                inFlight += 1
                if inFlight == 4 {
                    guard try await completionIterator.next() != nil else { throw CancellationError() }
                    inFlight -= 1
                }
            }
            while inFlight > 0 {
                try Task.checkCancellation()
                guard playbackGeneration == token,
                      try await completionIterator.next() != nil else { throw CancellationError() }
                inFlight -= 1
            }
            try Task.checkCancellation()
            guard playbackGeneration == token else { throw CancellationError() }
            guard scheduledFinalBuffer else { throw PipelineError.message("语音播放未完成。") }
        } catch {
            if playbackGeneration == token { stopSpeech() }
            throw error
        }
        if playbackGeneration == token {
            hasScheduledSpeech = false
            synthesisContinuation = nil
            playbackCompletionContinuation?.finish()
            playbackCompletionContinuation = nil
        }
    }

    func stopSpeech() {
        hasScheduledSpeech = false
        playbackGeneration = UUID()
        synthesisContinuation?.finish(throwing: CancellationError())
        synthesisContinuation = nil
        synthesizer.stopSpeaking(at: .immediate)
        playbackCompletionContinuation?.finish(throwing: CancellationError())
        playbackCompletionContinuation = nil
        player.stop()
    }

    func finishTurnCapture() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        capturedAudio?.finishInput()
        capturedAudio = nil
        stop()
    }

    /// Public playback is a distinct, explicit operation after capture has stopped.
    func configurePartnerSpeaker(onFailure: @escaping @MainActor (String) -> Void) async throws {
        try Task.checkCancellation()
        stop()
        selectedSide = .both
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
        ownsActiveSession = true
        partnerSpeaker = true
        try session.overrideOutputAudioPort(.speaker)
        for _ in 0..<20 {
            try Task.checkCancellation()
            if session.currentRoute.outputs.count == 1, session.currentRoute.outputs.first?.portType == .builtInSpeaker { break }
            try await Task.sleep(for: .milliseconds(75))
        }
        try Task.checkCancellation()
        expectedOutputUID = session.currentRoute.outputs.first?.uid
        try validateRoute()
        snapshot = inspectRoute()
        try configureOutputGraph()
        engine.prepare()
        try engine.start()
        try validateRoute()
        observeRoute(onFailure: onFailure)
    }

    /// A conversational handoff requires the last speaker buffer to finish and
    /// the public override to be cleared. The listener then negotiates its own
    /// private route before enabling the microphone.
    func releasePartnerSpeaker() throws {
        guard partnerSpeaker, engine.isRunning else { throw PipelineError.message("手机外放已中断，请点听对方重新收听。") }
        try validateRoute()
        try session.overrideOutputAudioPort(.none)
        partnerSpeaker = false
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
        capturedAudio?.discard()
        capturedAudio = nil
        playbackFormat = nil
        expectedHardwareOutput = nil
        expectedInputUID = nil
        expectedOutputUID = nil
        captureRequired = false
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        if partnerSpeaker {
            try? session.overrideOutputAudioPort(.none)
            partnerSpeaker = false
        }
        if ownsActiveSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            ownsActiveSession = false
        }
    }

    private func configureOutputGraph() throws {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                        channels: snapshot.output.supportsSingleEar ? 2 : 1) else {
            throw PipelineError.message("当前耳机播放格式不可用。")
        }
        expectedHardwareOutput = hardware
        playbackFormat = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func inspectRoute() -> AudioSnapshot {
        let route = session.currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        let channels = output?.channels ?? []
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
                                         isHeadphones: route.outputs.count == 1 && output.map(Self.isHeadphone) == true)
        if #available(iOS 26.2, *), let capability = input?.bluetoothMicrophoneExtension?.farFieldCapture {
            result.farFieldSupported = capability.isSupported
            result.farFieldEnabled = capability.isEnabled
        }
        result.detail = result.output.supportsSingleEar ? "检测到独立左右声道；物理听感仍需确认" : "当前路由未确认独立左右声道，仅可选择双耳"
        return result
    }

    private static func identity(_ port: AVAudioSessionPortDescription) -> RoutePortIdentity {
        RoutePortIdentity(uid: port.uid, name: port.portName)
    }

    private static func isBluetooth(_ port: AVAudioSessionPortDescription) -> Bool {
        [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains(port.portType)
    }

    private static func isHeadphone(_ port: AVAudioSessionPortDescription) -> Bool {
        isBluetooth(port) || port.portType == .headphones
    }

    private static func accepts(_ port: AVAudioSessionPortDescription, source: CaptureSource) -> Bool {
        source == .phone ? port.portType == .builtInMic : [.bluetoothHFP, .bluetoothLE].contains(port.portType)
    }

    private static func farFieldEnabled(_ port: AVAudioSessionPortDescription?) -> Bool {
        if #available(iOS 26.2, *) { return port?.bluetoothMicrophoneExtension?.farFieldCapture.isEnabled == true }
        return false
    }

    private func requestStereoIfSupported() {
        if session.maximumOutputNumberOfChannels >= 2 && session.outputNumberOfChannels != 2 {
            try? session.setPreferredOutputNumberOfChannels(2)
        }
    }

    private func routeSummary() -> String {
        let route = session.currentRoute
        func names(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.isEmpty ? "无" : ports.map { "\($0.portName)（\($0.portType.rawValue)）" }.joined(separator: "、")
        }
        return "实际输入：\(names(route.inputs))，输出：\(names(route.outputs))。"
    }

    private func validateRoute() throws {
        let route = session.currentRoute
        if partnerSpeaker {
            guard !captureRequired, session.category == .playAndRecord, route.outputs.count == 1,
                  let port = route.outputs.first, port.portType == .builtInSpeaker, port.uid == expectedOutputUID else {
                throw PipelineError.message("手机扬声器不可用。可以把屏幕上的译文给对方看。")
            }
            return
        }
        if captureRequired {
            guard session.category == .playAndRecord, route.inputs.count == 1, let input = route.inputs.first,
                  input.uid == expectedInputUID, Self.accepts(input, source: selectedSource) else {
                throw PipelineError.message("当前麦克风或录音模式与启动时不一致。" + routeSummary())
            }
        } else if session.category != .playback {
            throw PipelineError.message("系统已切换音频播放模式。" + routeSummary())
        }
        guard let output = route.outputs.first, route.outputs.count == 1,
              output.uid == expectedOutputUID, Self.isHeadphone(output) else {
            throw PipelineError.message("耳机已断开或输出设备已切换。" + routeSummary())
        }
        if selectedSide != .both && !inspectRoute().output.permits(selectedSide) {
            throw PipelineError.message("当前耳机声道无法单独向所选耳侧播放。请检查声道或选择双耳。")
        }
        if captureRequired && requiresFarField && !Self.farFieldEnabled(route.inputs.first) {
            throw PipelineError.message("系统已停用耳机远场收音。" + routeSummary())
        }
    }

    private func observeRoute(onFailure: @escaping @MainActor (String) -> Void) {
        let token = routeGeneration
        let center = NotificationCenter.default
        let names: [Notification.Name] = [AVAudioSession.routeChangeNotification,
                                         AVAudioSession.interruptionNotification,
                                         AVAudioSession.mediaServicesWereLostNotification,
                                         AVAudioSession.mediaServicesWereResetNotification,
                                         .AVAudioEngineConfigurationChange,
                                         UIAccessibility.monoAudioStatusDidChangeNotification]
        for name in names {
            let object: AnyObject? = name == .AVAudioEngineConfigurationChange ? engine :
                (name == UIAccessibility.monoAudioStatusDidChangeNotification ? nil : session)
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
                let signal: AudioSessionSignal
                switch name {
                case AVAudioSession.interruptionNotification:
                    let value = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                    signal = value == AVAudioSession.InterruptionType.ended.rawValue ? .interruptionEnded : .interruptionBegan
                case AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.mediaServicesWereLostNotification:
                    signal = .servicesLost
                case .AVAudioEngineConfigurationChange: signal = .engineChanged
                case UIAccessibility.monoAudioStatusDidChangeNotification: signal = .monoChanged
                default: signal = .routeChanged
                }
                // Leave the notification callback before tearing down the engine.
                Task { @MainActor in
                    guard let self, self.routeGeneration == token else { return }
                    var reason = signal.immediateStop
                    if reason == nil {
                        var invalid: String?
                        do { try self.validateRoute() } catch { invalid = error.localizedDescription }
                        let running = self.engine.isRunning
                        let formatsOK = running && self.expectedHardwareOutput == self.engine.outputNode.outputFormat(forBus: 0)
                            && (!self.captureRequired || self.capturedAudio?.format == self.inputFormat)
                        reason = signal.pauseReason(routeFailure: invalid, engineRunning: running, formatMatches: formatsOK)
                        if reason == nil, signal == .engineChanged, self.hasScheduledSpeech, !self.player.isPlaying {
                            reason = "系统重新配置音频引擎时中止了当前播报。"
                        }
                    }
                    if let reason {
                        self.snapshot.inputName = self.session.currentRoute.inputs.first?.portName ?? "无输入"
                        self.snapshot.outputName = self.session.currentRoute.outputs.first?.portName ?? "无输出"
                        self.snapshot.detail = reason
                        self.stopSpeech()
                        onFailure(reason + " 已暂停，请手动恢复。")
                    }
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

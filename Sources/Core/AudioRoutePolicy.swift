import Foundation

struct RoutePortIdentity: Equatable {
    let uid: String
    let name: String
}

/// The caller supplies only inputs of the requested kind. Once selected, never
/// jump to another device simply because its microphone has become available.
struct CaptureRouteNegotiation {
    let selectedHeadphones: RoutePortIdentity?
    private(set) var target: RoutePortIdentity?
    private var lastRequestUID: String?
    private var attempts = 0
    private var requestedAt: TimeInterval = 0
    private var stableInput: String?
    private var stableOutput: String?
    private var stableSince: TimeInterval = 0

    init(selectedHeadphones: RoutePortIdentity?) {
        self.selectedHeadphones = selectedHeadphones
    }

    mutating func choose(available: [RoutePortIdentity], active: RoutePortIdentity?,
                         output: RoutePortIdentity?) -> RoutePortIdentity? {
        if let pinned = target {
            if active?.uid == pinned.uid { return active }
            if let active, active.name == pinned.name, output?.name == pinned.name,
               available.filter({ $0.name == pinned.name }).count <= 1 {
                target = active
                return active
            }
            if let exact = available.first(where: { $0.uid == pinned.uid }) { return exact }
            // HFP/LE renegotiation can replace a port object. Use a replacement
            // only if its name is unique and the selected headset is still the output.
            if let output, output.name == pinned.name {
                let same = available.filter { $0.name == pinned.name }
                if same.count == 1 { target = same[0]; return target }
            }
            return nil
        }
        if let selectedHeadphones {
            if let same = available.first(where: { $0.uid == selectedHeadphones.uid }) { target = same }
            else {
                let named = available.filter { $0.name == selectedHeadphones.name }
                if named.count == 1 { target = named[0] }
                else if named.isEmpty, let active, output?.uid == selectedHeadphones.uid,
                        active.name == selectedHeadphones.name { target = active }
            }
        } else if let active { target = active }
        else if let output {
            let named = available.filter { $0.name == output.name }
            if named.count == 1 { target = named[0] }
        }
        if target == nil, selectedHeadphones == nil, available.count == 1 { target = available[0] }
        return target
    }

    mutating func shouldRequest(_ uid: String, activeUID: String?, now: TimeInterval) -> Bool {
        guard uid != activeUID else { return false }
        if uid != lastRequestUID { attempts = 0 }
        guard attempts == 0 || (attempts < 2 && now - requestedAt >= 1) else { return false }
        lastRequestUID = uid
        requestedAt = now
        attempts += 1
        return true
    }

    mutating func ready(input: String?, output: String?, capabilitiesOK: Bool, now: TimeInterval) -> Bool {
        guard let target, let input, target.uid == input, let output, capabilitiesOK else {
            stableInput = nil; stableOutput = nil
            return false
        }
        if stableInput != input || stableOutput != output {
            stableInput = input; stableOutput = output; stableSince = now
        }
        return now - stableSince >= 0.20
    }
}

enum AudioSessionSignal {
    case routeChanged, engineChanged, monoChanged, interruptionBegan, interruptionEnded, servicesLost

    var immediateStop: String? {
        switch self {
        case .interruptionBegan: return "音频会话被来电或其他系统音频中断。"
        case .servicesLost: return "系统音频服务已中断或重置。"
        default: return nil
        }
    }

    func pauseReason(routeFailure: String?, engineRunning: Bool, formatMatches: Bool) -> String? {
        if let immediateStop { return immediateStop }
        if let routeFailure { return routeFailure }
        if !engineRunning { return "系统已停止音频引擎。" }
        if !formatMatches { return "系统已改变当前音频采样率或声道，需要重建音频连接。" }
        return nil
    }
}

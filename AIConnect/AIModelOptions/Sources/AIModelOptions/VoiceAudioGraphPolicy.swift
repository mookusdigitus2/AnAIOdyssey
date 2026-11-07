// SPDX-License-Identifier: MIT
import Foundation

/// Hardware format the duplex graph must adopt after a route change.
///
/// Sample rate and channel count are read fresh from the input / output node.
/// A cached or hard-coded format must never be passed to `installTap` or
/// `connect(..., format:)` — that trips the AVAudioEngine fatal
/// `format.sampleRate == hwFormat.sampleRate` (or a channel-count mismatch)
/// when the car kit switches the session to 8 / 16 kHz HFP mono.
public struct VoiceHardwareFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public var route: VoiceOutputRouteKind

    public init(sampleRate: Double, channelCount: Int, route: VoiceOutputRouteKind) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.route = route
    }

    public var isValid: Bool {
        sampleRate > 0 && channelCount > 0
    }

    public static let speaker48k = VoiceHardwareFormat(
        sampleRate: 48_000,
        channelCount: 1,
        route: .speaker
    )
    public static let hfp16kMono = VoiceHardwareFormat(
        sampleRate: 16_000,
        channelCount: 1,
        route: .bluetoothHFP
    )
    public static let hfp8kMono = VoiceHardwareFormat(
        sampleRate: 8_000,
        channelCount: 1,
        route: .bluetoothHFP
    )
    public static let a2dp48kStereo = VoiceHardwareFormat(
        sampleRate: 48_000,
        channelCount: 2,
        route: .headphones
    )

    /// True when `candidate` would survive `installTap` / `connect` against this hardware.
    public func matchesHardware(_ candidate: VoiceHardwareFormat?) -> Bool {
        guard let candidate, candidate.isValid else { return false }
        return candidate.sampleRate == sampleRate && candidate.channelCount == channelCount
    }
}

/// Lifecycle of the shared `AVAudioEngine` graph.
public enum VoiceAudioGraphPhase: String, Sendable, Equatable {
    case idle
    case running
    case interrupted
    case rebuilding
}

/// External events that mutate the graph. Route / configuration bursts are
/// coalesced before `reduce` so a car kit connecting does not install a tap twice.
public enum VoiceAudioGraphEvent: String, Sendable, Equatable {
    case start
    case routeChanged
    case configurationChanged
    case interruptionBegan
    case interruptionEnded
    case stop
}

/// Ordered mutations the engine must perform. Voice processing is applied only
/// while the engine is stopped; the tap is installed once after start, using
/// the incoming hardware format.
public enum VoiceAudioGraphAction: String, Sendable, Equatable {
    case activateSession
    case stopEngine
    case removeTap
    case applyVoiceProcessing
    case reconnectNodes
    case startEngine
    case installTap
    case recreateRecognizer
    case dropPendingPlayback
    case disableSpeechBargeIn
    case showAudioIssue
    case clearAudioIssue
    case deactivateSession
}

/// Short, non-blocking copy shown when audio recovers instead of crashing.
public enum VoiceAudioIssueMessage {
    public static let voiceProcessingUnavailable = "Car audio connected. Tap to interrupt if you need to cut in."
    public static let sessionActivationFailed = "Couldn't start the microphone. Tap to retry."
    public static let formatUnavailable = "Waiting for the car audio to finish connecting…"
    public static let graphRebuildFailed = "Audio route changed. Recovering…"
}

/// Session category / mode / options the live `VoiceAudioSession` must set.
///
/// `.allowBluetooth` is HFP (car kits / SCO). `.allowBluetoothA2DP` keeps
/// high-quality output when the route is headphones. `.defaultToSpeaker`
/// covers the built-in speaker. `setActive` is never force-tried.
public enum VoiceAudioSessionPolicy {
    public static let requiredCategory = "playAndRecord"
    public static let requiredMode = "voiceChat"
    public static let requiredOptions: Set<String> = [
        "allowBluetooth",
        "allowBluetoothA2DP",
        "defaultToSpeaker",
    ]

    public static func allowsForceTrySetActive() -> Bool { false }

    public static func containsRequiredOptions(_ options: Set<String>) -> Bool {
        requiredOptions.isSubset(of: options)
    }
}

/// Observable graph state. The Linux simulator and the on-device engine share
/// this shape so tests can assert the same invariants the car crash hits.
public struct VoiceAudioGraphSnapshot: Sendable, Equatable {
    public var phase: VoiceAudioGraphPhase
    public var format: VoiceHardwareFormat?
    public var tapInstalled: Bool
    public var tapFormat: VoiceHardwareFormat?
    public var engineRunning: Bool
    public var voiceProcessingEnabled: Bool
    public var voiceProcessingFailed: Bool
    public var speechBargeInEnabled: Bool
    public var recognizerGeneration: Int
    public var pendingPlayback: Bool
    public var isListening: Bool
    public var lastIssue: String?
    public var rebuildGeneration: Int
    public var tapInstallCount: Int
    public var tapRemoveCount: Int
    public var voiceProcessingAppliedWhileRunning: Int
    public var usedStaleFormat: Bool

    public init(
        phase: VoiceAudioGraphPhase = .idle,
        format: VoiceHardwareFormat? = nil,
        tapInstalled: Bool = false,
        tapFormat: VoiceHardwareFormat? = nil,
        engineRunning: Bool = false,
        voiceProcessingEnabled: Bool = false,
        voiceProcessingFailed: Bool = false,
        speechBargeInEnabled: Bool = false,
        recognizerGeneration: Int = 0,
        pendingPlayback: Bool = false,
        isListening: Bool = false,
        lastIssue: String? = nil,
        rebuildGeneration: Int = 0,
        tapInstallCount: Int = 0,
        tapRemoveCount: Int = 0,
        voiceProcessingAppliedWhileRunning: Int = 0,
        usedStaleFormat: Bool = false
    ) {
        self.phase = phase
        self.format = format
        self.tapInstalled = tapInstalled
        self.tapFormat = tapFormat
        self.engineRunning = engineRunning
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.voiceProcessingFailed = voiceProcessingFailed
        self.speechBargeInEnabled = speechBargeInEnabled
        self.recognizerGeneration = recognizerGeneration
        self.pendingPlayback = pendingPlayback
        self.isListening = isListening
        self.lastIssue = lastIssue
        self.rebuildGeneration = rebuildGeneration
        self.tapInstallCount = tapInstallCount
        self.tapRemoveCount = tapRemoveCount
        self.voiceProcessingAppliedWhileRunning = voiceProcessingAppliedWhileRunning
        self.usedStaleFormat = usedStaleFormat
    }

    public static func idle() -> VoiceAudioGraphSnapshot {
        VoiceAudioGraphSnapshot()
    }
}

public struct VoiceAudioGraphStep: Sendable, Equatable {
    public var actions: [VoiceAudioGraphAction]
    public var snapshot: VoiceAudioGraphSnapshot

    public init(actions: [VoiceAudioGraphAction], snapshot: VoiceAudioGraphSnapshot) {
        self.actions = actions
        self.snapshot = snapshot
    }
}

/// Simulated duplex-graph state machine.
///
/// Car Bluetooth (HFP / CarPlay) arrives as a route + configuration change
/// while the engine is already running with voice processing. The only safe
/// sequence is: stop → remove tap → apply VP while stopped (catch) →
/// reconnect with the *incoming* hardware format → start → install tap once
/// → recreate the speech request. Speech barge-in turns off on HFP or when
/// VP throws; the UI shows a short message instead of asserting.
public enum VoiceAudioGraphPolicy {
    /// Collapse a burst of route / configuration notifications into one rebuild.
    public static func coalesce(_ events: [VoiceAudioGraphEvent]) -> [VoiceAudioGraphEvent] {
        var result: [VoiceAudioGraphEvent] = []
        for event in events {
            switch event {
            case .routeChanged, .configurationChanged:
                if let last = result.last, last == .routeChanged || last == .configurationChanged {
                    result[result.count - 1] = .configurationChanged
                } else {
                    result.append(event)
                }
            case .interruptionEnded:
                if result.last == .interruptionBegan {
                    result.removeLast()
                } else {
                    result.append(event)
                }
            default:
                result.append(event)
            }
        }
        return result
    }

    public static func reduce(
        _ snapshot: VoiceAudioGraphSnapshot,
        event: VoiceAudioGraphEvent,
        incomingFormat: VoiceHardwareFormat?,
        voiceProcessingAvailable: Bool = true,
        voiceProcessingThrows: Bool = false
    ) -> VoiceAudioGraphStep {
        let actions: [VoiceAudioGraphAction]
        switch event {
        case .start:
            actions = startActions(from: snapshot, incomingFormat: incomingFormat)
        case .routeChanged, .configurationChanged:
            actions = rebuildActions(from: snapshot, incomingFormat: incomingFormat, showIssue: true)
        case .interruptionBegan:
            actions = interruptionBeganActions(from: snapshot)
        case .interruptionEnded:
            actions = rebuildActions(from: snapshot, incomingFormat: incomingFormat, showIssue: false)
        case .stop:
            actions = stopActions(from: snapshot)
        }

        let next = apply(
            actions: actions,
            to: snapshot,
            incomingFormat: incomingFormat,
            voiceProcessingAvailable: voiceProcessingAvailable,
            voiceProcessingThrows: voiceProcessingThrows
        )
        return VoiceAudioGraphStep(actions: actions, snapshot: next)
    }

    /// Apply the same action list the on-device engine walks.
    public static func apply(
        actions: [VoiceAudioGraphAction],
        to snapshot: VoiceAudioGraphSnapshot,
        incomingFormat: VoiceHardwareFormat?,
        voiceProcessingAvailable: Bool,
        voiceProcessingThrows: Bool
    ) -> VoiceAudioGraphSnapshot {
        var state = snapshot
        for action in actions {
            switch action {
            case .activateSession:
                break
            case .stopEngine:
                state.engineRunning = false
                if state.phase == .running || state.phase == .rebuilding {
                    state.phase = .rebuilding
                }
            case .removeTap:
                if state.tapInstalled {
                    state.tapRemoveCount += 1
                    state.tapInstalled = false
                    state.tapFormat = nil
                }
            case .applyVoiceProcessing:
                if state.engineRunning {
                    state.voiceProcessingAppliedWhileRunning += 1
                }
                let route = incomingFormat?.route ?? state.format?.route ?? .unknown
                let allowedOnRoute = VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: route)
                if voiceProcessingThrows || !allowedOnRoute {
                    state.voiceProcessingEnabled = false
                    state.voiceProcessingFailed = voiceProcessingThrows || !allowedOnRoute
                } else {
                    let desired = VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(
                        route: route,
                        voiceProcessingAvailable: voiceProcessingAvailable
                    )
                    state.voiceProcessingEnabled = desired
                    state.voiceProcessingFailed = desired && !voiceProcessingAvailable
                }
            case .reconnectNodes:
                if let incomingFormat {
                    if !incomingFormat.isValid {
                        state.usedStaleFormat = true
                    }
                    state.format = incomingFormat
                } else {
                    state.usedStaleFormat = true
                }
            case .startEngine:
                if let format = incomingFormat ?? state.format, format.isValid {
                    state.engineRunning = true
                    state.phase = .running
                } else {
                    state.engineRunning = false
                    state.phase = .idle
                }
            case .installTap:
                if state.tapInstalled {
                    // Installing twice on the same bus is the other fatal assertion.
                    state.usedStaleFormat = true
                }
                if let format = incomingFormat ?? state.format, format.isValid, !state.tapInstalled {
                    state.tapInstalled = true
                    state.tapFormat = format
                    state.tapInstallCount += 1
                }
            case .recreateRecognizer:
                state.recognizerGeneration += 1
            case .dropPendingPlayback:
                state.pendingPlayback = false
            case .disableSpeechBargeIn:
                state.speechBargeInEnabled = false
            case .showAudioIssue, .clearAudioIssue:
                break
            case .deactivateSession:
                state.engineRunning = false
                state.phase = .idle
                state.voiceProcessingEnabled = false
                state.voiceProcessingFailed = false
            }
        }

        if let format = state.format {
            state.speechBargeInEnabled = VoiceEchoPolicy.allowsSpeechBargeIn(
                route: format.route,
                acousticEchoCancellationAvailable: state.voiceProcessingEnabled && !state.voiceProcessingFailed
            )
            if format.route == .bluetoothHFP || state.voiceProcessingFailed {
                state.speechBargeInEnabled = false
            }
        }

        if actions.contains(.showAudioIssue) || state.voiceProcessingFailed {
            state.lastIssue = issueMessage(
                format: incomingFormat ?? state.format,
                voiceProcessingFailed: state.voiceProcessingFailed,
                formatValid: incomingFormat?.isValid ?? state.format?.isValid ?? false
            )
        } else if actions.contains(.clearAudioIssue) {
            state.lastIssue = nil
        }
        return state
    }

    /// `installTap` / `connect` may use `tap` only when it matches hardware.
    public static func tapFormatMustMatchHardware(
        tap: VoiceHardwareFormat?,
        hardware: VoiceHardwareFormat
    ) -> Bool {
        hardware.matchesHardware(tap)
    }

    /// TTS PCM is converted with `AVAudioConverter` whenever the mixer differs.
    public static func ttsNeedsConversion(
        sourceSampleRate: Double,
        sourceChannels: Int,
        mixer: VoiceHardwareFormat
    ) -> Bool {
        sourceSampleRate != mixer.sampleRate || sourceChannels != mixer.channelCount
    }

    public static func shouldReuseRecognizer(
        previousFormat: VoiceHardwareFormat?,
        incomingFormat: VoiceHardwareFormat
    ) -> Bool {
        incomingFormat.matchesHardware(previousFormat)
    }

    // MARK: - Action lists

    private static func startActions(
        from snapshot: VoiceAudioGraphSnapshot,
        incomingFormat: VoiceHardwareFormat?
    ) -> [VoiceAudioGraphAction] {
        var actions: [VoiceAudioGraphAction] = [.activateSession]
        if snapshot.engineRunning {
            actions.append(.stopEngine)
        }
        if snapshot.tapInstalled {
            actions.append(.removeTap)
        }
        actions.append(.applyVoiceProcessing)
        actions.append(.reconnectNodes)
        if incomingFormat?.isValid == true {
            actions.append(.startEngine)
            actions.append(.installTap)
            actions.append(.recreateRecognizer)
            actions.append(.clearAudioIssue)
        } else {
            actions.append(.showAudioIssue)
        }
        if incomingFormat?.route == .bluetoothHFP {
            actions.append(.disableSpeechBargeIn)
        }
        return actions
    }

    private static func rebuildActions(
        from snapshot: VoiceAudioGraphSnapshot,
        incomingFormat: VoiceHardwareFormat?,
        showIssue: Bool
    ) -> [VoiceAudioGraphAction] {
        var actions: [VoiceAudioGraphAction] = []
        if snapshot.engineRunning {
            actions.append(.stopEngine)
        }
        if snapshot.tapInstalled {
            actions.append(.removeTap)
        }
        if snapshot.pendingPlayback {
            actions.append(.dropPendingPlayback)
        }
        actions.append(.applyVoiceProcessing)
        actions.append(.reconnectNodes)
        if incomingFormat?.isValid == true {
            actions.append(.startEngine)
            actions.append(.installTap)
            if snapshot.isListening || snapshot.recognizerGeneration > 0 {
                actions.append(.recreateRecognizer)
            }
        }
        if incomingFormat?.route == .bluetoothHFP {
            actions.append(.disableSpeechBargeIn)
        }
        if showIssue {
            actions.append(.showAudioIssue)
        }
        return actions
    }

    private static func interruptionBeganActions(
        from snapshot: VoiceAudioGraphSnapshot
    ) -> [VoiceAudioGraphAction] {
        var actions: [VoiceAudioGraphAction] = []
        if snapshot.engineRunning {
            actions.append(.stopEngine)
        }
        if snapshot.tapInstalled {
            actions.append(.removeTap)
        }
        if snapshot.pendingPlayback {
            actions.append(.dropPendingPlayback)
        }
        return actions
    }

    private static func stopActions(from snapshot: VoiceAudioGraphSnapshot) -> [VoiceAudioGraphAction] {
        var actions: [VoiceAudioGraphAction] = []
        if snapshot.engineRunning {
            actions.append(.stopEngine)
        }
        if snapshot.tapInstalled {
            actions.append(.removeTap)
        }
        if snapshot.pendingPlayback {
            actions.append(.dropPendingPlayback)
        }
        actions.append(.deactivateSession)
        actions.append(.clearAudioIssue)
        return actions
    }

    private static func issueMessage(
        format: VoiceHardwareFormat?,
        voiceProcessingFailed: Bool,
        formatValid: Bool
    ) -> String {
        if !formatValid {
            return VoiceAudioIssueMessage.formatUnavailable
        }
        if voiceProcessingFailed || format?.route == .bluetoothHFP {
            return VoiceAudioIssueMessage.voiceProcessingUnavailable
        }
        return VoiceAudioIssueMessage.graphRebuildFailed
    }
}

/// Walks events through the policy and records invariant counters.
public struct VoiceAudioGraphSimulator: Sendable, Equatable {
    public var snapshot: VoiceAudioGraphSnapshot
    public var voiceProcessingAvailable: Bool
    public var voiceProcessingThrows: Bool

    public init(
        snapshot: VoiceAudioGraphSnapshot = .idle(),
        voiceProcessingAvailable: Bool = true,
        voiceProcessingThrows: Bool = false
    ) {
        self.snapshot = snapshot
        self.voiceProcessingAvailable = voiceProcessingAvailable
        self.voiceProcessingThrows = voiceProcessingThrows
    }

    @discardableResult
    public mutating func apply(
        _ event: VoiceAudioGraphEvent,
        format: VoiceHardwareFormat?
    ) -> VoiceAudioGraphStep {
        let step = VoiceAudioGraphPolicy.reduce(
            snapshot,
            event: event,
            incomingFormat: format,
            voiceProcessingAvailable: voiceProcessingAvailable,
            voiceProcessingThrows: voiceProcessingThrows
        )
        snapshot = step.snapshot
        snapshot.rebuildGeneration += event == .routeChanged || event == .configurationChanged || event == .start
            ? 1 : 0
        return step
    }

    /// Rapid route / config bursts become a single rebuild (one tap install).
    @discardableResult
    public mutating func applyRapid(
        _ events: [VoiceAudioGraphEvent],
        format: VoiceHardwareFormat?
    ) -> VoiceAudioGraphStep {
        let coalesced = VoiceAudioGraphPolicy.coalesce(events)
        var last = VoiceAudioGraphStep(actions: [], snapshot: snapshot)
        for event in coalesced {
            last = apply(event, format: format)
        }
        return last
    }
}

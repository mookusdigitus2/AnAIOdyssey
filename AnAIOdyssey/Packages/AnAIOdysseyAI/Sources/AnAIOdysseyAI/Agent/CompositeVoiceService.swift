// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AIConnect
import AIConnectVoice
import AIModelOptions

/// Odyssey's voice provider switch, driven by its agent and voice settings.
@MainActor
public final class CompositeVoiceService: VoiceServiceProtocol {
    private let settings: AgentRegistrySettings
    private let providerSettings: ProviderSettings
    private let system: SystemVoiceService
    private let elevenLabs: ElevenLabsVoiceService
    private let openAI: OpenAIVoiceService
    private let xai: XAIVoiceService
    private var playbackStartedHandler: (@MainActor () -> Void)?
    private var latencyTrace: VoiceLatencyTrace?
    private var completedSpokenTurns = 0
    private var conversationArmed = false
    public private(set) var isVoiceControlArmed = false
    private var isPreparing = false

    public init(settings: AgentRegistrySettings, providerSettings: ProviderSettings) {
        self.settings = settings
        self.providerSettings = providerSettings
        self.system = SystemVoiceService(voiceID: { settings.systemVoiceID })
        self.elevenLabs = ElevenLabsVoiceService(
            apiKey: { settings.elevenLabsAPIKey },
            voiceID: {
                VoiceCatalog.resolvedVoiceID(settings.elevenLabsVoiceID, for: .elevenLabs)
            },
            modelID: { settings.elevenLabsModelID }
        )
        self.openAI = OpenAIVoiceService(
            apiKey: { providerSettings.openAITTSConnection()?.apiKey ?? "" },
            baseURL: {
                providerSettings.openAITTSConnection()?.trimmedBaseURL
                    ?? RemoteConnection.defaultOpenAIBaseURL
            },
            modelID: { settings.openAIVoiceModel },
            voiceID: { settings.openAIVoiceID }
        )
        self.xai = XAIVoiceService(
            apiKey: { providerSettings.xAITTSConnection()?.apiKey ?? "" },
            voiceID: { settings.xaiVoiceID }
        )
    }

    public var providerName: String {
        activeOutput.providerName
    }

    public var isAvailable: Bool {
        activeOutput.isAvailable
    }

    public var isListening: Bool { system.isListening }
    public var supportsLiveInput: Bool { system.supportsLiveInput }
    public var isSpeechBargeInEnabled: Bool { VoiceRouteMonitor.speechBargeInEnabled }
    public var lastAudioIssue: String? { VoiceDuplexEngine.shared.lastAudioIssue }

    public func setAudioIssueHandler(_ handler: (@MainActor (String?) -> Void)?) {
        VoiceDuplexEngine.shared.onAudioIssue = handler
    }

    public func setVoiceControlArmed(_ armed: Bool) {
        isVoiceControlArmed = armed
    }

    private var activeOutput: any VoiceServiceProtocol {
        switch VoiceProvider(rawValue: settings.voiceProvider) ?? .system {
        case .elevenLabs where elevenLabs.isAvailable: return elevenLabs
        case .openai where openAI.isAvailable: return openAI
        case .xai where xai.isAvailable: return xai
        default: return system
        }
    }

    public func speak(text: String) async throws {
        try await activeOutput.speak(text: text)
    }

    public func prepareSpokenConversation() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        conversationArmed = true
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? await VoiceDuplexEngine.shared.prepareAsync(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        await VoiceDuplexEngine.shared.ensureCaptureReady(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        await VoiceNetworkSession.preconnect(urls: warmupHosts())
        await activeOutput.prepareSpokenConversation()
    }

    /// Synchronous variant (kept for callers outside voice control). Each
    /// provider used to run its own engine teardown here — up to 5 per Stop;
    /// now providers only release their own resources and the engine is
    /// torn down once.
    public func endSpokenConversation() {
        resetConversationBookkeeping()
        releaseProviders(endListening: false)
        VoiceAudioSession.endSpokenConversation()
    }

    /// Voice control's teardown: provider cancels (TTS sockets, recognizer)
    /// on main, then one engine stop / tap removal / session deactivation on
    /// the audio queue, in that order.
    public func endSpokenConversationAsync() async {
        resetConversationBookkeeping()
        releaseProviders(endListening: true)
        await VoiceAudioSession.endSpokenConversationAsync()
    }

    public func silenceNow() {
        VoiceDuplexEngine.shared.silenceNow()
        system.cancelSpeech()
        elevenLabs.cancelSpeech()
        openAI.cancelSpeech()
        xai.cancelSpeech()
    }

    public var currentMicLevel: Double { VoiceDuplexEngine.shared.currentMicRMS }
    public var hasLiveAudio: Bool {
        conversationArmed || VoiceAudioSession.conversationActive || VoiceDuplexEngine.shared.isEngineRunning
    }

    private func resetConversationBookkeeping() {
        conversationArmed = false
        isVoiceControlArmed = false
        completedSpokenTurns = 0
    }

    private func releaseProviders(endListening: Bool) {
        system.releaseSpokenResources(endListening: endListening)
        elevenLabs.releaseSpokenResources()
        openAI.releaseSpokenResources()
        xai.releaseSpokenResources()
    }

    public func playListeningEndedCue() {
        VoiceListeningCue.play()
        markSpokenTurn(.requestSent)
    }

    public func setPlaybackStartedHandler(_ handler: (@MainActor () -> Void)?) {
        playbackStartedHandler = handler
        let wrapped: (@MainActor () -> Void)? = { [weak self] in
            self?.markSpokenTurn(.firstAudioByte)
            self?.markSpokenTurn(.playbackStart)
            handler?()
        }
        system.setPlaybackStartedHandler(wrapped)
        elevenLabs.setPlaybackStartedHandler(wrapped)
        openAI.setPlaybackStartedHandler(wrapped)
        xai.setPlaybackStartedHandler(wrapped)
    }

    public func beginSpokenTurn() {
        latencyTrace = VoiceLatencyTrace(
            turnKind: VoiceConnectionPolicy.turnKind(completedSpokenTurns: completedSpokenTurns),
            turnIndex: completedSpokenTurns
        )
        latencyTrace?.mark(.requestSent)
    }

    public func markSpokenTurn(_ mark: VoiceLatencyMark) {
        latencyTrace?.mark(mark)
    }

    public func endSpokenTurn() -> VoiceLatencyTrace? {
        let finished = latencyTrace
        latencyTrace = nil
        if finished?.timeToFirstAudioMilliseconds() != nil {
            completedSpokenTurns += 1
        }
        if let finished {
            #if DEBUG
            print(finished.summaryLine())
            #endif
        }
        return finished
    }

    public func beginStreamingSpeech() {
        VoiceDuplexEngine.shared.resetFirstPlaybackFlag()
        activeOutput.beginStreamingSpeech()
    }

    public func appendStreamingSpeech(_ cumulativeText: String) {
        if latencyTrace?.time(for: .firstTTSRequest) == nil,
           StreamingSpeechChunker.boundaryLength(in: cumulativeText) != nil {
            markSpokenTurn(.firstTTSRequest)
        }
        activeOutput.appendStreamingSpeech(cumulativeText)
    }

    public func checkpointStreamingSpeech(_ cumulativeText: String) {
        activeOutput.checkpointStreamingSpeech(cumulativeText)
    }

    public func finishStreamingSpeech(_ cumulativeText: String) async throws {
        try await activeOutput.finishStreamingSpeech(cumulativeText)
    }

    public func replayLastReply() async -> Bool {
        await activeOutput.replayLastReply()
    }

    public func cancelSpeech() {
        VoiceDuplexEngine.shared.stopPlayback()
        system.cancelSpeech()
        elevenLabs.cancelSpeech()
        openAI.cancelSpeech()
        xai.cancelSpeech()
    }

    /// Speech input is always Apple Speech (`SystemSpeechInputService`).
    public func beginContinuousListening(onEvent: @MainActor @escaping (VoiceInputEvent) -> Void) async throws {
        try await system.beginContinuousListening(onEvent: onEvent)
    }

    public func setListenMode(_ mode: VoiceListenMode) {
        system.setListenMode(mode)
    }

    public var listenIDs: String { system.listenIDs }

    public func endContinuousListening() {
        system.endContinuousListening()
    }

    private func warmupHosts() -> [URL] {
        let tts = VoiceProvider(rawValue: settings.voiceProvider) ?? .system
        return VoiceConnectionPolicy.hostsToPreconnect(
            llmBaseURL: providerSettings.resolvedConnection()?.trimmedBaseURL
                ?? providerSettings.chatCompletionsURL?.absoluteString,
            ttsProvider: tts,
            openAIBaseURL: providerSettings.openAITTSConnection()?.trimmedBaseURL
        )
    }
}

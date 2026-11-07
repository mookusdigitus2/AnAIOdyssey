// SPDX-License-Identifier: MIT
@preconcurrency import AVFoundation
import AIConnect
import Foundation
import AIModelOptions

/// Every AVAudioEngine / AVAudioPlayerNode call goes through this. The duplex
/// engine only calls it on `VoiceAudioSession.audioQueue`, the serial queue
/// that also runs session activation and teardown, so engine start, tap
/// install and route rebuilds are ordered with them and never block main.
/// Tests inject a fake (see `BlockingFakeAudioGraph`).
protocol VoiceAudioGraph: AnyObject {
    var isRunning: Bool { get }
    var isPlayerPlaying: Bool { get }
    func inputFormat() -> AVAudioFormat?
    func playerFormat() -> AVAudioFormat?
    func configureIfNeeded()
    func reconnectPlayer()
    func setVoiceProcessing(_ enabled: Bool) throws
    /// Read back from the input node (the node the recognizer taps).
    var isVoiceProcessingEnabled: Bool { get }
    /// The TTS player node is attached to this same engine, so voice
    /// processing has the reply as its echo reference.
    var isPlayerAttachedToEngine: Bool { get }
    func start() throws
    func stop()
    func installTap(format: AVAudioFormat)
    func removeTap()
    func stopPlayer()
    /// Pauses the player node, keeping everything already scheduled.
    func pausePlayer()
    func play()
    func schedule(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)?)
    func scheduleFile(_ file: AVAudioFile, completion: @escaping () -> Void)
}

/// The real graph: one AVAudioEngine plus the TTS player node.
final class AVAudioEngineGraph: VoiceAudioGraph {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false

    var isRunning: Bool { engine.isRunning }
    var isPlayerPlaying: Bool { player.isPlaying }

    func inputFormat() -> AVAudioFormat? {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0 { return hardware }
        let output = input.outputFormat(forBus: 0)
        if output.sampleRate > 0, output.channelCount > 0 { return output }
        return nil
    }

    func playerFormat() -> AVAudioFormat? {
        // Must match the node buffers are scheduled on, not the mixer's output:
        // AVAudioPlayerNode.scheduleBuffer raises on a format mismatch.
        let format = player.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func configureIfNeeded() {
        guard !attached else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        attached = true
    }

    func reconnectPlayer() {
        configureIfNeeded()
        engine.disconnectNodeOutput(player)
        // `nil` lets the engine adopt the current hardware format — never a cache.
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    func setVoiceProcessing(_ enabled: Bool) throws {
        #if os(iOS) || os(macOS)
        try engine.inputNode.setVoiceProcessingEnabled(enabled)
        #endif
    }

    var isVoiceProcessingEnabled: Bool {
        #if os(iOS) || os(macOS)
        return engine.inputNode.isVoiceProcessingEnabled
        #else
        return false
        #endif
    }

    var isPlayerAttachedToEngine: Bool { attached && player.engine === engine }

    func start() throws {
        configureIfNeeded()
        engine.prepare()
        try engine.start()
        play()
    }

    func stop() { engine.stop() }

    func installTap(format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            VoiceAudioNotificationBridge.handleTapBuffer(buffer)
        }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func stopPlayer() { player.stop() }
    func pausePlayer() { player.pause() }

    /// AVAudioPlayerNode.play() on a stopped engine logs "Engine is not
    /// running... Cannot play yet!" and drops audio: check the real engine.
    func play() {
        guard engine.isRunning, !player.isPlaying else { return }
        player.play()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)?) {
        guard attached else { return }
        if let completion {
            // .dataPlayedBack: done only once it was heard, so drain waiters
            // (and the mic resuming) don't clip the end of a reply.
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        } else {
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    func scheduleFile(_ file: AVAudioFile, completion: @escaping () -> Void) {
        guard attached else { completion(); return }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }
}

/// The graph is only touched on the audio queue; this box carries it there.
struct VoiceAudioGraphBox: @unchecked Sendable {
    let graph: VoiceAudioGraph
}

/// What a rebuild needs from main-actor state, captured before it is queued.
struct VoiceGraphRebuildInput: @unchecked Sendable {
    var desiredAEC: Bool
    var event: VoiceAudioGraphEvent
    /// prepare(): skip when the live graph already matches.
    var skipIfLive: Bool
    /// route/config change: skip when the installed tap still matches hardware.
    var skipIfMatching: Bool
    var lastRequestedAEC: Bool?
    var isRunning: Bool
    var tapInstalled: Bool
    var installedSampleRate: Double
    var installedChannelCount: AVAudioChannelCount
    var hasRecognizer: Bool
    var pendingPlayback: Bool
    var isListening: Bool
    var spokenSessionActivated: Bool
    var sessionOptionsRaw: UInt
}

/// A side effect the rebuild hands back to main, in order.
enum VoiceGraphRebuildEffect: Sendable, Equatable {
    case issue(String?)
    case action(VoiceAudioGraphAction)
}

struct VoiceGraphRebuildOutcome: @unchecked Sendable {
    var skipped = false
    var isRunning = false
    var tapInstalled = false
    var installedSampleRate: Double = 0
    var installedChannelCount: AVAudioChannelCount = 0
    var acousticEchoCancellation: Bool?
    var routeSettled = false
    var resetConverters = false
    var sessionActionRan = false
    var sessionActivated = false
    var needsFormatRetry = false
    var playerFormat: AVAudioFormat?
    var effects: [VoiceGraphRebuildEffect] = []
    var log: [(String, String)] = []
    var error: Error?
    var ranOnMainThread = false
    /// The runtime echo check's final result, when it ran (req. 15).
    var echoCheck: VoiceEchoCheck?
}

/// One `AVAudioEngine` for mic capture and TTS playback so Apple's voice
/// processing unit has a playback reference for acoustic echo cancellation.
///
/// State lives on the main actor; every engine call (start, prepare, tap
/// install, voice processing, route/configuration rebuilds, teardown) runs on
/// `VoiceAudioSession.audioQueue`, the same serial queue as session
/// activation, so they are ordered with each other and main only receives
/// the resulting state. A car Bluetooth / CarPlay route change (often 8 or
/// 16 kHz mono HFP) rebuilds the graph with formats read fresh from the
/// hardware nodes — never a cached or hard-coded rate.
@MainActor
public final class VoiceDuplexEngine {
    public static let shared = VoiceDuplexEngine(graph: AVAudioEngineGraph())

    private let graphBox: VoiceAudioGraphBox
    private let observedEngine: AVAudioEngine?
    private var isConfigured = false
    /// Set by `teardown()` (user left voice). Route/config/interruption
    /// notifications must not resurrect the graph until `prepare` runs again.
    private var isTornDown = false
    /// Main-side mirror of the engine's running state (updated from queue results).
    private var isRunning = false
    private var tapInstalled = false
    private var rebuildsInFlight = 0
    private var rebuildQueued = false
    private var rebuildWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped by teardown; a rebuild that started before it is discarded.
    private var lifecycleGeneration = 0
    private var observersInstalled = false
    private var pendingBuffers = 0
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    private var didNotifyFirstSchedule = false
    private var lastMicRMS: Double = 0
    private var lastPlaybackRMS: Double = 0
    private var converters: [String: AVAudioConverter] = [:]
    private var lastInstalledSampleRate: Double = 0
    private var lastInstalledChannelCount: AVAudioChannelCount = 0
    private var cachedPlayerFormat: AVAudioFormat?
    private var formatRetryTask: Task<Void, Never>?
    private var routeSettled = false

    private(set) var acousticEchoCancellationAvailable = false
    /// True after the runtime echo check failed twice (voice processing,
    /// same-engine player or voiceChat mode). Speech barge-in is then off on
    /// every route, so the mic stays closed during playback.
    public private(set) var echoCheckFailed = false
    public private(set) var lastEchoCheck: VoiceEchoCheck?
    /// Voice processing verified and allowed on the current route: the reply
    /// (and a paused reply's tail) is cancelled out of the mic.
    var echoCancelledOnThisRoute: Bool {
        !echoCheckFailed && VoiceEchoPolicy.allowsSpeechBargeIn(
            route: VoiceRouteMonitor.currentKind(),
            acousticEchoCancellationAvailable: acousticEchoCancellationAvailable
        )
    }
    public private(set) var lastAudioIssue: String?
    public var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onFirstPlayback: (() -> Void)?
    public var onGraphRebuilt: (() -> Void)?
    public var onAudioIssue: ((String?) -> Void)?

    /// Audible reply playback. A paused reply counts as quiet, so the mic
    /// gate lets the user answer the "continue?" prompt.
    public var isPlayingBack: Bool { pendingBuffers > 0 && !isPlaybackPaused }
    /// Reply audio scheduled and not finished, paused or not.
    public var hasPendingPlayback: Bool { pendingBuffers > 0 }
    /// Barge-in prompt: playback paused, incoming audio keeps buffering.
    private(set) var isPlaybackPaused = false

    /// Pauses the player node; everything scheduled stays queued and new
    /// buffers keep queueing behind it (no `play()` until resume).
    public func pausePlayback() {
        guard !isPlaybackPaused else { return }
        isPlaybackPaused = true
        // A barge-in pause on an echo-cancelled route must not start the tail
        // guard: the user is mid-sentence and ~0.6 s of their words would be
        // dropped (PR #215 re-review). Tap-to-interrupt on HFP still guards.
        if pendingBuffers > 0, VoiceMicGate.pauseStartsTailGuard(echoCancelled: echoCancelledOnThisRoute) {
            lastPlaybackEndedAt = Date()
        }
        lastPlaybackRMS = 0
        VoiceAudioDebugStore.append(event: "playback.pause", detail: "pending=\(pendingBuffers)")
        onAudioQueueAsync { $0.pausePlayer() }
    }

    /// Resumes from the pause point, buffered audio included.
    public func resumePlayback() {
        guard isPlaybackPaused else { return }
        isPlaybackPaused = false
        VoiceAudioDebugStore.append(event: "playback.resume", detail: "pending=\(pendingBuffers)")
        onAudioQueueAsync { graph in
            if !graph.isRunning { try? graph.start() }
            graph.play()
        }
    }
    public var isEngineRunning: Bool { isRunning }
    public var currentMicRMS: Double { lastMicRMS }
    /// When the last scheduled reply audio finished playing (tail guard for barge-in).
    private(set) var lastPlaybackEndedAt: Date?
    public var secondsSincePlaybackEnded: Double? {
        lastPlaybackEndedAt.map { Date().timeIntervalSince($0) }
    }
    /// True when the mic should be treated as the user, not our own voice.
    public var micAcceptsSpeech: Bool {
        VoiceMicGate.shouldAccept(
            isPlayingBack: isPlayingBack,
            secondsSincePlaybackEnded: secondsSincePlaybackEnded,
            echoCancellationActive: acousticEchoCancellationAvailable,
            bargeInEnabled: VoiceRouteMonitor.speechBargeInEnabled
        )
    }
    public var currentPlaybackRMS: Double { lastPlaybackRMS }

    init(graph: VoiceAudioGraph) {
        graphBox = VoiceAudioGraphBox(graph: graph)
        observedEngine = (graph as? AVAudioEngineGraph)?.engine
        installSessionObservers()
    }

    // MARK: - Audio queue

    /// Waits on main for queue work. Only for the legacy synchronous API
    /// (`prepare`, `start`, `teardown`, test hooks); the engine work itself
    /// still runs on the audio queue, ordered after anything queued earlier.
    private func onAudioQueueSync<T>(_ work: (VoiceAudioGraph) throws -> T) rethrows -> T {
        let box = graphBox
        return try VoiceAudioSession.audioQueue.sync { try work(box.graph) }
    }

    private func onAudioQueue<T>(_ work: @escaping (VoiceAudioGraph) -> T) async -> T {
        let box = graphBox
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let unchecked = UncheckedContinuationBox(continuation: continuation)
            VoiceAudioSession.audioQueue.async {
                unchecked.continuation.resume(returning: work(box.graph))
            }
        }
    }

    /// Fire-and-forget, still ordered on the serial queue.
    private func onAudioQueueAsync(_ work: @escaping (VoiceAudioGraph) -> Void) {
        let box = graphBox
        VoiceAudioSession.audioQueue.async { work(box.graph) }
    }

    public func acceptTapBuffer(_ buffer: AVAudioPCMBuffer, rms: Double) {
        guard !micBuffersDropped else { return }
        lastMicRMS = rms
        onMicBuffer?(buffer)
    }

    /// Synchronous session-change stop (legacy sync activation path).
    public func stopEngineForSessionChange() {
        let pending = pendingBuffers > 0
        onAudioQueueSync { graph in
            if graph.isPlayerPlaying || pending { graph.stopPlayer() }
            if graph.isRunning { graph.stop() }
        }
        isRunning = false
        VoiceAudioDebugStore.append(event: "engine.stop", detail: "session-change")
    }

    public func stopEngineForSessionChangeAsync() async {
        let pending = pendingBuffers > 0
        await onAudioQueue { graph in
            if graph.isPlayerPlaying || pending { graph.stopPlayer() }
            if graph.isRunning { graph.stop() }
        }
        isRunning = false
        VoiceAudioDebugStore.append(event: "engine.stop", detail: "session-change async")
    }

    public func reportAudioIssue(_ message: String?) {
        lastAudioIssue = message
        onAudioIssue?(message)
    }

    /// Full graph rebuilds performed (stop engine, VP, reconnect, start, tap).
    private(set) var graphRebuildCount = 0
    /// Test hook: whether the last graph rebuild's engine work ran on main.
    private(set) var lastRebuildRanOnMainThread: Bool?
    private var lastRequestedAEC: Bool?

    private func beginPrepare() {
        isTornDown = false
        setMicBuffersDropped(false)
        installSessionObservers()
    }

    /// Main-side fast path: the mirror says the graph is live with this AEC
    /// setting and nothing is pending, so skip the queue round trip. Route
    /// changes come through `handleExternalGraphChange`, which re-checks the
    /// hardware on the queue.
    private func mirrorSaysLive(enableAEC: Bool) -> Bool {
        isRunning && tapInstalled && rebuildsInFlight == 0 && lastRequestedAEC == enableAEC
    }

    /// Synchronous prepare (kept for TTS players and tests). Main waits, but
    /// the engine work runs on the audio queue.
    public func prepare(enableAEC: Bool) throws {
        beginPrepare()
        if mirrorSaysLive(enableAEC: enableAEC) {
            VoiceAudioDebugStore.append(event: "prepare.skip", detail: "graph already live")
            return
        }
        let input = rebuildInput(desiredAEC: enableAEC, event: .start, skipIfLive: true, skipIfMatching: false)
        let generation = beginRebuild()
        let outcome = onAudioQueueSync { Self.performRebuild(input, on: $0) }
        try finishRebuild(outcome, generation: generation, requestedAEC: enableAEC)
    }

    /// Voice start's prepare: returns to the caller at once and never blocks
    /// main on engine work.
    public func prepareAsync(enableAEC: Bool) async throws {
        beginPrepare()
        await waitForRebuildIdle()
        if mirrorSaysLive(enableAEC: enableAEC) {
            VoiceAudioDebugStore.append(event: "prepare.skip", detail: "graph already live")
            if enableAEC { await verifyEchoCancellation() }
            return
        }
        let input = rebuildInput(desiredAEC: enableAEC, event: .start, skipIfLive: true, skipIfMatching: false)
        let generation = beginRebuild()
        let outcome = await onAudioQueue { Self.performRebuild(input, on: $0) }
        try finishRebuild(outcome, generation: generation, requestedAEC: enableAEC)
    }

    public func primeSilence() {
        guard isConfigured, let format = cachedPlayerFormat else { return }
        let frames = max(AVAudioFrameCount(format.sampleRate * 0.01), 64)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        if let dst = buffer.mutableAudioBufferList.pointee.mBuffers.mData {
            memset(dst, 0, Int(frames) * Int(format.streamDescription.pointee.mBytesPerFrame))
        }
        let unchecked = UncheckedBufferBox(buffer: buffer)
        onAudioQueueAsync { $0.schedule(unchecked.buffer, completion: nil) }
    }

    /// Test/diagnostic hook: whether the underlying AVAudioEngine is running.
    /// Read on the audio queue, so it sees every earlier queued block.
    public var isEngineActuallyRunning: Bool { onAudioQueueSync { $0.isRunning } }
    public var isTapInstalledForTesting: Bool { tapInstalled }
    public var isRunningForTesting: Bool { isEngineActuallyRunning }
    /// Test hook: simulate the engine stopping on a configuration change.
    public func stopEngineBehindOurBackForTesting() { onAudioQueueSync { $0.stop() } }
    /// Test hook: waits for every queued engine block and main-side rebuild result.
    public func waitUntilGraphIdle() async {
        await onAudioQueue { _ in }
        await waitForRebuildIdle()
    }

    /// Voice mode's own capture setup, independent of anything the custom
    /// voice screen did. If the engine isn't running or the mic tap is
    /// missing (stale session state, format retry, external stop), re-apply
    /// the session and rebuild the graph once. The real engine state is read
    /// on the audio queue; nothing here blocks main.
    @discardableResult
    public func ensureCaptureReady(enableAEC: Bool) async -> Bool {
        await waitForRebuildIdle()
        let live = await onAudioQueue { $0.isRunning }
        if !live, isRunning {
            isRunning = false
            VoiceAudioDebugStore.append(event: "engine.stopped-externally", detail: "")
        }
        if live, tapInstalled { return true }
        VoiceAudioDebugStore.append(event: "capture.heal", detail: "running=\(live) tap=\(tapInstalled)")
        VoiceAudioSession.invalidateSpokenActivation()
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        routeSettled = true
        try? await prepareAsync(enableAEC: enableAEC)
        var running = await onAudioQueue { $0.isRunning }
        if !running {
            try? await startAsync()
            running = await onAudioQueue { $0.isRunning }
        }
        isRunning = running
        return running && tapInstalled
    }

    public func start() throws {
        guard rebuildsInFlight == 0 else { return }
        if isRunning {
            guard !isPlaybackPaused else { return }
            onAudioQueueAsync { graph in
                if graph.isRunning { graph.play() }
            }
            return
        }
        #if os(iOS)
        do {
            try VoiceAudioSession.prepareForPlayback()
        } catch {
            reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            throw error
        }
        #endif
        let format = try onAudioQueueSync { graph -> AVAudioFormat? in
            try graph.start()
            return graph.playerFormat()
        }
        noteStarted(playerFormat: format)
    }

    public func startAsync() async throws {
        guard rebuildsInFlight == 0 else { return }
        if isRunning {
            guard !isPlaybackPaused else { return }
            onAudioQueueAsync { graph in
                if graph.isRunning { graph.play() }
            }
            return
        }
        #if os(iOS)
        do {
            try await VoiceAudioSession.prepareForPlaybackAsync()
        } catch {
            reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            throw error
        }
        #endif
        let result: Result<AVAudioFormat?, Error> = await onAudioQueue { graph in
            Result { try graph.start(); return graph.playerFormat() }
        }
        noteStarted(playerFormat: try result.get())
    }

    private func noteStarted(playerFormat: AVAudioFormat?) {
        isConfigured = true
        isRunning = true
        if let playerFormat { cachedPlayerFormat = playerFormat }
    }

    public func schedule(pcmData: Data, sampleRate: Double) {
        guard !pcmData.isEmpty else { return }
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { return }
        guard let buffer = Self.int16Buffer(pcmData, format: source) else { return }
        schedule(buffer: buffer)
    }

    /// Conversion and bookkeeping on main; the node calls are queued. The
    /// queued block restarts an engine that stopped behind our back
    /// (configuration change, interruption) before scheduling.
    ///
    /// Not dropped while a rebuild is in flight: the block queues behind the
    /// rebuild on the serial audio queue, and is skipped there only if the
    /// rebuild changed the player format (scheduleBuffer raises on a mismatch).
    public func schedule(buffer: AVAudioPCMBuffer) {
        schedule(buffer, isReply: true)
    }

    /// The listening cue: played on the same player (so AEC hears it) but
    /// not reply playback. It never counts in `isPlayingBack`, never gates
    /// the mic and never reports first playback.
    public func scheduleCue(pcmData: Data, sampleRate: Double) {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let buffer = Self.int16Buffer(pcmData, format: source) else { return }
        schedule(buffer, isReply: false)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, isReply: Bool) {
        guard buffer.frameLength > 0 else { return }
        guard isConfigured, let target = cachedPlayerFormat else { return }
        let playable: AVAudioPCMBuffer
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.commonFormat == target.commonFormat,
           buffer.format.channelCount == target.channelCount {
            playable = buffer
        } else if let converted = convert(buffer, to: target) {
            playable = converted
        } else {
            return
        }

        if !isRunning {
            do {
                try start()
            } catch {
                reportAudioIssue(VoiceAudioIssueMessage.graphRebuildFailed)
                return
            }
        }

        if isReply {
            lastPlaybackRMS = Self.rms(playable)
            notifyFirstPlayback()
            pendingBuffers += 1
        }
        let paused = isPlaybackPaused
        let unchecked = UncheckedBufferBox(buffer: playable)
        onAudioQueueAsync { [weak self] graph in
            let finished: @Sendable () -> Void = {
                guard isReply else { return }
                Task { @MainActor in self?.noteBufferFinished() }
            }
            guard let current = graph.playerFormat(), current.isEqual(unchecked.buffer.format) else {
                finished()
                return
            }
            if !graph.isRunning {
                do {
                    try graph.start()
                } catch {
                    finished()
                    Task { @MainActor in self?.reportAudioIssue(VoiceAudioIssueMessage.graphRebuildFailed) }
                    return
                }
                if paused { graph.pausePlayer() } // start() plays; keep the prompt's pause
            }
            if !paused { graph.play() }
            graph.schedule(unchecked.buffer, completion: finished)
        }
    }

    public func scheduleCompressed(data: Data) {
        guard !data.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-tts-\(UUID().uuidString).audio")
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            if !isRunning {
                try start()
            }
            notifyFirstPlayback()
            pendingBuffers += 1
            let paused = isPlaybackPaused
            let unchecked = UncheckedFileBox(file: file)
            onAudioQueueAsync { [weak self] graph in
                if !graph.isRunning {
                    do {
                        try graph.start()
                    } catch {
                        // Same as the buffer path: never schedule on a stopped engine (its completion
                        // never fires, pendingBuffers stays > 0 and isPlayingBack keeps the mic shut).
                        let detail = "\(error)"
                        Task { @MainActor in
                            VoiceAudioDebugStore.append(event: "playback.compressed.startFailed", detail: detail)
                            try? FileManager.default.removeItem(at: url)
                            self?.noteBufferFinished()
                            self?.reportAudioIssue(VoiceAudioIssueMessage.graphRebuildFailed)
                        }
                        return
                    }
                    if paused { graph.pausePlayer() }
                }
                if !paused { graph.play() }
                graph.scheduleFile(unchecked.file) {
                    Task { @MainActor in
                        try? FileManager.default.removeItem(at: url)
                        self?.noteBufferFinished()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            reportAudioIssue(VoiceAudioIssueMessage.graphRebuildFailed)
        }
    }

    public func waitUntilFinished() async {
        if pendingBuffers == 0 { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainContinuations.append(continuation)
            if pendingBuffers == 0 {
                resumeDrainWaiters()
            }
        }
    }

    public func stopPlayback() {
        if pendingBuffers > 0 { lastPlaybackEndedAt = Date() }
        pendingBuffers = 0
        isPlaybackPaused = false
        didNotifyFirstSchedule = false
        lastPlaybackRMS = 0
        resumeDrainWaiters()
        let replay = isRunning && rebuildsInFlight == 0
        onAudioQueueAsync { graph in
            graph.stopPlayer()
            if replay { graph.play() }
        }
    }

    public func resetFirstPlaybackFlag() {
        didNotifyFirstSchedule = false
    }

    /// Test hooks: how many teardowns ran, their steps, and on which thread.
    private(set) var teardownCount = 0
    private(set) var lastTeardownSteps: [String] = []
    private(set) var lastTeardownRanOnMainThread: Bool?

    private var micBuffersDropped = false

    private func setMicBuffersDropped(_ dropped: Bool) {
        micBuffersDropped = dropped
        VoiceAudioNotificationBridge.setMicBuffersDropped(dropped)
        if dropped { lastMicRMS = 0 }
    }

    /// Stop/Back tap: cut playback and ignore the mic right now. No
    /// `engine.stop()` and no session call — those are queued separately.
    public func silenceNow() {
        if pendingBuffers > 0 { lastPlaybackEndedAt = Date() }
        pendingBuffers = 0
        isPlaybackPaused = false
        didNotifyFirstSchedule = false
        lastPlaybackRMS = 0
        resumeDrainWaiters()
        setMicBuffersDropped(true)
        onAudioQueueAsync { $0.stopPlayer() }
        VoiceAudioDebugStore.append(event: "engine.silence", detail: "stop tap")
    }

    private func clearStateForTeardown() {
        isTornDown = true
        isPlaybackPaused = false
        lifecycleGeneration += 1
        rebuildQueued = false
        formatRetryTask?.cancel()
        formatRetryTask = nil
        tapInstalled = false
        lastInstalledSampleRate = 0
        lastInstalledChannelCount = 0
        isRunning = false
        acousticEchoCancellationAvailable = false
        echoCheckFailed = false
        lastEchoCheck = nil
        onMicBuffer = nil
        onGraphRebuilt = nil
        lastRequestedAEC = nil
        converters.removeAll()
        lastAudioIssue = nil
        teardownCount += 1
    }

    /// Voice control's teardown. Bookkeeping happens now on main; the
    /// engine / session calls run on the audio queue in order: engine stop,
    /// tap removal, then (optionally) session deactivation with
    /// `.notifyOthersOnDeactivation`, so other apps' audio resumes.
    public func teardownOffMain(deactivateSession: Bool) async {
        VoiceAudioDebugStore.append(event: "engine.teardown.async", detail: "running=\(isRunning) tap=\(tapInstalled)")
        silenceNow()
        let removeTap = tapInstalled
        clearStateForTeardown()
        let result = await onAudioQueue { graph -> ([String], Bool) in
            Self.performTeardown(on: graph, removeTap: removeTap, deactivateSession: deactivateSession)
        }
        lastTeardownSteps = result.0
        lastTeardownRanOnMainThread = result.1
        VoiceAudioDebugStore.append(event: "engine.teardown.done", detail: lastTeardownSteps.joined(separator: ","))
    }

    public func teardown() {
        VoiceAudioDebugStore.append(event: "engine.teardown", detail: "running=\(isRunning) tap=\(tapInstalled)")
        stopPlayback()
        let removeTap = tapInstalled
        clearStateForTeardown()
        let result = onAudioQueueSync { graph in
            Self.performTeardown(on: graph, removeTap: removeTap, deactivateSession: false)
        }
        lastTeardownSteps = result.0
        lastTeardownRanOnMainThread = result.1
    }

    nonisolated private static func performTeardown(
        on graph: VoiceAudioGraph,
        removeTap: Bool,
        deactivateSession: Bool
    ) -> ([String], Bool) {
        var steps: [String] = []
        graph.stopPlayer()
        if graph.isRunning {
            graph.stop()
            steps.append("engine.stop")
        }
        if removeTap {
            graph.removeTap()
            steps.append("tap.remove")
        }
        #if os(iOS)
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            steps.append("session.deactivate")
        }
        #endif
        return (steps, Thread.isMainThread)
    }

    // MARK: - Route / configuration rebuild

    /// Route change with its reason. Losing the output device while a reply is playing
    /// stops the reply (no speaker blast) and tells the chat, which shows Replay.
    public func handleRouteChange(reasonRawValue: UInt?) {
        switch VoiceRouteChangePolicy.response(reasonRawValue: reasonRawValue, hasPendingPlayback: hasPendingPlayback) {
        case .ignore:
            return
        case .stopPlaybackOfferReplay:
            VoiceAudioDebugStore.append(event: "route.oldDeviceUnavailable", detail: "stop playback, offer replay")
            stopPlayback()
            reportAudioIssue(VoiceRouteChangePolicy.stoppedMessage)
        case .rebuild:
            break
        }
        handleExternalGraphChange(event: .routeChanged)
    }

    public func handleExternalGraphChange(event: VoiceAudioGraphEvent) {
        VoiceAudioDebugStore.append(event: "graph.\(event.rawValue)", detail: VoiceRouteMonitor.debugDescription())
        guard !isTornDown else {
            VoiceAudioDebugStore.append(event: "graph.ignored", detail: "torn down")
            return
        }
        guard VoiceAudioSession.conversationActive || isRunning || isConfigured else { return }
        requestRebuild(
            event: event,
            desiredAEC: VoiceRouteMonitor.shouldEnableAEC,
            skipIfMatching: event == .routeChanged || event == .configurationChanged
        )
    }

    /// Queues one rebuild; a burst of route/config notifications while it
    /// runs coalesces into a single follow-up.
    private func requestRebuild(event: VoiceAudioGraphEvent, desiredAEC: Bool, skipIfMatching: Bool) {
        if rebuildsInFlight > 0 {
            rebuildQueued = true
            return
        }
        let input = rebuildInput(desiredAEC: desiredAEC, event: event, skipIfLive: false, skipIfMatching: skipIfMatching)
        let generation = beginRebuild()
        Task { @MainActor in
            let outcome = await self.onAudioQueue { Self.performRebuild(input, on: $0) }
            try? self.finishRebuild(outcome, generation: generation, requestedAEC: nil)
        }
    }

    private func rebuildInput(
        desiredAEC: Bool,
        event: VoiceAudioGraphEvent,
        skipIfLive: Bool,
        skipIfMatching: Bool
    ) -> VoiceGraphRebuildInput {
        var optionsRaw: UInt = 0
        #if os(iOS)
        optionsRaw = VoiceAudioSession.spokenConversationOptions.rawValue
        #endif
        return VoiceGraphRebuildInput(
            desiredAEC: desiredAEC,
            event: event,
            skipIfLive: skipIfLive,
            skipIfMatching: skipIfMatching,
            lastRequestedAEC: lastRequestedAEC,
            isRunning: isRunning,
            tapInstalled: tapInstalled,
            installedSampleRate: lastInstalledSampleRate,
            installedChannelCount: lastInstalledChannelCount,
            hasRecognizer: onGraphRebuilt != nil,
            pendingPlayback: pendingBuffers > 0,
            isListening: onMicBuffer != nil,
            spokenSessionActivated: VoiceAudioSession.spokenSessionActivated,
            sessionOptionsRaw: optionsRaw
        )
    }

    private func beginRebuild() -> Int {
        rebuildsInFlight += 1
        return lifecycleGeneration
    }

    private func waitForRebuildIdle() async {
        while rebuildsInFlight > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                rebuildWaiters.append(continuation)
            }
        }
    }

    /// Applies a rebuild's result on main: state mirror, then the ordered
    /// main-side effects (issues, recognizer recreation, dropped playback).
    private func finishRebuild(
        _ outcome: VoiceGraphRebuildOutcome,
        generation: Int,
        requestedAEC: Bool?
    ) throws {
        rebuildsInFlight -= 1
        defer {
            let waiters = rebuildWaiters
            rebuildWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if rebuildQueued, rebuildsInFlight == 0, !isTornDown {
                rebuildQueued = false
                handleExternalGraphChange(event: .configurationChanged)
            }
        }
        for (event, detail) in outcome.log {
            VoiceAudioDebugStore.append(event: event, detail: detail)
        }
        // Left voice while this rebuild was queued: the teardown queued after
        // it already stopped the engine; don't resurrect the mirror.
        guard generation == lifecycleGeneration else { return }
        isConfigured = true
        if let format = outcome.playerFormat { cachedPlayerFormat = format }
        if outcome.skipped {
            if let aec = outcome.acousticEchoCancellation { acousticEchoCancellationAvailable = aec }
            if outcome.effects.contains(.action(.dropPendingPlayback)) { dropPendingPlaybackState() }
            if let check = outcome.echoCheck { applyEchoCheck(check) }
            return
        }
        graphRebuildCount += 1
        lastRebuildRanOnMainThread = outcome.ranOnMainThread
        if let requestedAEC { lastRequestedAEC = requestedAEC }
        isRunning = outcome.isRunning
        tapInstalled = outcome.tapInstalled
        lastInstalledSampleRate = outcome.installedSampleRate
        lastInstalledChannelCount = outcome.installedChannelCount
        if let aec = outcome.acousticEchoCancellation { acousticEchoCancellationAvailable = aec }
        if outcome.routeSettled { routeSettled = true }
        if outcome.resetConverters { converters.removeAll() }
        if let check = outcome.echoCheck { applyEchoCheck(check) }
        if outcome.sessionActionRan {
            VoiceAudioSession.noteSpokenActivation(applied: outcome.sessionActivated)
        }
        for effect in outcome.effects {
            switch effect {
            case .issue(let message):
                reportAudioIssue(message)
            case .action(.recreateRecognizer):
                onGraphRebuilt?()
            case .action(.dropPendingPlayback):
                dropPendingPlaybackState()
            case .action(.showAudioIssue):
                if let message = VoiceDuplexEngine.shared.lastAudioIssue {
                    onAudioIssue?(message)
                } else if !acousticEchoCancellationAvailable || VoiceRouteMonitor.currentKind() == .bluetoothHFP {
                    reportAudioIssue(VoiceAudioIssueMessage.voiceProcessingUnavailable)
                } else {
                    reportAudioIssue(VoiceAudioIssueMessage.graphRebuildFailed)
                }
            case .action(.clearAudioIssue):
                reportAudioIssue(nil)
            case .action:
                break
            }
        }
        if outcome.needsFormatRetry { scheduleFormatRetry() }
        if let error = outcome.error { throw error }
    }

    /// Session start (a live graph that skipped its rebuild): run the echo
    /// check on the audio queue anyway.
    public func verifyEchoCancellation() async {
        let sessionOptions = rebuildInput(desiredAEC: true, event: .start, skipIfLive: true, skipIfMatching: false).sessionOptionsRaw
        let outcome = await onAudioQueue { graph -> VoiceGraphRebuildOutcome in
            var out = VoiceGraphRebuildOutcome()
            out.isRunning = graph.isRunning
            Self.verifyEcho(desiredAEC: true, sessionOptionsRaw: sessionOptions, on: graph, into: &out)
            return out
        }
        for (event, detail) in outcome.log {
            VoiceAudioDebugStore.append(event: event, detail: detail)
        }
        if let aec = outcome.acousticEchoCancellation { acousticEchoCancellationAvailable = aec }
        if outcome.effects.contains(.action(.dropPendingPlayback)) { dropPendingPlaybackState() }
        if let check = outcome.echoCheck { applyEchoCheck(check) }
    }

    /// The player was stopped on the audio queue: nothing is pending anymore.
    private func dropPendingPlaybackState() {
        pendingBuffers = 0
        isPlaybackPaused = false
        didNotifyFirstSchedule = false
        lastPlaybackRMS = 0
        resumeDrainWaiters()
    }

    private func applyEchoCheck(_ check: VoiceEchoCheck) {
        lastEchoCheck = check
        echoCheckFailed = !check.passes
        guard !check.passes else { return }
        // Log-only (`voice.aec.disabled` was logged on the audio queue): the
        // mic stays closed during playback and tap interrupts. No assert, so
        // Debug device builds keep running.
        acousticEchoCancellationAvailable = false
    }

    nonisolated static func sessionIsVoiceChat() -> Bool {
        if let forced = VoiceAudioSession.voiceChatOverrideForTesting { return forced }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return session.category == VoiceAudioSession.spokenConversationCategory
            && session.mode == VoiceAudioSession.spokenConversationMode
        #else
        return true
        #endif
    }

    /// The runtime echo check (req. 15), on the audio queue: voice processing
    /// on the input node, the player on this same engine, and a voiceChat
    /// session. A failure is repaired once (engine stopped, voice processing
    /// re-enabled, player reattached, session mode reapplied, engine
    /// restarted); a second failure logs `voice.aec.disabled` and the main
    /// side closes the mic during playback. The repair stops the player, so
    /// it drops any pending reply playback (a reply cut mid-play; Replay
    /// still has it). It runs only when the check fails.
    nonisolated static func verifyEcho(
        desiredAEC: Bool,
        sessionOptionsRaw: UInt,
        on graph: VoiceAudioGraph,
        into out: inout VoiceGraphRebuildOutcome
    ) {
        guard desiredAEC, graph.isRunning else { return }
        let route = VoiceRouteMonitor.currentKind()
        let expected = VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: route)
            && VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(route: route, voiceProcessingAvailable: true)
        func probe() -> VoiceEchoCheck {
            VoiceEchoCheck(
                voiceProcessingExpected: expected,
                voiceProcessingOn: graph.isVoiceProcessingEnabled,
                playerOnSameEngine: graph.isPlayerAttachedToEngine,
                sessionIsVoiceChat: sessionIsVoiceChat()
            )
        }
        var check = probe()
        if !check.passes {
            out.log.append(("voice.aec.check.failed", "\(check.failures.joined(separator: ",")) \(check.detail) route=\(route.rawValue)"))
            graph.stopPlayer()
            graph.stop()
            out.effects.append(.action(.dropPendingPlayback))
            if expected, !check.voiceProcessingOn { try? graph.setVoiceProcessing(true) }
            if !check.playerOnSameEngine { graph.reconnectPlayer() }
            #if os(iOS)
            if !check.sessionIsVoiceChat, VoiceAudioSession.voiceChatOverrideForTesting == nil {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(VoiceAudioSession.spokenConversationCategory, mode: VoiceAudioSession.spokenConversationMode, options: AVAudioSession.CategoryOptions(rawValue: sessionOptionsRaw))
                try? session.setActive(true, options: [])
            }
            #endif
            try? graph.start()
            out.isRunning = graph.isRunning
            check = probe()
            if check.passes {
                out.log.append(("voice.aec.reenabled", check.detail))
            } else {
                out.log.append(("voice.aec.disabled", "\(check.failures.joined(separator: ",")) \(check.detail) route=\(route.rawValue) mic closed during playback"))
            }
        } else {
            out.log.append(("voice.aec.ok", "\(check.detail) route=\(route.rawValue)"))
        }
        out.echoCheck = check
        out.acousticEchoCancellation = check.echoCancelled
    }

    /// The whole rebuild, on the audio queue: read formats fresh, run the
    /// pure policy, perform the engine actions in order, then the echo check.
    nonisolated static func performRebuild(
        _ input: VoiceGraphRebuildInput,
        on graph: VoiceAudioGraph
    ) -> VoiceGraphRebuildOutcome {
        var outcome = performRebuildSteps(input, on: graph)
        // A route or configuration change that skipped the rebuild is still
        // checked: the change itself can reset voice processing.
        if outcome.isRunning, !outcome.skipped || input.skipIfMatching {
            verifyEcho(desiredAEC: input.desiredAEC, sessionOptionsRaw: input.sessionOptionsRaw, on: graph, into: &outcome)
        }
        // Read after every step (a `defer` on the returned struct would be
        // lost: the return value is copied before the defer runs).
        outcome.playerFormat = graph.playerFormat()
        return outcome
    }

    nonisolated private static func performRebuildSteps(
        _ input: VoiceGraphRebuildInput,
        on graph: VoiceAudioGraph
    ) -> VoiceGraphRebuildOutcome {
        var out = VoiceGraphRebuildOutcome()
        out.ranOnMainThread = Thread.isMainThread
        out.isRunning = input.isRunning && graph.isRunning
        out.tapInstalled = input.tapInstalled
        out.installedSampleRate = input.installedSampleRate
        out.installedChannelCount = input.installedChannelCount
        if input.isRunning, !graph.isRunning {
            out.log.append(("engine.stopped-externally", ""))
        }
        graph.configureIfNeeded()

        let format = graph.inputFormat()
        let matchesTap = format.map {
            $0.sampleRate == input.installedSampleRate
                && $0.channelCount == input.installedChannelCount
                && input.installedSampleRate > 0
        } ?? false
        let live = out.isRunning && input.tapInstalled && matchesTap
        if input.skipIfLive, live, input.lastRequestedAEC == input.desiredAEC {
            out.skipped = true
            out.log.append(("prepare.skip", "graph already live"))
            return out
        }
        if input.skipIfMatching, live {
            out.skipped = true
            return out
        }

        let route = VoiceRouteMonitor.currentKind()
        let incoming = VoiceHardwareFormat(
            sampleRate: format?.sampleRate ?? 0,
            channelCount: Int(format?.channelCount ?? 0),
            route: route
        )
        if !incoming.isValid {
            out.log.append(("format.invalid", "rate=\(incoming.sampleRate) ch=\(incoming.channelCount) — waiting"))
            if graph.isPlayerPlaying || input.pendingPlayback { graph.stopPlayer() }
            if graph.isRunning { graph.stop() }
            out.log.append(("engine.stop", "session-change"))
            if out.tapInstalled { graph.removeTap() }
            out.isRunning = false
            out.tapInstalled = false
            out.installedSampleRate = 0
            out.installedChannelCount = 0
            out.effects.append(.issue(VoiceAudioIssueMessage.formatUnavailable))
            out.needsFormatRetry = true
            return out
        }
        out.routeSettled = true
        let step = VoiceAudioGraphPolicy.reduce(
            VoiceAudioGraphSnapshot(
                phase: input.isRunning ? .running : .idle,
                format: incoming,
                tapInstalled: input.tapInstalled,
                engineRunning: input.isRunning || graph.isRunning,
                recognizerGeneration: input.hasRecognizer ? 1 : 0,
                pendingPlayback: input.pendingPlayback,
                isListening: input.isListening
            ),
            event: input.event,
            incomingFormat: incoming,
            voiceProcessingAvailable: true,
            voiceProcessingThrows: false
        )

        actions: for action in step.actions {
            switch action {
            case .activateSession:
                #if os(iOS)
                out.sessionActionRan = true
                let session = AVAudioSession.sharedInstance()
                if input.spokenSessionActivated,
                   session.category == .playAndRecord,
                   session.mode == .voiceChat {
                    continue actions
                }
                if graph.isRunning, !VoiceLifecyclePolicy.shouldActivateSessionWhileEngineRunning() {
                    graph.stopPlayer()
                    graph.stop()
                    out.isRunning = false
                    out.log.append(("engine.stop", "session-change"))
                }
                do {
                    try session.setCategory(
                        VoiceAudioSession.spokenConversationCategory,
                        mode: VoiceAudioSession.spokenConversationMode,
                        options: AVAudioSession.CategoryOptions(rawValue: input.sessionOptionsRaw)
                    )
                    try session.setActive(true, options: [])
                    try? session.overrideOutputAudioPort(route == .speaker ? .speaker : .none)
                    out.sessionActivated = true
                    out.log.append(("session.activate", "playAndRecord/voiceChat (audio queue)"))
                } catch {
                    out.effects.append(.issue(VoiceAudioIssueMessage.sessionActivationFailed))
                    out.log.append(("session.activate.failed", "\(error)"))
                }
                #endif
            case .stopEngine:
                if graph.isPlayerPlaying || input.pendingPlayback { graph.stopPlayer() }
                if graph.isRunning || out.isRunning {
                    graph.stop()
                    out.isRunning = false
                }
            case .removeTap:
                if out.tapInstalled {
                    graph.removeTap()
                    out.tapInstalled = false
                    out.installedSampleRate = 0
                    out.installedChannelCount = 0
                }
            case .applyVoiceProcessing:
                #if os(iOS) || os(macOS)
                guard !graph.isRunning else { continue actions }
                let enable = input.desiredAEC
                    && VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: route)
                    && VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(route: route, voiceProcessingAvailable: true)
                do {
                    try graph.setVoiceProcessing(enable)
                    out.acousticEchoCancellation = enable
                    out.log.append(("voice-processing", "enabled=\(enable) route=\(route.rawValue)"))
                } catch {
                    out.acousticEchoCancellation = false
                    out.log.append(("voice-processing.failed", "\(error)"))
                    if enable || route == .bluetoothHFP {
                        out.effects.append(.issue(VoiceAudioIssueMessage.voiceProcessingUnavailable))
                    }
                }
                #else
                out.acousticEchoCancellation = false
                #endif
            case .reconnectNodes:
                graph.reconnectPlayer()
                out.resetConverters = true
            case .startEngine:
                guard let current = graph.inputFormat(),
                      VoiceLifecyclePolicy.shouldStartEngine(
                        formatValid: current.sampleRate > 0 && current.channelCount > 0,
                        routeSettled: out.routeSettled
                      ) else {
                    out.effects.append(.issue(VoiceAudioIssueMessage.formatUnavailable))
                    out.needsFormatRetry = true
                    break actions
                }
                do {
                    try graph.start()
                    out.isRunning = true
                    out.log.append(("engine.start", "rate=\(current.sampleRate) ch=\(current.channelCount)"))
                } catch {
                    out.isRunning = false
                    out.effects.append(.issue(VoiceAudioIssueMessage.graphRebuildFailed))
                    out.error = error
                    break actions
                }
            case .installTap:
                if out.tapInstalled {
                    graph.removeTap()
                    out.tapInstalled = false
                }
                guard let current = graph.inputFormat() else {
                    out.effects.append(.issue(VoiceAudioIssueMessage.formatUnavailable))
                    continue actions
                }
                guard VoiceLifecyclePolicy.shouldInstallTap(
                    format: VoiceHardwareFormat(
                        sampleRate: current.sampleRate,
                        channelCount: Int(current.channelCount),
                        route: route
                    )
                ) else {
                    out.effects.append(.issue(VoiceAudioIssueMessage.formatUnavailable))
                    out.needsFormatRetry = true
                    continue actions
                }
                graph.installTap(format: current)
                out.tapInstalled = true
                out.installedSampleRate = current.sampleRate
                out.installedChannelCount = current.channelCount
                out.log.append(("tap.install", "rate=\(current.sampleRate) ch=\(current.channelCount)"))
            case .recreateRecognizer, .dropPendingPlayback, .showAudioIssue, .clearAudioIssue,
                 .disableSpeechBargeIn, .deactivateSession:
                out.effects.append(.action(action))
            }
        }
        return out
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = "\(buffer.format.sampleRate)x\(buffer.format.channelCount)->\(format.sampleRate)x\(format.channelCount):\(format.commonFormat.rawValue)"
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else if let created = AVAudioConverter(from: buffer.format, to: format) {
            converters[key] = created
            converter = created
        } else {
            return nil
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil || output.frameLength == 0 { return nil }
        return output
    }

    private func notifyFirstPlayback() {
        guard !didNotifyFirstSchedule else { return }
        didNotifyFirstSchedule = true
        onFirstPlayback?()
    }

    private func noteBufferFinished() {
        if pendingBuffers > 0 {
            pendingBuffers -= 1
        }
        if pendingBuffers == 0 {
            lastPlaybackRMS = 0
            lastPlaybackEndedAt = Date()
            resumeDrainWaiters()
        }
    }

    private func resumeDrainWaiters() {
        let waiters = drainContinuations
        drainContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func installSessionObservers() {
        guard !observersInstalled, let observedEngine else { return }
        observersInstalled = true
        VoiceAudioNotificationBridge.install(engine: observedEngine)
    }

    private func scheduleFormatRetry() {
        formatRetryTask?.cancel()
        routeSettled = false
        formatRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(VoiceLifecyclePolicy.routeSettleMilliseconds))
            guard !Task.isCancelled, VoiceAudioSession.conversationActive, !isTornDown else { return }
            routeSettled = true
            requestRebuild(event: .configurationChanged, desiredAEC: VoiceRouteMonitor.shouldEnableAEC, skipIfMatching: false)
        }
    }

    #if os(iOS)
    public func handleInterruptionUserInfo(_ info: [AnyHashable: Any]?) {
        guard let info,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        VoiceAudioDebugStore.append(event: "interruption", detail: "\(type.rawValue)")
        switch type {
        case .began:
            // An active voice session gets a Stop command (one teardown via
            // the controller); otherwise just quiesce the graph.
            if !VoiceSessionControllers.routeInterruption(userInfo: info) {
                handleExternalGraphChange(event: .interruptionBegan)
            }
        case .ended:
            // Never auto-restart the mic, even with .shouldResume: the user
            // taps the mic again, and that start (or the next reply) rebuilds.
            VoiceSessionControllers.routeInterruption(userInfo: info)
            VoiceAudioDebugStore.append(event: "interruption.ended", detail: "no auto-restart")
        @unknown default:
            break
        }
    }
    #endif

    private static func int16Buffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let copyCount = min(data.count, Int(frames) * bytesPerFrame)
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress, let dst = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            memcpy(dst, src, copyCount)
        }
        return buffer
    }

    public nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let floats = buffer.floatChannelData {
            let samples = floats[0]
            var sum: Double = 0
            for index in 0..<frames {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            return sqrt(sum / Double(frames))
        }
        if let ints = buffer.int16ChannelData {
            let samples = ints[0]
            var sum: Double = 0
            for index in 0..<frames {
                let sample = Double(samples[index]) / Double(Int16.max)
                sum += sample * sample
            }
            return sqrt(sum / Double(frames))
        }
        return 0
    }
}

/// Non-Sendable AVFoundation values handed to the audio queue. Each is used
/// by exactly one queued block.
private struct UncheckedBufferBox: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
private struct UncheckedFileBox: @unchecked Sendable { let file: AVAudioFile }
private struct UncheckedContinuationBox<T>: @unchecked Sendable { let continuation: CheckedContinuation<T, Never> }

@MainActor
public enum VoiceRouteMonitor {
    /// Nonisolated: the audio queue reads the route during a graph rebuild.
    /// Tests pin the route (speaker, headphones, HFP) instead of the hardware's.
    public nonisolated(unsafe) static var routeOverrideForTesting: VoiceOutputRouteKind?

    public nonisolated static func currentKind() -> VoiceOutputRouteKind {
        if let forced = routeOverrideForTesting { return forced }
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return VoiceEchoPolicy.routeKind(
            outputPortTypes: outputs.map(\.portType.rawValue),
            outputPortNames: outputs.map(\.portName)
        )
        #else
        return .speaker
        #endif
    }

    public static var speechBargeInEnabled: Bool {
        !VoiceDuplexEngine.shared.echoCheckFailed && VoiceEchoPolicy.allowsSpeechBargeIn(
            route: currentKind(),
            acousticEchoCancellationAvailable: VoiceDuplexEngine.shared.acousticEchoCancellationAvailable
        )
    }

    /// The voice-mode line shown while speech barge-in is off on this route.
    public static var interruptHint: String? {
        VoiceInterruptHintPolicy.text(route: currentKind(), speechBargeInEnabled: speechBargeInEnabled)
    }

    public static var shouldEnableAEC: Bool {
        let route = currentKind()
        return VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: route)
            && VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(
                route: route,
                voiceProcessingAvailable: true
            )
    }

    public static func debugDescription() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        return "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) in=[\(inputs)] out=[\(outputs)]"
        #else
        return "route=\(currentKind().rawValue)"
        #endif
    }
}

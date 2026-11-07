// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AVFoundation
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// Fake audio graph whose `start()` blocks for 500 ms, like a cold
/// AVAudioEngine start with voice processing on a Bluetooth route. Every call
/// records the thread it ran on, so a test can assert no engine work ever
/// ran on the main thread.
final class BlockingFakeAudioGraph: VoiceAudioGraph, @unchecked Sendable {
    private let lock = NSLock()
    var startDelay: TimeInterval = 0.5
    private var _sampleRate: Double = 48_000
    private var running = false
    private var playing = false
    private var attached = false
    private var _calls: [String] = []
    private var _mainThreadCalls: [String] = []
    private var _tapSampleRate: Double = 0

    var sampleRate: Double {
        get { lock.withLock { _sampleRate } }
        set { lock.withLock { _sampleRate = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }
    var mainThreadCalls: [String] { lock.withLock { _mainThreadCalls } }
    var tapSampleRate: Double { lock.withLock { _tapSampleRate } }

    func resetCalls() {
        lock.withLock {
            _calls.removeAll()
            _mainThreadCalls.removeAll()
        }
    }

    /// The engine stopping by itself (configuration change); not a call.
    func simulateExternalStop() {
        lock.withLock { running = false }
    }

    private func record(_ name: String) {
        let onMain = Thread.isMainThread
        lock.withLock {
            _calls.append(name)
            if onMain { _mainThreadCalls.append(name) }
        }
    }

    var isRunning: Bool {
        record("isRunning")
        return lock.withLock { running }
    }
    var isPlayerPlaying: Bool {
        record("isPlayerPlaying")
        return lock.withLock { playing }
    }
    func inputFormat() -> AVAudioFormat? {
        record("inputFormat")
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    }
    func playerFormat() -> AVAudioFormat? {
        record("playerFormat")
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    }
    func configureIfNeeded() {
        record("configure")
        lock.withLock { attached = true }
    }
    func reconnectPlayer() { record("reconnect") }
    private var _voiceProcessing = false
    private var _dropsVoiceProcessingOnStart = 0
    private var _refusesVoiceProcessing = false
    private var _voiceProcessingWrites: [Bool] = []
    /// Every value written with `setVoiceProcessing`, in order.
    var voiceProcessingWrites: [Bool] { lock.withLock { _voiceProcessingWrites } }
    /// The next `n` engine starts turn voice processing off again, like a
    /// rebuild or route change that resets the input node.
    var dropsVoiceProcessingOnStart: Int {
        get { lock.withLock { _dropsVoiceProcessingOnStart } }
        set { lock.withLock { _dropsVoiceProcessingOnStart = newValue } }
    }
    /// True: voice processing never turns on (an I/O unit that refuses it).
    var refusesVoiceProcessing: Bool {
        get { lock.withLock { _refusesVoiceProcessing } }
        set { lock.withLock { _refusesVoiceProcessing = newValue } }
    }
    /// False models a player node attached to some other engine.
    var playerAttachedToEngine = true
    func setVoiceProcessing(_ enabled: Bool) throws {
        record("voiceProcessing")
        lock.withLock {
            _voiceProcessingWrites.append(enabled)
            _voiceProcessing = enabled && !_refusesVoiceProcessing
        }
    }
    var isVoiceProcessingEnabled: Bool { lock.withLock { _voiceProcessing } }
    var isPlayerAttachedToEngine: Bool { lock.withLock { attached } && playerAttachedToEngine }
    struct StartFailed: Error {}
    private var _failsStart = false
    /// True: start() throws, like AVAudioEngine failing to start on a dead route.
    var failsStart: Bool {
        get { lock.withLock { _failsStart } }
        set { lock.withLock { _failsStart = newValue } }
    }
    func start() throws {
        record("start")
        if failsStart { throw StartFailed() }
        Thread.sleep(forTimeInterval: startDelay)
        lock.withLock {
            running = true
            if _dropsVoiceProcessingOnStart > 0 {
                _dropsVoiceProcessingOnStart -= 1
                _voiceProcessing = false
            }
        }
    }
    func stop() {
        record("stop")
        lock.withLock { running = false; playing = false }
    }
    func installTap(format: AVAudioFormat) {
        record("installTap")
        lock.withLock { _tapSampleRate = format.sampleRate }
    }
    func removeTap() {
        record("removeTap")
        lock.withLock { _tapSampleRate = 0 }
    }
    func stopPlayer() {
        record("stopPlayer")
        lock.withLock { playing = false }
    }
    func pausePlayer() {
        record("pausePlayer")
        lock.withLock { playing = false }
    }
    func play() {
        record("play")
        lock.withLock { if running { playing = true } }
    }
    /// True: scheduled buffers stay "playing" until the test says otherwise.
    var holdsCompletions = false
    func schedule(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)?) {
        record("schedule")
        if holdsCompletions { return }
        if let completion { DispatchQueue.global().async { completion() } }
    }
    func scheduleFile(_ file: AVAudioFile, completion: @escaping () -> Void) {
        record("scheduleFile")
        DispatchQueue.global().async { completion() }
    }
}

/// Records how long the main actor goes without getting to run.
@MainActor
final class MainThreadHeartbeat {
    private var task: Task<Void, Never>?
    private var last = Date()
    private(set) var maxGap: TimeInterval = 0

    func start() {
        last = Date()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                guard let self else { return }
                let now = Date()
                self.maxGap = max(self.maxGap, now.timeIntervalSince(self.last))
                self.last = now
            }
        }
    }

    func stop() -> TimeInterval {
        task?.cancel()
        maxGap = max(maxGap, Date().timeIntervalSince(last))
        return maxGap
    }
}

/// Real controller + real duplex engine logic over the blocking fake graph.
@MainActor
final class EngineBackedPipeline: VoicePipelineBackend {
    let engine: VoiceDuplexEngine
    init(engine: VoiceDuplexEngine) { self.engine = engine }

    func startPipeline(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws {
        try await engine.prepareAsync(enableAEC: false)
        _ = await engine.ensureCaptureReady(enableAEC: false)
    }
    func silenceImmediately() { engine.silenceNow() }
    func teardownPipeline() async { await engine.teardownOffMain(deactivateSession: false) }
    var micLevel: Double { engine.currentMicRMS }
    var hasLiveAudio: Bool { engine.isEngineRunning }
}

@MainActor
final class VoiceEngineOffMainStartupTests: XCTestCase {
    private let mainBudget: TimeInterval = 0.05

    func testPrepareAsyncRunsEngineStartAndTapInstallOffMain() async throws {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        try await engine.prepareAsync(enableAEC: false)
        let gap = heartbeat.stop()

        XCTAssertTrue(fake.calls.contains("start"), "\(fake.calls)")
        XCTAssertTrue(fake.calls.contains("installTap"), "\(fake.calls)")
        XCTAssertEqual(fake.mainThreadCalls, [], "engine work ran on the main thread")
        XCTAssertLessThan(gap, mainBudget, "main thread was blocked for \(Int(gap * 1000)) ms during prepare")
        XCTAssertEqual(engine.lastRebuildRanOnMainThread, false)
        XCTAssertTrue(engine.isTapInstalledForTesting)
        XCTAssertTrue(engine.isEngineRunning)
    }

    func testControllerStartReturnsAndPublishesStartingWithin50msWhileEngineStartBlocks() async {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        let controller = VoiceSessionController(backend: EngineBackedPipeline(engine: engine))
        controller.onFailure = { _, _ in }
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()

        let began = Date()
        controller.start()
        let returned = Date().timeIntervalSince(began)
        XCTAssertLessThan(returned, mainBudget, "start() took \(Int(returned * 1000)) ms to return")
        XCTAssertEqual(controller.state, .starting, "Starting must be published on the tap")

        await controller.waitUntilSettled()
        let gap = heartbeat.stop()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(fake.calls.contains("start"))
        XCTAssertEqual(fake.mainThreadCalls, [], "engine work ran on the main thread")
        XCTAssertLessThan(gap, mainBudget, "main thread was blocked for \(Int(gap * 1000)) ms while the engine started")

        controller.stop()
        await controller.waitUntilSettled()
    }

    func testRouteChangeTo16kHFPRebuildsGraphOffMain() async throws {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        let rebuildsBefore = engine.graphRebuildCount
        fake.resetCalls()
        fake.sampleRate = 16_000

        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let began = Date()
        engine.handleExternalGraphChange(event: .routeChanged)
        let returned = Date().timeIntervalSince(began)
        await engine.waitUntilGraphIdle()
        let gap = heartbeat.stop()

        XCTAssertLessThan(returned, mainBudget, "route change handler blocked for \(Int(returned * 1000)) ms")
        XCTAssertEqual(engine.graphRebuildCount, rebuildsBefore + 1)
        XCTAssertEqual(fake.tapSampleRate, 16_000, "tap must be reinstalled with the new hardware rate")
        XCTAssertEqual(fake.mainThreadCalls, [], "rebuild ran engine work on the main thread")
        XCTAssertLessThan(gap, mainBudget, "main thread was blocked for \(Int(gap * 1000)) ms during the rebuild")
    }

    func testEnsureCaptureReadyHealsAStoppedEngineOffMain() async throws {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        fake.simulateExternalStop()
        fake.resetCalls()

        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let ready = await engine.ensureCaptureReady(enableAEC: false)
        let gap = heartbeat.stop()

        XCTAssertTrue(ready)
        XCTAssertTrue(fake.calls.contains("start"), "\(fake.calls)")
        XCTAssertEqual(fake.mainThreadCalls, [], "heal ran engine work on the main thread")
        XCTAssertLessThan(gap, mainBudget, "main thread was blocked for \(Int(gap * 1000)) ms during heal")
    }

    func testTeardownQueuedBehindAnInFlightStartRunsAfterItAndWins() async throws {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        let starting = Task { @MainActor in try await engine.prepareAsync(enableAEC: false) }
        try? await Task.sleep(for: .milliseconds(50))
        await engine.teardownOffMain(deactivateSession: false)
        _ = try? await starting.value
        await engine.waitUntilGraphIdle()

        let calls = fake.calls
        let startIndex = calls.firstIndex(of: "start") ?? -1
        let stopIndex = calls.lastIndex(of: "stop") ?? -1
        XCTAssertGreaterThan(stopIndex, startIndex, "teardown must run after the start it was queued behind: \(calls)")
        XCTAssertFalse(engine.isEngineRunning, "a start finishing after teardown must not resurrect the state")
        XCTAssertFalse(engine.isEngineActuallyRunning)
        XCTAssertEqual(fake.mainThreadCalls.filter { $0 != "isRunning" }, [])
    }

    /// Rebuilds are async now: reply audio scheduled while one is in flight
    /// must queue behind it on the audio queue, not be dropped.
    func testAudioScheduledDuringAnInFlightRebuildIsNotDropped() async throws {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        fake.sampleRate = 16_000
        engine.handleExternalGraphChange(event: .routeChanged) // 500 ms rebuild in flight
        fake.resetCalls()

        engine.schedule(pcmData: Data(count: 4_800), sampleRate: 24_000)
        XCTAssertTrue(engine.isPlayingBack, "buffer scheduled during a rebuild was dropped")
        await engine.waitUntilGraphIdle()
        XCTAssertTrue(fake.calls.contains("schedule"), "\(fake.calls)")
        XCTAssertEqual(fake.mainThreadCalls, [])
    }

    /// Regression: the rebuild outcome lost the player format, so every
    /// reply buffer after a prepare was silently dropped.
    func testReplyAudioPlaysAfterPrepare() async throws {
        let fake = BlockingFakeAudioGraph()
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        fake.resetCalls()
        engine.schedule(pcmData: Data(count: 4_800), sampleRate: 24_000)
        XCTAssertTrue(engine.isPlayingBack, "reply buffer was dropped after prepare")
        await engine.waitUntilGraphIdle()
        XCTAssertTrue(fake.calls.contains("schedule"), "\(fake.calls)")
    }

    /// Regression: file-based reply audio (AudioPlaybackService) was queued
    /// on a graph that had stopped behind our back, so it never played.
    func testCompressedReplyRestartsAStoppedGraphBeforeScheduling() async throws {
        let fake = BlockingFakeAudioGraph()
        fake.startDelay = 0
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        fake.simulateExternalStop() // configuration change stopped the engine
        fake.resetCalls()

        engine.scheduleCompressed(data: try Self.tinyWAV())
        await engine.waitUntilGraphIdle()
        let calls = fake.calls
        guard let fileAt = calls.firstIndex(of: "scheduleFile") else {
            return XCTFail("compressed reply was never scheduled: \(calls)")
        }
        XCTAssertNotNil(calls[..<fileAt].firstIndex(of: "start"), "graph not restarted before scheduleFile: \(calls)")
    }

    /// Regression: if the graph wouldn't restart, the file was scheduled on a stopped engine,
    /// its completion never fired, pendingBuffers stayed > 0 and isPlayingBack kept the mic shut.
    func testCompressedReplyOnAGraphThatWontStartFinishesAndReports() async throws {
        let fake = BlockingFakeAudioGraph()
        fake.startDelay = 0
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        engine.reportAudioIssue(nil)
        fake.simulateExternalStop()
        fake.failsStart = true
        fake.resetCalls()

        engine.scheduleCompressed(data: try Self.tinyWAV())
        await engine.waitUntilGraphIdle()
        for _ in 0..<50 where engine.hasPendingPlayback { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertFalse(fake.calls.contains("scheduleFile"), "scheduled on a stopped engine: \(fake.calls)")
        XCTAssertFalse(engine.hasPendingPlayback, "pendingBuffers never reached 0")
        XCTAssertFalse(engine.isPlayingBack, "isPlayingBack stuck true keeps the mic shut")
        XCTAssertEqual(engine.lastAudioIssue, VoiceAudioIssueMessage.graphRebuildFailed)
        if !engine.hasPendingPlayback { await engine.waitUntilFinished() } // returns at once when drained
    }

    private static func tinyWAV() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400)!
            buffer.frameLength = 2_400
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}

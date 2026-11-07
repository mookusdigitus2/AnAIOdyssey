// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// Fake audio pipeline with a deliberately slow teardown (500 ms, like a real
/// `engine.stop()` + `setActive(false)` on a Bluetooth route). The slow part
/// runs off the main thread, the way the real engine teardown now does.
@MainActor
final class SlowFakeVoicePipeline: VoicePipelineBackend {
    var events: [String] = []
    var startDelay: Duration = .milliseconds(0)
    var teardownDelay: TimeInterval = 0.5
    var startError: Error?
    private(set) var startCount = 0
    private(set) var teardownCount = 0
    private(set) var micOpen = false
    private(set) var lastOnEvent: (@MainActor (VoiceInputEvent) -> Void)?
    private let audioQueue = DispatchQueue(label: "fake-audio")

    func startPipeline(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws {
        startCount += 1
        events.append("start.begin")
        lastOnEvent = onEvent
        try? await Task.sleep(for: startDelay)
        if let startError {
            events.append("start.failed")
            micOpen = true // partially opened before failing
            throw startError
        }
        micOpen = true
        events.append("start.done")
    }

    func silenceImmediately() {
        events.append("silence")
    }

    func teardownPipeline() async {
        teardownCount += 1
        events.append("teardown.begin")
        let delay = teardownDelay
        let steps: [String] = await withCheckedContinuation { continuation in
            audioQueue.asyncAfter(deadline: .now() + delay) {
                // Same order as the engine: stop, remove tap, deactivate last.
                continuation.resume(returning: ["engine.stop", "tap.remove", "session.deactivate"])
            }
        }
        events += steps
        micOpen = false
    }

    var micLevel: Double { micOpen ? 0.05 : 0 }
    var hasLiveAudio: Bool { micOpen }
}

private struct FakeStartError: LocalizedError {
    var errorDescription: String? { "Microphone unavailable" }
}

@MainActor
final class VoiceSessionControllerTests: XCTestCase {
    private func makeController(_ fake: SlowFakeVoicePipeline) -> VoiceSessionController {
        let controller = VoiceSessionController(backend: fake)
        controller.onFailure = { _, _ in }
        return controller
    }

    private func startListening(_ controller: VoiceSessionController) async {
        controller.start()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .listening)
    }

    func testMicTapShowsStartingImmediately() {
        let fake = SlowFakeVoicePipeline()
        fake.startDelay = .milliseconds(300)
        let controller = makeController(fake)
        controller.toggleMic()
        XCTAssertEqual(controller.state, .starting, "the button must flip to Starting on the tap itself")
    }

    func testStopReturnsWithin50msAndStateIsIdleImmediately() async {
        let fake = SlowFakeVoicePipeline()
        let controller = makeController(fake)
        await startListening(controller)

        let began = Date()
        controller.stop()
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertLessThan(elapsed, 0.05, "Stop must not wait for the 500 ms teardown")
        XCTAssertEqual(controller.state, .idle, "UI state must be idle on the Stop tap")
        XCTAssertEqual(fake.events.last, "silence", "playback/mic must be cut synchronously")
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.teardownCount, 1)
        XCTAssertFalse(fake.micOpen)
    }

    func testLeaveDuringSpeechReturnsWithin50ms() async {
        let fake = SlowFakeVoicePipeline()
        let controller = makeController(fake)
        await startListening(controller)
        fake.lastOnEvent?(.utterance(VoiceUtterance(id: 1, text: "tell me a story")))
        controller.replyStarted()
        XCTAssertEqual(controller.state, .speaking)

        let began = Date()
        controller.leave()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.05, "Back must never wait on audio teardown")
        XCTAssertEqual(controller.state, .idle)
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.teardownCount, 1)
        XCTAssertFalse(fake.micOpen)
    }

    func testTeardownRunsExactlyOncePerSession() async {
        let fake = SlowFakeVoicePipeline()
        fake.teardownDelay = 0.1
        let controller = makeController(fake)
        await startListening(controller)

        controller.stop()
        controller.stop()
        controller.leave()
        controller.enterBackground()
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.teardownCount, 1, "Stop + Back + background for one session must tear down once")

        await startListening(controller)
        controller.leave()
        controller.stop()
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.teardownCount, 2)
    }

    func testDeactivateComesAfterEngineStopAndTapRemoval() async {
        let fake = SlowFakeVoicePipeline()
        fake.teardownDelay = 0.05
        let controller = makeController(fake)
        await startListening(controller)
        controller.stop()
        await controller.waitUntilSettled()
        let stop = try? XCTUnwrap(fake.events.firstIndex(of: "engine.stop"))
        let tap = try? XCTUnwrap(fake.events.firstIndex(of: "tap.remove"))
        let deactivate = try? XCTUnwrap(fake.events.firstIndex(of: "session.deactivate"))
        XCTAssertNotNil(stop); XCTAssertNotNil(tap); XCTAssertNotNil(deactivate)
        if let stop, let tap, let deactivate {
            XCTAssertLessThan(stop, deactivate)
            XCTAssertLessThan(tap, deactivate)
        }
    }

    func testNextStartWaitsForPreviousTeardownToFinish() async {
        let fake = SlowFakeVoicePipeline()
        fake.teardownDelay = 0.2
        let controller = makeController(fake)
        await startListening(controller)
        controller.stop()
        controller.start()
        await controller.waitUntilSettled()
        let deactivate = fake.events.firstIndex(of: "session.deactivate")
        let secondStart = fake.events.lastIndex(of: "start.begin")
        XCTAssertNotNil(deactivate)
        if let deactivate, let secondStart {
            XCTAssertLessThan(deactivate, secondStart, "audio calls must never overlap: start runs after teardown")
        }
        XCTAssertEqual(controller.state, .listening)
    }

    func testStopDuringStartNeverLeavesMicOpen() async {
        let fake = SlowFakeVoicePipeline()
        fake.startDelay = .milliseconds(300)
        fake.teardownDelay = 0.05
        let controller = makeController(fake)
        controller.start()
        // Let the start op begin, then stop while it is still in flight.
        while !fake.events.contains("start.begin") { await Task.yield() }
        controller.stop()
        XCTAssertEqual(controller.state, .idle)

        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .idle, "a late start completion must not flip back to listening")
        XCTAssertFalse(fake.micOpen, "a superseded start must never leave the mic open")
        XCTAssertEqual(fake.teardownCount, 1)
    }

    func testDoubleStartOnlyStartsOneSession() async {
        let fake = SlowFakeVoicePipeline()
        fake.startDelay = .milliseconds(100)
        let controller = makeController(fake)
        controller.start()
        controller.start()
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testSecondTapWhileStartingCancels() async {
        let fake = SlowFakeVoicePipeline()
        fake.startDelay = .milliseconds(200)
        fake.teardownDelay = 0.05
        let controller = makeController(fake)
        controller.toggleMic()
        controller.toggleMic()
        XCTAssertEqual(controller.state, .idle)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertLessThanOrEqual(fake.startCount, 1, "double-tap must not start two pipelines")
        XCTAssertFalse(fake.micOpen)
    }

    func testMicTapDuringCleanupQueuesStart() async {
        let fake = SlowFakeVoicePipeline()
        let controller = makeController(fake)
        await startListening(controller)
        controller.stop()
        XCTAssertTrue(controller.isCleaningUp)

        controller.toggleMic()
        XCTAssertEqual(controller.state, .starting, "tap during cleanup is queued, not ignored or grayed out")
        XCTAssertEqual(fake.startCount, 1, "the queued start waits for teardown")

        await controller.waitUntilSettled()
        XCTAssertEqual(fake.startCount, 2)
        XCTAssertEqual(fake.teardownCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(fake.micOpen)
    }

    func testUtteranceFromStoppedSessionIsDropped() async {
        let fake = SlowFakeVoicePipeline()
        fake.teardownDelay = 0.01
        let controller = makeController(fake)
        var heard: [String] = []
        controller.onTurn = { heard.append($0.text); return true }
        await startListening(controller)
        fake.lastOnEvent?(.utterance(VoiceUtterance(id: 1, text: "hello")))
        XCTAssertEqual(heard, ["hello"])
        controller.stop()
        fake.lastOnEvent?(.utterance(VoiceUtterance(id: 2, text: "late words")))
        XCTAssertEqual(heard, ["hello"], "recognizer output after Stop must not send a message")
        await controller.waitUntilSettled()
    }

    func testStartFailureReportsAndCleansUpWithoutAlert() async {
        let fake = SlowFakeVoicePipeline()
        fake.startError = FakeStartError()
        fake.teardownDelay = 0.01
        let controller = makeController(fake)
        var reported: [(String, Bool)] = []
        controller.onFailure = { message, canRetry in reported.append((message, canRetry)) }
        controller.start()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .error("Microphone unavailable"))
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(fake.teardownCount, 1, "a half-open pipeline is torn down")
        XCTAssertFalse(fake.micOpen)
    }

    func testStateStreamPublishesTransitions() async {
        let fake = SlowFakeVoicePipeline()
        fake.teardownDelay = 0.01
        let controller = makeController(fake)
        let stream = controller.states()
        let collector = Task { @MainActor () -> [VoiceSessionState] in
            var seen: [VoiceSessionState] = []
            for await next in stream {
                seen.append(next)
                if seen.count == 4 { break }
            }
            return seen
        }
        controller.start()
        await controller.waitUntilSettled()
        controller.stop()
        await controller.waitUntilSettled()
        let timeout = Task { try? await Task.sleep(for: .seconds(2)); collector.cancel() }
        let seen = await collector.value
        timeout.cancel()
        XCTAssertEqual(seen, [.idle, .starting, .listening, .idle])
        XCTAssertFalse(seen.contains { "\($0)".contains("stopping") })
    }
}

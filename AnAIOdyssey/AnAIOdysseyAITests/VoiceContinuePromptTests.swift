// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AVFoundation
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// Engine side of the prompt: pause keeps buffering, resume plays it all.
@MainActor
final class VoiceEnginePausePlaybackTests: XCTestCase {
    private func makeEngine() async throws -> (BlockingFakeAudioGraph, VoiceDuplexEngine) {
        let fake = BlockingFakeAudioGraph()
        fake.startDelay = 0
        fake.holdsCompletions = true
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        return (fake, engine)
    }

    func testPauseKeepsBufferingIncomingAudioWithoutPlaying() async throws {
        let (fake, engine) = try await makeEngine()
        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000) // 1 s
        engine.pausePlayback()
        await engine.waitUntilGraphIdle()
        fake.resetCalls()

        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000) // arrives while paused
        try engine.start() // PCMStreamPlayer calls this before every chunk
        await engine.waitUntilGraphIdle()

        XCTAssertTrue(engine.isPlaybackPaused)
        XCTAssertTrue(engine.hasPendingPlayback, "paused audio must be kept")
        XCTAssertFalse(engine.isPlayingBack, "the mic gate treats a paused reply as quiet")
        XCTAssertTrue(fake.calls.contains("schedule"), "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains("play"), "nothing may un-pause the player: \(fake.calls)")
    }

    func testPauseCallsPausePlayerNotStop() async throws {
        let (fake, engine) = try await makeEngine()
        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000)
        await engine.waitUntilGraphIdle()
        fake.resetCalls()
        engine.pausePlayback()
        await engine.waitUntilGraphIdle()
        XCTAssertEqual(fake.calls.filter { $0 == "pausePlayer" || $0 == "stopPlayer" }, ["pausePlayer"])
    }

    func testResumePlaysFromThePausePoint() async throws {
        let (fake, engine) = try await makeEngine()
        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000)
        engine.pausePlayback()
        await engine.waitUntilGraphIdle()
        fake.resetCalls()

        engine.resumePlayback()
        await engine.waitUntilGraphIdle()
        XCTAssertFalse(engine.isPlaybackPaused)
        XCTAssertTrue(fake.calls.contains("play"), "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains("stopPlayer"), "resume must not drop the buffered audio")
    }

    func testDiscardWhilePausedDropsAudioAndClearsPause() async throws {
        let (fake, engine) = try await makeEngine()
        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000)
        engine.pausePlayback()
        await engine.waitUntilGraphIdle()
        fake.resetCalls()

        engine.stopPlayback()
        await engine.waitUntilGraphIdle()
        XCTAssertFalse(engine.isPlaybackPaused)
        XCTAssertFalse(engine.hasPendingPlayback)
        XCTAssertTrue(fake.calls.contains("stopPlayer"))
    }

    func testListeningCueIsSilentWhileReplyAudioIsPending() {
        XCTAssertFalse(VoiceListeningCue.shouldPlay(replyAudioPending: true), "no earcon over or behind a paused reply")
        XCTAssertTrue(VoiceListeningCue.shouldPlay(replyAudioPending: false))
    }
}

/// The turn earcon: quieter (half the gain) and an octave lower.
final class VoiceListeningCueToneTests: XCTestCase {
    func testCueIsAnOctaveLowerAndHalfAsLoud() {
        XCTAssertEqual(VoiceListeningCue.frequency, 392, accuracy: 0.001)
        XCTAssertEqual(VoiceListeningCue.peak, 0.08, accuracy: 0.0001)
        XCTAssertEqual(VoiceListeningCue.playerVolume, 0.175, accuracy: 0.0001)
    }

    func testGeneratedToneNeverExceedsTheNewPeak() throws {
        let pcm = try XCTUnwrap(VoiceListeningCue.tonePCM())
        let maxSample = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0
        }
        let limit = Int((0.08 * Double(Int16.max)).rounded())
        XCTAssertLessThanOrEqual(maxSample, limit)
        XCTAssertGreaterThan(maxSample, limit * 9 / 10)
    }
}

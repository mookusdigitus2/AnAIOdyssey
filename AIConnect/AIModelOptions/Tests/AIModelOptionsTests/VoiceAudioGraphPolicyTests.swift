// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceAudioGraphPolicyTests: XCTestCase {
    func testHFP16kMonoRebuildUsesFreshFormatAndInstallsTapOnce() {
        var simulator = runningSpeakerGraph()
        let step = simulator.apply(.routeChanged, format: .hfp16kMono)

        XCTAssertTrue(step.actions.contains(.stopEngine))
        XCTAssertTrue(step.actions.contains(.removeTap))
        XCTAssertTrue(step.actions.contains(.applyVoiceProcessing))
        XCTAssertTrue(step.actions.contains(.reconnectNodes))
        XCTAssertTrue(step.actions.contains(.startEngine))
        XCTAssertTrue(step.actions.contains(.installTap))
        XCTAssertEqual(step.actions.filter { $0 == .installTap }.count, 1)
        XCTAssertEqual(simulator.snapshot.format, .hfp16kMono)
        XCTAssertEqual(simulator.snapshot.tapFormat, .hfp16kMono)
        XCTAssertTrue(
            VoiceAudioGraphPolicy.tapFormatMustMatchHardware(
                tap: simulator.snapshot.tapFormat,
                hardware: .hfp16kMono
            )
        )
        XCTAssertFalse(simulator.snapshot.usedStaleFormat)
        XCTAssertEqual(simulator.snapshot.tapInstallCount, 2)
        XCTAssertEqual(simulator.snapshot.tapRemoveCount, 1)
        XCTAssertFalse(simulator.snapshot.speechBargeInEnabled)
        XCTAssertEqual(simulator.snapshot.lastIssue, VoiceAudioIssueMessage.voiceProcessingUnavailable)
    }

    func testHFP8kMonoRebuildUsesFreshFormat() {
        var simulator = runningSpeakerGraph()
        simulator.apply(.configurationChanged, format: .hfp8kMono)

        XCTAssertEqual(simulator.snapshot.format?.sampleRate, 8_000)
        XCTAssertEqual(simulator.snapshot.format?.channelCount, 1)
        XCTAssertEqual(simulator.snapshot.tapFormat, .hfp8kMono)
        XCTAssertTrue(simulator.snapshot.tapInstalled)
        XCTAssertFalse(simulator.snapshot.usedStaleFormat)
        XCTAssertFalse(simulator.snapshot.speechBargeInEnabled)
    }

    func testA2DP48kStereoRequiresTTSConversion() {
        var simulator = runningSpeakerGraph()
        simulator.apply(.routeChanged, format: .a2dp48kStereo)

        XCTAssertEqual(simulator.snapshot.format, .a2dp48kStereo)
        XCTAssertEqual(simulator.snapshot.tapFormat?.channelCount, 2)
        XCTAssertTrue(
            VoiceAudioGraphPolicy.ttsNeedsConversion(
                sourceSampleRate: 24_000,
                sourceChannels: 1,
                mixer: .a2dp48kStereo
            )
        )
        XCTAssertTrue(
            VoiceAudioGraphPolicy.ttsNeedsConversion(
                sourceSampleRate: 48_000,
                sourceChannels: 1,
                mixer: .a2dp48kStereo
            )
        )
        XCTAssertFalse(
            VoiceAudioGraphPolicy.ttsNeedsConversion(
                sourceSampleRate: 48_000,
                sourceChannels: 2,
                mixer: .a2dp48kStereo
            )
        )
        XCTAssertTrue(simulator.snapshot.speechBargeInEnabled)
    }

    func testSpeaker48kKeepsAECAndBargeIn() {
        var simulator = VoiceAudioGraphSimulator()
        simulator.apply(.start, format: .speaker48k)

        XCTAssertEqual(simulator.snapshot.phase, .running)
        XCTAssertTrue(simulator.snapshot.voiceProcessingEnabled)
        XCTAssertTrue(simulator.snapshot.speechBargeInEnabled)
        XCTAssertTrue(simulator.snapshot.tapInstalled)
        XCTAssertEqual(simulator.snapshot.tapFormat, .speaker48k)
        XCTAssertFalse(
            VoiceAudioGraphPolicy.ttsNeedsConversion(
                sourceSampleRate: 48_000,
                sourceChannels: 1,
                mixer: .speaker48k
            )
        )
        XCTAssertTrue(
            VoiceAudioGraphPolicy.ttsNeedsConversion(
                sourceSampleRate: 24_000,
                sourceChannels: 1,
                mixer: .speaker48k
            )
        )
    }

    func testRapidBackToBackChangesCoalesceToOneRebuild() {
        let burst: [VoiceAudioGraphEvent] = [
            .routeChanged,
            .configurationChanged,
            .routeChanged,
            .configurationChanged,
        ]
        XCTAssertEqual(
            VoiceAudioGraphPolicy.coalesce(burst),
            [.configurationChanged]
        )

        var simulator = runningSpeakerGraph()
        let installsBefore = simulator.snapshot.tapInstallCount
        simulator.applyRapid(burst, format: .hfp16kMono)

        XCTAssertEqual(simulator.snapshot.tapInstallCount, installsBefore + 1)
        XCTAssertEqual(simulator.snapshot.tapRemoveCount, 1)
        XCTAssertEqual(simulator.snapshot.tapFormat, .hfp16kMono)
        XCTAssertFalse(simulator.snapshot.usedStaleFormat)
    }

    func testRouteChangeMidPlaybackDropsPendingBuffers() {
        var simulator = runningSpeakerGraph()
        simulator.snapshot.pendingPlayback = true
        let step = simulator.apply(.routeChanged, format: .hfp16kMono)

        XCTAssertTrue(step.actions.contains(.dropPendingPlayback))
        XCTAssertFalse(simulator.snapshot.pendingPlayback)
        XCTAssertTrue(simulator.snapshot.tapInstalled)
        XCTAssertEqual(simulator.snapshot.tapFormat, .hfp16kMono)
    }

    func testRouteChangeMidListeningRecreatesRecognizer() {
        var simulator = runningSpeakerGraph()
        simulator.snapshot.isListening = true
        let generation = simulator.snapshot.recognizerGeneration
        let step = simulator.apply(.routeChanged, format: .hfp16kMono)

        XCTAssertTrue(step.actions.contains(.recreateRecognizer))
        XCTAssertEqual(simulator.snapshot.recognizerGeneration, generation + 1)
        XCTAssertFalse(
            VoiceAudioGraphPolicy.shouldReuseRecognizer(
                previousFormat: .speaker48k,
                incomingFormat: .hfp16kMono
            )
        )
        XCTAssertTrue(
            VoiceAudioGraphPolicy.shouldReuseRecognizer(
                previousFormat: .hfp16kMono,
                incomingFormat: .hfp16kMono
            )
        )
    }

    func testVoiceProcessingThrowFallsBackToNoAEC() {
        var simulator = VoiceAudioGraphSimulator(voiceProcessingThrows: true)
        simulator.apply(.start, format: .speaker48k)

        XCTAssertTrue(simulator.snapshot.voiceProcessingFailed)
        XCTAssertFalse(simulator.snapshot.voiceProcessingEnabled)
        XCTAssertFalse(simulator.snapshot.speechBargeInEnabled)
        XCTAssertEqual(simulator.snapshot.voiceProcessingAppliedWhileRunning, 0)
        XCTAssertEqual(simulator.snapshot.lastIssue, VoiceAudioIssueMessage.voiceProcessingUnavailable)
    }

    func testNeverInstallsTapTwiceWithoutRemove() {
        var simulator = runningSpeakerGraph()
        let first = simulator.apply(.routeChanged, format: .hfp16kMono)
        XCTAssertTrue(first.actions.contains(.removeTap))
        let removeIndex = first.actions.firstIndex(of: .removeTap)!
        let installIndex = first.actions.firstIndex(of: .installTap)!
        XCTAssertLessThan(removeIndex, installIndex)

        simulator.apply(.configurationChanged, format: .hfp8kMono)
        XCTAssertEqual(simulator.snapshot.tapInstallCount, simulator.snapshot.tapRemoveCount + 1)
        XCTAssertTrue(simulator.snapshot.tapInstalled)
        XCTAssertEqual(simulator.snapshot.tapFormat, .hfp8kMono)
    }

    func testNeverAppliesVoiceProcessingWhileRunning() {
        var simulator = runningSpeakerGraph()
        let step = simulator.apply(.routeChanged, format: .hfp16kMono)
        let stopIndex = step.actions.firstIndex(of: .stopEngine)!
        let vpIndex = step.actions.firstIndex(of: .applyVoiceProcessing)!
        let startIndex = step.actions.firstIndex(of: .startEngine)!
        XCTAssertLessThan(stopIndex, vpIndex)
        XCTAssertLessThan(vpIndex, startIndex)
        XCTAssertEqual(simulator.snapshot.voiceProcessingAppliedWhileRunning, 0)
    }

    func testCachedFormatMismatchIsRejected() {
        XCTAssertFalse(
            VoiceAudioGraphPolicy.tapFormatMustMatchHardware(
                tap: .speaker48k,
                hardware: .hfp16kMono
            )
        )
        XCTAssertFalse(
            VoiceAudioGraphPolicy.tapFormatMustMatchHardware(
                tap: .hfp16kMono,
                hardware: .hfp8kMono
            )
        )
        XCTAssertFalse(
            VoiceAudioGraphPolicy.tapFormatMustMatchHardware(
                tap: .speaker48k,
                hardware: .a2dp48kStereo
            )
        )
        XCTAssertTrue(
            VoiceAudioGraphPolicy.tapFormatMustMatchHardware(
                tap: .hfp16kMono,
                hardware: .hfp16kMono
            )
        )
    }

    func testSessionOptionsIncludeBluetoothHFPAndA2DP() {
        XCTAssertEqual(VoiceAudioSessionPolicy.requiredCategory, "playAndRecord")
        XCTAssertEqual(VoiceAudioSessionPolicy.requiredMode, "voiceChat")
        XCTAssertTrue(
            VoiceAudioSessionPolicy.containsRequiredOptions([
                "allowBluetooth",
                "allowBluetoothA2DP",
                "defaultToSpeaker",
            ])
        )
        XCTAssertFalse(
            VoiceAudioSessionPolicy.containsRequiredOptions(["defaultToSpeaker", "allowBluetoothHFP"])
        )
        XCTAssertFalse(VoiceAudioSessionPolicy.allowsForceTrySetActive())
    }

    func testInvalidFormatShowsIssueAndDoesNotInstallTap() {
        var simulator = runningSpeakerGraph()
        let invalid = VoiceHardwareFormat(sampleRate: 0, channelCount: 0, route: .bluetoothHFP)
        simulator.apply(.routeChanged, format: invalid)

        XCTAssertFalse(simulator.snapshot.tapInstalled)
        XCTAssertFalse(simulator.snapshot.engineRunning)
        XCTAssertEqual(simulator.snapshot.lastIssue, VoiceAudioIssueMessage.formatUnavailable)
    }

    func testInterruptionStopsThenRebuildsOnEnd() {
        var simulator = runningSpeakerGraph()
        simulator.snapshot.pendingPlayback = true
        let began = simulator.apply(.interruptionBegan, format: .speaker48k)
        XCTAssertTrue(began.actions.contains(.stopEngine))
        XCTAssertTrue(began.actions.contains(.removeTap))
        XCTAssertFalse(simulator.snapshot.engineRunning)
        XCTAssertFalse(simulator.snapshot.tapInstalled)

        let ended = simulator.apply(.interruptionEnded, format: .speaker48k)
        XCTAssertTrue(ended.actions.contains(.applyVoiceProcessing))
        XCTAssertTrue(ended.actions.contains(.startEngine))
        XCTAssertTrue(ended.actions.contains(.installTap))
        XCTAssertTrue(simulator.snapshot.engineRunning)
        XCTAssertTrue(simulator.snapshot.tapInstalled)
    }

    func testStopRemovesTapAndClearsIssue() {
        var simulator = runningSpeakerGraph()
        simulator.apply(.stop, format: .speaker48k)
        XCTAssertEqual(simulator.snapshot.phase, .idle)
        XCTAssertFalse(simulator.snapshot.tapInstalled)
        XCTAssertFalse(simulator.snapshot.engineRunning)
        XCTAssertNil(simulator.snapshot.lastIssue)
    }

    func testHFPSkipsVoiceProcessingAndCarAudioIsHFP() {
        XCTAssertEqual(VoiceEchoPolicy.routeKind(outputPortTypes: ["CarAudio"]), .bluetoothHFP)
        var simulator = runningSpeakerGraph()
        XCTAssertTrue(simulator.snapshot.voiceProcessingEnabled)
        simulator.apply(.routeChanged, format: .hfp16kMono)
        XCTAssertFalse(simulator.snapshot.voiceProcessingEnabled)
        XCTAssertFalse(simulator.snapshot.speechBargeInEnabled)
        XCTAssertFalse(
            VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: .bluetoothHFP)
        )
    }

    func testHardwareFormatValidity() {
        XCTAssertTrue(VoiceHardwareFormat.speaker48k.isValid)
        XCTAssertTrue(VoiceHardwareFormat.hfp16kMono.isValid)
        XCTAssertTrue(VoiceHardwareFormat.hfp8kMono.isValid)
        XCTAssertTrue(VoiceHardwareFormat.a2dp48kStereo.isValid)
        XCTAssertFalse(VoiceHardwareFormat(sampleRate: 0, channelCount: 1, route: .speaker).isValid)
        XCTAssertFalse(VoiceHardwareFormat(sampleRate: 16_000, channelCount: 0, route: .bluetoothHFP).isValid)
    }

    // MARK: - Helpers

    private func runningSpeakerGraph() -> VoiceAudioGraphSimulator {
        var simulator = VoiceAudioGraphSimulator()
        simulator.apply(.start, format: .speaker48k)
        simulator.snapshot.recognizerGeneration = 1
        return simulator
    }
}

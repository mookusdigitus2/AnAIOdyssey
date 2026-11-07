// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceEchoPolicyTests: XCTestCase {
    func testSpeakerRouteEnablesAECAndSpeechBargeInWhenProcessingWorks() {
        XCTAssertEqual(
            VoiceEchoPolicy.routeKind(outputPortTypes: ["Speaker"]),
            .speaker
        )
        XCTAssertTrue(
            VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(
                route: .speaker,
                voiceProcessingAvailable: true
            )
        )
        XCTAssertTrue(
            VoiceEchoPolicy.allowsSpeechBargeIn(
                route: .speaker,
                acousticEchoCancellationAvailable: true
            )
        )
        XCTAssertFalse(
            VoiceEchoPolicy.allowsSpeechBargeIn(
                route: .speaker,
                acousticEchoCancellationAvailable: false
            )
        )
        XCTAssertFalse(VoiceEchoPolicy.shouldShowInterruptHint(speechBargeInEnabled: true))
        XCTAssertTrue(VoiceEchoPolicy.shouldShowInterruptHint(speechBargeInEnabled: false))
    }

    func testHeadphonesAndAirPodsKeepSpeechBargeInOn() {
        XCTAssertEqual(VoiceEchoPolicy.routeKind(outputPortTypes: ["Headphones"]), .headphones)
        XCTAssertEqual(VoiceEchoPolicy.routeKind(outputPortTypes: ["BluetoothA2DP"]), .headphones)
        XCTAssertEqual(VoiceEchoPolicy.routeKind(outputPortTypes: ["BluetoothLE"]), .headphones)
        XCTAssertEqual(VoiceEchoPolicy.routeKind(outputPortTypes: ["USBAudio"]), .headphones)
        XCTAssertEqual(
            VoiceEchoPolicy.routeKind(
                outputPortTypes: ["BluetoothHFP"],
                outputPortNames: ["AirPods Pro"]
            ),
            .headphones
        )
        XCTAssertTrue(
            VoiceEchoPolicy.allowsSpeechBargeIn(
                route: .headphones,
                acousticEchoCancellationAvailable: false
            )
        )
    }

    func testBluetoothHFPWithoutHeadphoneNameGetsEchoProtection() {
        XCTAssertEqual(
            VoiceEchoPolicy.routeKind(
                outputPortTypes: ["BluetoothHFP"],
                outputPortNames: ["CarPlay"]
            ),
            .bluetoothHFP
        )
        XCTAssertEqual(VoiceEchoPolicy.routeKind(outputPortTypes: ["CarAudio"]), .bluetoothHFP)
        XCTAssertFalse(
            VoiceEchoPolicy.allowsSpeechBargeIn(
                route: .bluetoothHFP,
                acousticEchoCancellationAvailable: true
            )
        )
        XCTAssertTrue(VoiceEchoPolicy.shouldShowInterruptHint(speechBargeInEnabled: false))
    }

    func testMacWithoutVoiceProcessingDisablesSpeakerBargeIn() {
        XCTAssertFalse(
            VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(
                route: .speaker,
                voiceProcessingAvailable: false
            )
        )
        XCTAssertFalse(
            VoiceEchoPolicy.allowsSpeechBargeIn(
                route: .unknown,
                acousticEchoCancellationAvailable: false
            )
        )
    }
}

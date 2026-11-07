// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceLibraryBannerStateTests: XCTestCase {
    func testSuccessBannerSelectsVoiceWithoutRetry() {
        let b = VoiceLibraryBannerState.added(voiceID: "v", name: "Narrator")
        XCTAssertEqual(b.message, "Added Narrator and set it as your voice")
        XCTAssertFalse(b.showsRetry)
        XCTAssertTrue(b.selectsVoice)
    }

    func testFailureBannerOffersRetryAndDoesNotSelect() {
        let b = VoiceLibraryBannerState.failed(voiceID: "v", name: "Narrator", message: "Paid plan needed")
        XCTAssertTrue(b.showsRetry)
        XCTAssertFalse(b.selectsVoice)
        XCTAssertTrue(b.message.contains("Narrator"))
    }

    func testVoiceSessionFailureBannerIsAProblemAndNeverSelectsAVoice() {
        let attached = VoiceLibraryBannerState.voiceSessionFailed(message: "Microphone unavailable", canRetry: true)
        XCTAssertEqual(attached.message, "Voice stopped: Microphone unavailable")
        XCTAssertTrue(attached.showsRetry)
        XCTAssertTrue(attached.isProblem)
        XCTAssertFalse(attached.selectsVoice)
        let detached = VoiceLibraryBannerState.voiceSessionFailed(message: "x", canRetry: false)
        XCTAssertFalse(detached.showsRetry)
        XCTAssertTrue(detached.isProblem)
    }

    func testDuplicateInFlightIDRejected() {
        var f = VoiceAddInFlight()
        XCTAssertTrue(f.begin("v1"))
        XCTAssertFalse(f.begin("v1"))
        XCTAssertTrue(f.begin("v2"))
        f.end("v1")
        XCTAssertTrue(f.begin("v1"))
    }
}

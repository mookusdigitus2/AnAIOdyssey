// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Headphones or car Bluetooth going away mid-reply (`.oldDeviceUnavailable`) must stop the reply
/// rather than carry on out of the speaker; Replay brings it back.
final class VoiceRouteChangePolicyTests: XCTestCase {
    // AVAudioSession.RouteChangeReason raw values.
    let newDeviceAvailable: UInt = 1, oldDeviceUnavailable: UInt = 2, categoryChange: UInt = 3, override: UInt = 4

    func testOldDeviceUnavailableWhileSpeakingStopsWithReplay() {
        XCTAssertEqual(VoiceRouteChangePolicy.response(reasonRawValue: oldDeviceUnavailable, hasPendingPlayback: true),
                       .stopPlaybackOfferReplay)
    }

    func testOldDeviceUnavailableWhileQuietJustRebuilds() {
        XCTAssertEqual(VoiceRouteChangePolicy.response(reasonRawValue: oldDeviceUnavailable, hasPendingPlayback: false), .rebuild)
    }

    func testOwnCategoryChangeIsIgnored() {
        XCTAssertEqual(VoiceRouteChangePolicy.response(reasonRawValue: categoryChange, hasPendingPlayback: true), .ignore)
    }

    func testOtherReasonsRebuildAndKeepPlaying() {
        for r in [newDeviceAvailable, override, nil] {
            XCTAssertEqual(VoiceRouteChangePolicy.response(reasonRawValue: r, hasPendingPlayback: true), .rebuild)
        }
    }

    func testStoppedMessageCopy() {
        XCTAssertEqual(VoiceRouteChangePolicy.stoppedMessage,
                       "Your headphones or car audio disconnected, so I stopped. Tap Replay to hear it again.")
    }
}

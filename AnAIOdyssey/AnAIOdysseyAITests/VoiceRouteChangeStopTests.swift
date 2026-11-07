// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// `.oldDeviceUnavailable` (headphones / car Bluetooth gone) stops the reply and offers Replay;
/// with nothing playing it only rebuilds and shows no message.
@MainActor
final class VoiceRouteChangeStopTests: XCTestCase {
    func testOldDeviceUnavailableWhileQuietShowsNoStopMessage() {
        let engine = VoiceDuplexEngine.shared
        engine.stopPlayback()
        engine.reportAudioIssue(nil)
        engine.handleRouteChange(reasonRawValue: 2)
        XCTAssertNotEqual(engine.lastAudioIssue, VoiceRouteChangePolicy.stoppedMessage)
        XCTAssertFalse(engine.hasPendingPlayback)
    }

    func testCategoryChangeIsIgnored() {
        let engine = VoiceDuplexEngine.shared
        let before = engine.graphRebuildCount
        engine.handleRouteChange(reasonRawValue: 3)
        XCTAssertEqual(engine.graphRebuildCount, before)
    }
}

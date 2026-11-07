// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceMicPoliciesTests: XCTestCase {
    func testMicGateIgnoresOwnVoiceTail() {
        XCTAssertFalse(VoiceMicGate.shouldAccept(isPlayingBack: false, secondsSincePlaybackEnded: 0.2,
                                                 echoCancellationActive: true, bargeInEnabled: true))
        XCTAssertTrue(VoiceMicGate.shouldAccept(isPlayingBack: false, secondsSincePlaybackEnded: 1.0,
                                                echoCancellationActive: false, bargeInEnabled: false))
        XCTAssertTrue(VoiceMicGate.shouldAccept(isPlayingBack: false, secondsSincePlaybackEnded: nil,
                                                echoCancellationActive: false, bargeInEnabled: false))
    }

    func testMicGateDuringPlaybackNeedsAECAndBargeIn() {
        XCTAssertFalse(VoiceMicGate.shouldAccept(isPlayingBack: true, secondsSincePlaybackEnded: nil,
                                                 echoCancellationActive: false, bargeInEnabled: true))
        XCTAssertFalse(VoiceMicGate.shouldAccept(isPlayingBack: true, secondsSincePlaybackEnded: nil,
                                                 echoCancellationActive: true, bargeInEnabled: false))
        XCTAssertTrue(VoiceMicGate.shouldAccept(isPlayingBack: true, secondsSincePlaybackEnded: nil,
                                                echoCancellationActive: true, bargeInEnabled: true))
    }

    func testKeepAliveBeforeElevenLabsTwentySecondTimeout() {
        XCTAssertFalse(ElevenLabsKeepAlivePolicy.shouldSendKeepAlive(secondsSinceLastSend: 10, isConnected: true))
        XCTAssertTrue(ElevenLabsKeepAlivePolicy.shouldSendKeepAlive(secondsSinceLastSend: 15, isConnected: true))
        XCTAssertFalse(ElevenLabsKeepAlivePolicy.shouldSendKeepAlive(secondsSinceLastSend: 30, isConnected: false))
        XCTAssertLessThan(ElevenLabsKeepAlivePolicy.idleThresholdSeconds, 20)
        XCTAssertEqual(ElevenLabsKeepAlivePolicy.payload()["text"] as? String, " ")
    }

    func testReplayCacheKeepsLastCompletedTurn() {
        var cache = VoicePCMReplayCache()
        XCTAssertFalse(cache.canReplay)
        cache.beginTurn(); cache.append(Data([1, 2])); cache.append(Data([3, 4])); cache.commitTurn()
        XCTAssertEqual(cache.lastReply, Data([1, 2, 3, 4]))
        cache.beginTurn(); cache.commitTurn()           // empty turn keeps previous
        XCTAssertEqual(cache.lastReply, Data([1, 2, 3, 4]))
        cache.beginTurn(); cache.append(Data([9])); cache.commitTurn()
        XCTAssertEqual(cache.lastReply, Data([9]))
    }

    func testReconnectOnlyBeforeTurnTextWhenClosed() {
        XCTAssertTrue(ElevenLabsReconnectPolicy.shouldReconnectBeforeSend(isConnected: false, turnHasSentText: false, hasCredentials: true))
        XCTAssertFalse(ElevenLabsReconnectPolicy.shouldReconnectBeforeSend(isConnected: true, turnHasSentText: false, hasCredentials: true))
        XCTAssertFalse(ElevenLabsReconnectPolicy.shouldReconnectBeforeSend(isConnected: false, turnHasSentText: true, hasCredentials: true))
        XCTAssertFalse(ElevenLabsReconnectPolicy.shouldReconnectBeforeSend(isConnected: false, turnHasSentText: false, hasCredentials: false))
    }
}

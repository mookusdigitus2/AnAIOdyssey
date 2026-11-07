// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceLatencyTraceTests: XCTestCase {
    func testFirstMarkWinsAndReportsMilliseconds() {
        var first = VoiceLatencyTrace(turnKind: .first, turnIndex: 0)
        first.mark(.requestSent, at: 10)
        first.mark(.firstLLMToken, at: 10.12)
        first.mark(.firstTTSRequest, at: 10.18)
        first.mark(.firstAudioByte, at: 10.40)
        first.mark(.playbackStart, at: 10.45)
        first.mark(.playbackStart, at: 11.00)

        XCTAssertEqual(first.milliseconds(from: .requestSent, to: .firstLLMToken), 120)
        XCTAssertEqual(first.timeToFirstAudioMilliseconds(), 450)
        XCTAssertEqual(first.time(for: .playbackStart), 10.45)
        XCTAssertTrue(first.summaryLine().contains("first turn #1"))
        XCTAssertTrue(first.summaryLine().contains("450ms"))
    }

    func testLaterTurnLabelAndMissingMarks() {
        var later = VoiceLatencyTrace(turnKind: .subsequent, turnIndex: 2)
        later.mark(.requestSent, at: 1)
        XCTAssertNil(later.timeToFirstAudioMilliseconds())
        XCTAssertTrue(later.summaryLine().contains("later turn #3"))
        XCTAssertTrue(later.summaryLine().contains("—"))
    }

    func testTurnKindMatchesCompletedCount() {
        XCTAssertEqual(VoiceConnectionPolicy.turnKind(completedSpokenTurns: 0), .first)
        var first = VoiceLatencyTrace(turnKind: VoiceConnectionPolicy.turnKind(completedSpokenTurns: 0))
        first.mark(.requestSent, at: 0)
        first.mark(.playbackStart, at: 1.2)
        XCTAssertEqual(first.timeToFirstAudioMilliseconds(), 1200)

        var later = VoiceLatencyTrace(
            turnKind: VoiceConnectionPolicy.turnKind(completedSpokenTurns: 1),
            turnIndex: 1
        )
        later.mark(.requestSent, at: 0)
        later.mark(.playbackStart, at: 0.4)
        XCTAssertEqual(later.timeToFirstAudioMilliseconds(), 400)
        XCTAssertLessThan(later.timeToFirstAudioMilliseconds()!, first.timeToFirstAudioMilliseconds()!)
    }
}

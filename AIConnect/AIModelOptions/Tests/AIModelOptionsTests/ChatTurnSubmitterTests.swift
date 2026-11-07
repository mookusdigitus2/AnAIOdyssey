// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Requirements 3, 5 and 6: spoken and typed turns share one submit point,
/// an utterance is submitted at most once, and a new turn cancels the
/// running reply before it starts.
@MainActor
final class ChatTurnSubmitterTests: XCTestCase {
    private var center: BackgroundRunCenter!
    private var submitter: ChatTurnSubmitter!
    private var recorded: [String] = []
    private var finishedReplies: [String] = []

    override func setUp() async throws {
        center = BackgroundRunCenter()
        submitter = ChatTurnSubmitter(runs: center)
        recorded = []
        finishedReplies = []
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// A reply that streams until `gate` opens, then finishes unless cancelled.
    @discardableResult
    private func submit(_ text: String, utteranceID: Int? = nil, gate: AsyncStream<Void>) -> Bool {
        submitter.submit(
            chatID: "chat",
            text: text,
            utteranceID: utteranceID,
            execution: .cloud,
            record: { [unowned self] in self.recorded.append(text) }
        ) { [unowned self] _ in
            for await _ in gate { break }
            try Task.checkCancellation()
            self.finishedReplies.append(text)
        }
    }

    func testSecondTurnCancelsTheFirstTurnsGeneration() async {
        let (gateA, openA) = AsyncStream<Void>.makeStream()
        let (gateB, openB) = AsyncStream<Void>.makeStream()
        submit("first", utteranceID: 1, gate: gateA)
        await settle()
        submit("second", utteranceID: 2, gate: gateB)
        openA.yield()
        openB.yield()
        await settle()
        XCTAssertEqual(recorded, ["first", "second"])
        XCTAssertEqual(finishedReplies, ["second"], "two quick turns produce one reply")
        XCTAssertEqual(center.snapshot(for: "chat")?.phase, .finished)
    }

    func testTypedTurnCancelsASpokenTurnsGeneration() async {
        let (gateA, openA) = AsyncStream<Void>.makeStream()
        let (gateB, openB) = AsyncStream<Void>.makeStream()
        submit("spoken", utteranceID: 7, gate: gateA)
        submit("typed", gate: gateB)
        openA.yield()
        openB.yield()
        await settle()
        XCTAssertEqual(finishedReplies, ["typed"])
    }

    func testAnUtteranceIsSubmittedAtMostOnce() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        XCTAssertTrue(submit("hello", utteranceID: 3, gate: gate))
        XCTAssertFalse(submit("hello", utteranceID: 3, gate: gate))
        open.yield()
        await settle()
        XCTAssertEqual(recorded, ["hello"])
        XCTAssertEqual(finishedReplies, ["hello"])
    }

    func testTypedTurnsHaveNoIDAndAreNeverDeduplicated() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        submit("again", gate: gate)
        submit("again", gate: gate)
        open.yield()
        await settle()
        XCTAssertEqual(recorded, ["again", "again"])
    }

    func testBlankTurnsAreNotSubmitted() {
        let (gate, _) = AsyncStream<Void>.makeStream()
        XCTAssertFalse(submit("   ", utteranceID: 9, gate: gate))
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(center.isRunning(id: "chat"))
    }
}

// SPDX-License-Identifier: MIT
import Foundation

/// The one place a chat turn starts, typed or spoken. Starting a turn goes
/// through the chat's run center, which cancels the running reply first, so
/// two quick turns can never produce two replies. A spoken utterance is
/// submitted at most once, however often its id arrives.
@MainActor
public final class ChatTurnSubmitter {
    public static let chat = ChatTurnSubmitter(runs: .chat)

    private let runs: BackgroundRunCenter
    /// Recently submitted utterance ids, bounded (oldest dropped first).
    /// Ids only grow, so an evicted id is never seen again.
    public static let rememberedUtterances = 256
    private var submittedUtteranceIDs: Set<Int> = []
    private var submittedOrder: [Int] = []
    public var rememberedUtteranceCount: Int { submittedUtteranceIDs.count }

    public init(runs: BackgroundRunCenter) {
        self.runs = runs
    }

    /// `record` stores the user message; `work` produces the reply. Returns
    /// false (and does nothing) for blank text or an already submitted utterance.
    @discardableResult
    public func submit(
        chatID: String,
        text: String,
        utteranceID: Int?,
        execution: RunExecution,
        record: () -> Void,
        work: @escaping BackgroundRunCenter.Work
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let utteranceID {
            guard submittedUtteranceIDs.insert(utteranceID).inserted else { return false }
            submittedOrder.append(utteranceID)
            if submittedOrder.count > Self.rememberedUtterances {
                submittedUtteranceIDs.remove(submittedOrder.removeFirst())
            }
        }
        record()
        runs.start(id: chatID, title: trimmed, execution: execution, work: work)
        return true
    }
}

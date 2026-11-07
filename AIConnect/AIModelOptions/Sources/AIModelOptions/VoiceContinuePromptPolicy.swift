// SPDX-License-Identifier: MIT
import Foundation

/// The answer to "Would you like me to continue?" after speech barged in on
/// a playing reply.
public enum VoiceContinueIntent: Equatable, Sendable {
    case yes
    case no
    /// "Hold on", "wait"…: stay paused with the prompt up; a later yes or no
    /// still answers it.
    case hold
    /// Anything else: the reply is dropped and the utterance becomes the next turn.
    case other
}

/// Barge-in prompt copy and the simple spoken yes/no match: a short reply
/// made only of yes words (or only of no words) plus filler.
public enum VoiceContinuePromptPolicy {
    public static let promptText = "Would you like me to continue?"
    public static let yesTitle = "Yes"
    public static let noTitle = "No"

    static let maxAnswerWords = 4
    static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "ya", "yea", "sure", "ok", "okay", "continue",
        "go", "on", "ahead", "keep", "going", "resume", "carry",
    ]
    static let noWords: Set<String> = [
        "no", "nope", "nah", "stop", "cancel", "enough", "that's", "thats", "it", "don't", "dont",
    ]
    /// Every hold phrase, in one place.
    public static let holdPhrases: Set<String> = [
        "hold on", "hold", "hold up", "hold it", "wait", "wait a sec", "wait a second", "wait a minute",
        "wait wait", "pause", "one sec", "one second", "one moment", "just a sec", "just a second",
        "just a moment", "hang on", "hang on a sec", "hang on a second", "give me a sec",
        "give me a second", "a sec", "a second",
    ]
    static let negations: Set<String> = ["no", "nope", "nah"]
    static let fillerWords: Set<String> = ["please", "thanks", "thank", "you", "um", "uh", "oh"]

    public static func classify(_ utterance: String) -> VoiceContinueIntent {
        let words = utterance.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let meaningful = words.filter { !fillerWords.contains($0) }
        if !meaningful.isEmpty, holdPhrases.contains(meaningful.joined(separator: " ")) { return .hold }
        // "no wait", "wait no", "nope, hold on": a hold, not a new turn.
        let withoutNo = meaningful.filter { !negations.contains($0) }
        if withoutNo.count < meaningful.count, !withoutNo.isEmpty, words.count <= maxAnswerWords,
           holdPhrases.contains(withoutNo.joined(separator: " ")) {
            return .hold
        }
        guard !meaningful.isEmpty, words.count <= maxAnswerWords else { return .other }
        if meaningful.allSatisfy(yesWords.contains), meaningful.contains(where: { !["on", "it", "going"].contains($0) }) {
            return .yes
        }
        if meaningful.allSatisfy(noWords.contains), meaningful.contains(where: { $0 != "it" }) {
            return .no
        }
        return .other
    }
}

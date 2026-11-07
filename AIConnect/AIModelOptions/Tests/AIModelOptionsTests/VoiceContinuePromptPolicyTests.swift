// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceContinuePromptPolicyTests: XCTestCase {
    func testPromptCopy() {
        XCTAssertEqual(VoiceContinuePromptPolicy.promptText, "Would you like me to continue?")
    }

    func testSpokenYesVariants() {
        for phrase in ["Yes", "yeah", "Yep.", "continue", "Go on", "go ahead", "keep going", "Sure, please", "OK", "yes please"] {
            XCTAssertEqual(VoiceContinuePromptPolicy.classify(phrase), .yes, phrase)
        }
    }

    func testSpokenNoVariants() {
        for phrase in ["No", "nope", "Stop.", "no thanks", "nah", "No, stop", "that's enough", "cancel"] {
            XCTAssertEqual(VoiceContinuePromptPolicy.classify(phrase), .no, phrase)
        }
    }

    func testAnythingElseIsOther() {
        for phrase in ["What's the weather tomorrow?", "no tell me about Paris instead", "yes but shorter please and in French", "", "hmm"] {
            XCTAssertEqual(VoiceContinuePromptPolicy.classify(phrase), .other, phrase)
        }
    }
}

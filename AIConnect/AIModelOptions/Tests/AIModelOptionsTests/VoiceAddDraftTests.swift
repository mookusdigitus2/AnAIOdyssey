// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceAddDraftTests: XCTestCase {
    private let record = ElevenLabsVoiceRecord(voiceID: "abcdefghijkl1234", name: "Narrator", previewURL: nil, publicOwnerID: "o", freeUsersAllowed: true)

    func testCannotSaveBeforeLookup() {
        var d = VoiceAddDraft()
        d.voiceID = "My Narrator"
        d.voiceIDChanged()
        XCTAssertFalse(d.canSave)
        XCTAssertNil(d.recordToSave)
    }

    func testLookupPrefillsNameAndEditedNameIsSaved() {
        var d = VoiceAddDraft()
        d.voiceID = record.voiceID
        d.lookupSucceeded(record, isLibrary: true)
        XCTAssertEqual(d.name, "Narrator")
        d.name = "  Bedtime Voice "
        XCTAssertTrue(d.canSave)
        XCTAssertEqual(d.recordToSave?.name, "Bedtime Voice")
        XCTAssertEqual(d.recordToSave?.voiceID, record.voiceID)
    }

    func testTypedNameKeptWhenLookupArrives() {
        var d = VoiceAddDraft()
        d.name = "Mine"
        d.lookupSucceeded(record, isLibrary: false)
        XCTAssertEqual(d.recordToSave?.name, "Mine")
    }

    func testChangingIDDropsStaleLookup() {
        var d = VoiceAddDraft()
        d.voiceID = record.voiceID
        d.lookupSucceeded(record, isLibrary: true)
        d.voiceID = "different-id-0000"
        d.voiceIDChanged()
        XCTAssertFalse(d.canSave)
    }

    func testRemovalReplacementOnlyForActiveVoice() {
        let a = VoiceOption(id: "a", displayName: "A", previewURL: nil)
        let b = VoiceOption(id: "b", displayName: "B", previewURL: nil)
        XCTAssertNil(VoiceRemovalPlan.replacement(removing: "a", active: "b", added: [a], catalog: [b]))
        XCTAssertEqual(VoiceRemovalPlan.replacement(removing: "a", active: "a", added: [a], catalog: [b])?.id, "b")
    }
}

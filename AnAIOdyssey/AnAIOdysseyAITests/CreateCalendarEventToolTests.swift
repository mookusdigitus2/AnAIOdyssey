// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

final class CreateCalendarEventToolParsingTests: XCTestCase {
    private func parsed(_ content: String) -> CreateCalendarEventTool.ParsedInput? {
        if case .parsed(let input) = CreateCalendarEventTool.parseInput(content) {
            return input
        }
        return nil
    }

    func testParsesTimedEventWithAllFields() throws {
        let input = try XCTUnwrap(parsed("""
        Team sync
        start: 2026-08-27 14:00
        end: 2026-08-27 15:30
        location: Conference room
        notes: Agenda attached
        """))
        XCTAssertEqual(input.title, "Team sync")
        XCTAssertEqual(input.location, "Conference room")
        XCTAssertEqual(input.notes, "Agenda attached")
        XCTAssertFalse(input.allDay)
        XCTAssertEqual(input.end.timeIntervalSince(input.start), 90 * 60)
    }

    func testEndDefaultsToOneHourAfterStart() throws {
        let input = try XCTUnwrap(parsed("""
        Dentist
        start: 2026-08-27 09:00
        """))
        XCTAssertEqual(input.end.timeIntervalSince(input.start), 3600)
        XCTAssertFalse(input.allDay)
    }

    func testDateOnlyStartImpliesAllDay() throws {
        let input = try XCTUnwrap(parsed("""
        Vacation day
        start: 2026-08-28
        """))
        XCTAssertTrue(input.allDay)
        XCTAssertEqual(input.start, input.end)
    }

    func testExplicitAllDayOverrides() throws {
        let input = try XCTUnwrap(parsed("""
        Focus block
        start: 2026-08-27 09:00
        allday: true
        """))
        XCTAssertTrue(input.allDay)
    }

    func testEndBeforeStartIsClamped() throws {
        let input = try XCTUnwrap(parsed("""
        Backwards
        start: 2026-08-27 14:00
        end: 2026-08-27 13:00
        """))
        XCTAssertEqual(input.end, input.start)
    }

    func testBodyLinesJoinNotes() throws {
        let input = try XCTUnwrap(parsed("""
        Planning
        start: 2026-08-27 10:00
        Discuss roadmap
        and budget
        """))
        XCTAssertEqual(input.notes, "Discuss roadmap\nand budget")
    }

    func testMissingTitleIsRejectedWithGuidance() {
        guard case .invalid(let message) = CreateCalendarEventTool.parseInput("") else {
            return XCTFail("Expected invalid outcome")
        }
        XCTAssertTrue(message.contains("title"))
    }

    func testMissingStartIsRejectedWithGuidance() {
        guard case .invalid(let message) = CreateCalendarEventTool.parseInput("Just a title") else {
            return XCTFail("Expected invalid outcome")
        }
        XCTAssertTrue(message.contains("start:"))
    }

    func testParsesISO8601Dates() {
        XCTAssertNotNil(CreateCalendarEventTool.parseDate("2026-08-27T14:00:00Z"))
        XCTAssertNotNil(CreateCalendarEventTool.parseDate("2026-08-27T14:00"))
        XCTAssertNotNil(CreateCalendarEventTool.parseDate("2026-08-27 14:00"))
        XCTAssertEqual(CreateCalendarEventTool.parseDate("2026-08-27")?.dateOnly, true)
        XCTAssertNil(CreateCalendarEventTool.parseDate("tomorrow"))
    }
}

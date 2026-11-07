// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
import AnAIOdysseyCore

/// Every app that uses the AI framework gets a date tool. The agent can ask
/// for today's date, the local time and the time zone instead of guessing from training.
@MainActor
final class CurrentDateToolTests: XCTestCase {
    /// 2026-10-17 23:09:30 PDT (06:09:30 UTC on the 18th).
    private let saturdayNight = Date(timeIntervalSince1970: 1_792_303_770)

    private var repositories: RepositoryBundle!
    private var memoryService: MemoryService!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-date-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let (_, repos) = try TestModelContainer.makeRepositories()
        repositories = repos
        memoryService = MemoryService(
            memories: repos.memories,
            vectorStore: try VectorIndexStore(databaseURL: tempDirectory.appendingPathComponent("vectors.sqlite")),
            embeddingService: MockEmbeddingService()
        )
    }

    override func tearDownWithError() throws {
        memoryService = nil
        repositories = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    private func makeContext() -> AgentContext {
        AgentContext(sessionID: "s", repositories: repositories, memoryService: memoryService)
    }

    private func tz(_ id: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: id))
    }

    func testReportsWeekdayDateTimeZoneAndISO8601() async throws {
        let la = try tz("America/Los_Angeles")
        let tool = CurrentDateTool(now: { self.saturdayNight }, timeZone: { la })
        XCTAssertEqual(tool.name, "current_date")
        var context = makeContext()
        let result = try await tool.execute(content: "", context: &context)
        XCTAssertEqual(result, """
        Today is Saturday, October 17, 2026.
        Local time: 11:09 PM
        Time zone: America/Los_Angeles (UTC-07:00)
        ISO 8601: 2026-10-17T23:09:30-07:00
        """)
    }

    func testUsesStandardTimeOffsetInWinter() throws {
        let january = Date(timeIntervalSince1970: 1_799_049_600) // 2027-01-04 08:00 UTC
        let text = CurrentDateTool.report(for: january, in: try tz("America/Los_Angeles"))
        XCTAssertTrue(text.contains("Today is Monday, January 4, 2027."), text)
        XCTAssertTrue(text.contains("Local time: 12:00 AM"), text)
        XCTAssertTrue(text.contains("(UTC-08:00)"), text)
        XCTAssertTrue(text.hasSuffix("ISO 8601: 2027-01-04T00:00:00-08:00"), text)
    }

    func testSameInstantIsTheNextDayInAnotherZone() throws {
        let text = CurrentDateTool.report(for: saturdayNight, in: try tz("Asia/Kolkata"))
        XCTAssertTrue(text.contains("Today is Sunday, October 18, 2026."), text)
        XCTAssertTrue(text.contains("Local time: 11:39 AM"), text)
        XCTAssertTrue(text.contains("Time zone: Asia/Kolkata (UTC+05:30)"), text)
        XCTAssertTrue(text.hasSuffix("ISO 8601: 2026-10-18T11:39:30+05:30"), text)
    }

    func testUTCIsWrittenWithAnExplicitOffset() throws {
        let text = CurrentDateTool.report(for: saturdayNight, in: try tz("UTC"))
        XCTAssertTrue(text.contains("(UTC+00:00)"), text)
        XCTAssertTrue(text.hasSuffix("ISO 8601: 2026-10-18T06:09:30+00:00"), text)
    }

    func testReadsTheClockOnEveryCall() async throws {
        var now = saturdayNight
        let tool = CurrentDateTool(now: { now }, timeZone: { TimeZone(identifier: "America/Los_Angeles")! })
        var context = makeContext()
        let first = try await tool.execute(content: "", context: &context)
        now = now.addingTimeInterval(3600)
        let second = try await tool.execute(content: "", context: &context)
        XCTAssertTrue(first.contains("11:09 PM"))
        XCTAssertTrue(second.contains("Today is Sunday, October 18, 2026."), second)
        XCTAssertTrue(second.contains("12:09 AM"), second)
    }

    func testChatAndTaskRegistriesOfferAndDescribeIt() {
        let chat = AgentToolRegistry.standard(repositories: repositories, memoryService: memoryService)
        let task = AgentToolRegistry.taskWorkspace(repositories: repositories)
        for registry in [chat, task] {
            XCTAssertTrue(registry.toolNames.contains("current_date"))
            XCTAssertTrue(registry.toolDescriptions.contains("```current_date"), registry.toolDescriptions)
        }
    }
}

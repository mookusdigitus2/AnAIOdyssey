// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

final class CloudDefaultsSyncTests: XCTestCase {
    func testRemoteAPIKeysExcludedFromCloudSync() {
        let excluded = ["oauthTokens", "anaiodyssey.task.", "anaiodyssey.remote."]
        func shouldSync(_ key: String) -> Bool {
            guard key.hasPrefix("anaiodyssey.") else { return false }
            return !excluded.contains { key.contains($0) }
        }

        XCTAssertFalse(shouldSync("anaiodyssey.remote.apiKey"))
        XCTAssertFalse(shouldSync("anaiodyssey.remote.connections"))
        XCTAssertTrue(shouldSync("anaiodyssey.chat.systemPrompt"))
    }
}

final class DefaultsKeyMigrationTests: XCTestCase {
    func testCopiesLegacyPrefixAndRemovesSource() {
        let defaults = UserDefaults(suiteName: "anaiodyssey.defaults-migration-tests")!
        defaults.removePersistentDomain(forName: "anaiodyssey.defaults-migration-tests")

        defaults.set("hello", forKey: "odysseus.chat.systemPrompt")
        defaults.set("keep-me", forKey: "anaiodyssey.appearance.accent")
        defaults.set("stale", forKey: "odysseus.appearance.accent")
        defaults.synchronize()

        DefaultsKeyMigration.migrate(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "anaiodyssey.chat.systemPrompt"), "hello")
        XCTAssertNil(defaults.object(forKey: "odysseus.chat.systemPrompt"))
        XCTAssertEqual(defaults.string(forKey: "anaiodyssey.appearance.accent"), "keep-me")
        XCTAssertNil(defaults.object(forKey: "odysseus.appearance.accent"))

        defaults.removePersistentDomain(forName: "anaiodyssey.defaults-migration-tests")
    }
}

final class TaskSchedulerNextRunTests: XCTestCase {
    @MainActor
    func testRecomputesStaleDailyNextRun() {
        let past = Calendar.current.date(byAdding: .hour, value: -2, to: .now)!
        let next = TaskSchedulerService.computeNextRun(
            schedule: TaskSchedule.daily.rawValue,
            scheduledTime: "09:00",
            scheduledDate: nil,
            after: past
        )
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, .now)
    }

    @MainActor
    func testNotificationIdentifierUsesTaskPrefix() {
        XCTAssertTrue("anaiodyssey.task.abc-123".hasPrefix(TaskSchedulerService.notificationIDPrefix))
        XCTAssertTrue("odysseus.task.abc-123".hasPrefix(TaskSchedulerService.legacyNotificationIDPrefix))
    }
}

final class UnifiedSearchServiceTests: XCTestCase {
    @MainActor
    func testFindsDocumentByTitle() throws {
        let (context, repos) = try TestModelContainer.makeRepositories()
        _ = try repos.documents.createDocument(title: "Quarterly Budget", content: "Q3 numbers")
        try repos.documents.save()

        let service = UnifiedSearchService(repositories: repos)
        let hits = try service.search(query: "budget", kinds: [.document], limit: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.title.contains("Budget") })
        _ = context
    }
}

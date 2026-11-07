// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AIModelOptions
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

private final class FakeBackend: VoiceAddBackend, @unchecked Sendable {
    let record: ElevenLabsVoiceRecord
    let addDelay: Duration
    let addError: Error?
    private let lock = NSLock()
    private var _addCalls = 0
    var addCalls: Int { lock.lock(); defer { lock.unlock() }; return _addCalls }
    init(record: ElevenLabsVoiceRecord, addDelay: Duration = .zero, addError: Error? = nil) {
        self.record = record; self.addDelay = addDelay; self.addError = addError
    }
    func lookup(apiKey: String, voiceID: String) async throws -> ElevenLabsVoiceLookup { .library(record) }
    func addShared(apiKey: String, publicOwnerID: String, voiceID: String, name: String) async throws {
        lock.lock(); _addCalls += 1; lock.unlock()
        try await Task.sleep(for: addDelay)
        if let addError { throw addError }
    }
}

private struct Rejected: LocalizedError { var errorDescription: String? { "Paid plan needed" } }

@MainActor
private final class Saved { var records: [ElevenLabsVoiceRecord] = [] }

@MainActor
final class VoiceLibraryServiceTests: XCTestCase {
    private let record = ElevenLabsVoiceRecord(voiceID: "abcdefghijkl1234", name: "Narrator", previewURL: nil, publicOwnerID: "owner", freeUsersAllowed: true)

    func testLookupThenAddEventSequence() async {
        let service = VoiceLibraryService(backend: FakeBackend(record: record), lookupDebounce: .zero)
        let saved = Saved()
        let stream = await service.events()
        let collector = Task { () -> [VoiceAddEvent] in
            var out: [VoiceAddEvent] = []
            for await e in stream { out.append(e); if case .added = e { break } }
            return out
        }
        await service.lookup(voiceID: record.voiceID, apiKey: "k")
        try? await Task.sleep(for: .milliseconds(150))
        await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        let events = await collector.value
        XCTAssertEqual(events, [.idle, .lookingUp, .found(record, isLibrary: true), .adding, .added(record)])
        XCTAssertEqual(saved.records, [record])
    }

    func testDismissMidAddUnsubscribesAndStillSaves() async {
        let service = VoiceLibraryService(backend: FakeBackend(record: record, addDelay: .milliseconds(300)), lookupDebounce: .zero)
        let saved = Saved()
        let viewTask = Task { for await _ in await service.events() {} }
        try? await Task.sleep(for: .milliseconds(50))
        await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        viewTask.cancel() // picker dismissed mid-add
        try? await Task.sleep(for: .milliseconds(50))
        let subs = await service.subscriberCount
        XCTAssertEqual(subs, 0)
        await service.waitForAdds()
        XCTAssertEqual(saved.records, [record], "add must finish and persist after dismiss")
        let last = await service.lastEvent
        XCTAssertEqual(last, .added(record))
    }

    func testDuplicateAddForInFlightIDIsRejected() async {
        let backend = FakeBackend(record: record, addDelay: .milliseconds(200))
        let service = VoiceLibraryService(backend: backend, lookupDebounce: .zero)
        let saved = Saved()
        let first = await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        let second = await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        await service.waitForAdds()
        XCTAssertEqual(backend.addCalls, 1)
        XCTAssertEqual(saved.records.count, 1)
        let again = await service.add(record, isLibrary: true, apiKey: "k") { _ in }
        XCTAssertTrue(again, "ID is free again after the add finishes")
        await service.waitForAdds()
    }

    func testSuccessBannerAndSelection() async {
        let center = VoiceLibraryBannerCenter()
        let service = VoiceLibraryService(backend: FakeBackend(record: record), lookupDebounce: .zero, banners: center)
        let saved = Saved()
        await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        await service.waitForAdds()
        XCTAssertEqual(center.banner, .added(voiceID: record.voiceID, name: "Narrator"))
        XCTAssertEqual(center.banner?.message, "Added Narrator and set it as your voice")
        XCTAssertEqual(saved.records, [record])
    }

    func testFailureBannerRetryAndNoSelection() async {
        let center = VoiceLibraryBannerCenter()
        let backend = FakeBackend(record: record, addError: Rejected())
        let service = VoiceLibraryService(backend: backend, lookupDebounce: .zero, banners: center)
        let saved = Saved()
        await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        await service.waitForAdds()
        XCTAssertEqual(center.banner, .failed(voiceID: record.voiceID, name: "Narrator", message: "Paid plan needed"))
        XCTAssertTrue(center.banner?.showsRetry == true)
        XCTAssertTrue(saved.records.isEmpty, "failed add must not save or select")
        center.retry()
        XCTAssertNil(center.banner)
        try? await Task.sleep(for: .milliseconds(150))
        await service.waitForAdds()
        XCTAssertEqual(backend.addCalls, 2, "Retry re-sends the add once")
    }

    func testLookupTimesOutWithError() async {
        struct Hanging: VoiceAddBackend {
            func lookup(apiKey: String, voiceID: String) async throws -> ElevenLabsVoiceLookup {
                try await Task.sleep(for: .seconds(30)); return .notFound
            }
            func addShared(apiKey: String, publicOwnerID: String, voiceID: String, name: String) async throws {}
        }
        let service = VoiceLibraryService(backend: Hanging(), lookupDebounce: .zero, lookupTimeout: .milliseconds(200))
        await service.lookup(voiceID: record.voiceID, apiKey: "k")
        try? await Task.sleep(for: .milliseconds(600))
        let last = await service.lastEvent
        XCTAssertEqual(last, .failed(VoiceLibraryService.lookupTimeoutMessage))
    }

    func testCancelLookupLeavesCommittedAddRunning() async {
        let backend = FakeBackend(record: record, addDelay: .milliseconds(300))
        let service = VoiceLibraryService(backend: backend, lookupDebounce: .zero)
        let saved = Saved()
        await service.add(record, isLibrary: true, apiKey: "k") { saved.records.append($0) }
        await service.cancelLookup() // Back / Cancel after Save
        await service.waitForAdds()
        XCTAssertEqual(saved.records, [record], "a saved add must finish, not be half-done")
        XCTAssertEqual(backend.addCalls, 1)
    }

    func testCancelLookupStopsPendingLookup() async {
        let service = VoiceLibraryService(backend: FakeBackend(record: record), lookupDebounce: .milliseconds(200))
        await service.lookup(voiceID: record.voiceID, apiKey: "k")
        await service.cancelLookup()
        try? await Task.sleep(for: .milliseconds(400))
        let last = await service.lastEvent
        XCTAssertEqual(last, .idle)
    }

    func testOutOfOrderKeystrokeLookupsKeepLatest() async {
        let service = VoiceLibraryService(backend: FakeBackend(record: record), lookupDebounce: .milliseconds(50))
        await service.lookup(voiceID: record.voiceID, apiKey: "k", sequence: 2)   // full ID arrives first
        await service.lookup(voiceID: "abcd", apiKey: "k", sequence: 1)           // stale prefix arrives late
        try? await Task.sleep(for: .milliseconds(300))
        let last = await service.lastEvent
        XCTAssertEqual(last, .found(record, isLibrary: true))
    }
}

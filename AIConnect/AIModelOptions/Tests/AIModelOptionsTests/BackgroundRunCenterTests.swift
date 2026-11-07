// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Fake background-task assertion so tests can drive iOS expiration.
@MainActor
final class FakeBackgroundAssertion: BackgroundTaskAsserting {
    var begun = 0
    var ended = 0
    var expiration: (() -> Void)?
    func begin(name: String, expiration: @escaping () -> Void) -> Int {
        begun += 1
        self.expiration = expiration
        return begun
    }
    func end(_ token: Int) { ended += 1 }
}

@MainActor
final class BackgroundRunCenterTests: XCTestCase {
    /// Work that streams one chunk, then waits until released.
    private func gatedWork(_ gate: AsyncStream<Void>, chunk: String = "partial") -> @MainActor (RunHandle) async throws -> Void {
        { handle in
            handle.update(text: chunk)
            for await _ in gate { break }
            try Task.checkCancellation()
            handle.update(text: chunk + " done")
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testRunSurvivesItsViewGoingAway() async throws {
        let center = BackgroundRunCenter()
        var ended: [RunSnapshot] = []
        center.onRunEnded = { ended.append($0) }
        let (gate, open) = AsyncStream<Void>.makeStream()
        // A "view" that starts the run and is then released.
        final class FakeView { }
        weak var weakView: FakeView?
        do {
            let view = FakeView()
            weakView = view
            center.start(id: "r1", title: "Topic", execution: .cloud, work: gatedWork(gate))
        }
        XCTAssertNil(weakView)
        await settle()
        XCTAssertEqual(center.snapshot(for: "r1")?.phase, .running)
        XCTAssertEqual(center.activeRunCount, 1)
        open.yield()
        await settle()
        XCTAssertEqual(center.snapshot(for: "r1")?.phase, .finished)
        XCTAssertEqual(center.snapshot(for: "r1")?.text, "partial done")
        XCTAssertEqual(ended.map(\.id), ["r1"])
        XCTAssertEqual(center.activeRunCount, 0)
    }

    func testStopCancelsAndKeepsPartial() async {
        let center = BackgroundRunCenter()
        let (gate, _) = AsyncStream<Void>.makeStream()
        center.start(id: "r1", title: "T", execution: .cloud, work: gatedWork(gate))
        await settle()
        center.stop(id: "r1")
        await settle()
        let snap = center.snapshot(for: "r1")
        XCTAssertEqual(snap?.phase, .stopped(.user))
        XCTAssertEqual(snap?.text, "partial")
        XCTAssertFalse(center.isRunning(id: "r1"))
    }

    func testLateResultAfterStopIsIgnored() async {
        let center = BackgroundRunCenter()
        center.start(id: "r1", title: "T", execution: .cloud) { handle in
            handle.update(text: "a")
            try? await Task.sleep(nanoseconds: 50_000_000)
            handle.update(text: "late")
        }
        await settle()
        center.stop(id: "r1")
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(center.snapshot(for: "r1")?.text, "a")
        XCTAssertEqual(center.snapshot(for: "r1")?.phase, .stopped(.user))
    }

    func testOnDeviceRunStopsWhenAppBackgrounds() async {
        let center = BackgroundRunCenter()
        let assertion = FakeBackgroundAssertion()
        center.backgroundAssertion = assertion
        let (gate, _) = AsyncStream<Void>.makeStream()
        center.start(id: "local", title: "T", execution: .onDevice, work: gatedWork(gate))
        await settle()
        center.sceneDidEnterBackground()
        await settle()
        let snap = center.snapshot(for: "local")
        XCTAssertEqual(snap?.phase, .stopped(.leftApp))
        XCTAssertEqual(snap?.text, "partial")
        XCTAssertEqual(snap?.statusMessage, "Stopped when you left the app")
        XCTAssertTrue(snap?.canResume ?? false)
        XCTAssertEqual(assertion.begun, 0, "on-device runs don't ask for background time")
    }

    func testCloudRunContinuesInBackgroundUnderAssertion() async {
        let center = BackgroundRunCenter()
        let assertion = FakeBackgroundAssertion()
        center.backgroundAssertion = assertion
        let (gate, open) = AsyncStream<Void>.makeStream()
        center.start(id: "cloud", title: "T", execution: .cloud, work: gatedWork(gate))
        await settle()
        center.sceneDidEnterBackground()
        XCTAssertEqual(assertion.begun, 1)
        XCTAssertEqual(center.snapshot(for: "cloud")?.phase, .running)
        open.yield()
        await settle()
        XCTAssertEqual(center.snapshot(for: "cloud")?.phase, .finished)
        XCTAssertEqual(assertion.ended, 1, "assertion released when the last run ends")
    }

    func testBackgroundTimeExpiryMarksCloudRunStoppedNotComplete() async {
        let center = BackgroundRunCenter()
        let assertion = FakeBackgroundAssertion()
        center.backgroundAssertion = assertion
        var ended: [RunSnapshot] = []
        center.onRunEnded = { ended.append($0) }
        let (gate, _) = AsyncStream<Void>.makeStream()
        center.start(id: "cloud", title: "T", execution: .cloud, work: gatedWork(gate))
        await settle()
        center.sceneDidEnterBackground()
        assertion.expiration?()
        await settle()
        let snap = center.snapshot(for: "cloud")
        XCTAssertEqual(snap?.phase, .stopped(.leftApp))
        XCTAssertNotEqual(snap?.phase, .finished)
        XCTAssertEqual(snap?.text, "partial")
        XCTAssertEqual(assertion.ended, 1)
        XCTAssertEqual(ended.first?.phase, .stopped(.leftApp))
    }

    func testResumeRestartsAStoppedRun() async {
        let center = BackgroundRunCenter()
        var attempts = 0
        center.start(id: "r", title: "T", execution: .onDevice) { handle in
            attempts += 1
            handle.update(text: "try \(attempts)")
            if attempts == 1 { try await Task.sleep(nanoseconds: 5_000_000_000) }
        }
        await settle()
        center.sceneDidEnterBackground()
        await settle()
        XCTAssertEqual(center.snapshot(for: "r")?.phase, .stopped(.leftApp))
        center.sceneWillEnterForeground()
        center.resume(id: "r")
        await settle()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(center.snapshot(for: "r")?.phase, .finished)
        XCTAssertEqual(center.snapshot(for: "r")?.text, "try 2")
    }

    func testFailureIsReportedNotSilent() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let center = BackgroundRunCenter()
        center.start(id: "r", title: "T", execution: .cloud) { handle in
            handle.update(text: "half")
            throw Boom()
        }
        await settle()
        XCTAssertEqual(center.snapshot(for: "r")?.phase, .failed("boom"))
        XCTAssertEqual(center.snapshot(for: "r")?.text, "half")
    }

    func testDismissRemovesEndedRun() async {
        let center = BackgroundRunCenter()
        center.start(id: "r", title: "T", execution: .cloud) { _ in }
        await settle()
        center.dismiss(id: "r")
        XCTAssertNil(center.snapshot(for: "r"))
    }

    func testStartingSameIDReplacesPreviousRun() async {
        let center = BackgroundRunCenter()
        let (gate, _) = AsyncStream<Void>.makeStream()
        center.start(id: "r", title: "T", execution: .cloud, work: gatedWork(gate, chunk: "first"))
        await settle()
        center.start(id: "r", title: "T", execution: .cloud) { $0.update(text: "second") }
        await settle()
        XCTAssertEqual(center.snapshot(for: "r")?.text, "second")
        XCTAssertEqual(center.snapshot(for: "r")?.phase, .finished)
    }

    func testRunsSurviveForegroundWithoutBackgrounding() {
        XCTAssertEqual(RunStopReason.leftApp.message, "Stopped when you left the app")
        XCTAssertEqual(RunStopReason.user.message, "Stopped")
    }
}

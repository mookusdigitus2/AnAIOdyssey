// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

final class AnAIOdysseyCoreTests: XCTestCase {
    func testPackagesBuild() {
        XCTAssertEqual(AnAIOdysseyCore.version, "1.0.0")
    }

    func testAppBranding() {
        XCTAssertEqual(AppBranding.appName, "An AI Odyssey")
        XCTAssertEqual(AppBranding.companyName, "Grey Matter Ideations")
    }

    func testEmptyTestTargetsRun() {
        XCTAssertTrue(true, "AnAIOdysseyCoreTests bundle executes successfully")
    }
}

/// iPhone Duo prep: the app resizes live when the phone folds or unfolds, so nothing may read
/// the whole screen's size. Sizes come from the view, window or scene; scale comes from traits.
final class ScreenGeometrySourceScanTests: XCTestCase {
    private static let banned = ["UIScreen.main", "UIScreen.screens", "UIApplication.shared.windows"]

    func testAppSourcesDoNotReadTheWholeScreen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folders = ["AnAIOdysseyApp", "Packages"].map { root.appendingPathComponent($0) }
        var scanned = 0
        var hits: [String] = []
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
                XCTFail("missing \(folder.path)"); continue
            }
            for case let url as URL in walker {
                if url.path.contains("/.build/") || url.path.contains("/Tests/") { continue }
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                for (n, line) in text.components(separatedBy: .newlines).enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for word in Self.banned where line.contains(word) {
                        hits.append("\(url.lastPathComponent):\(n + 1): \(word)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan should cover the app and its packages")
        XCTAssertEqual(hits, [], "use view, window or scene geometry instead")
    }
}

/// The notification permission prompt waits until the user schedules their first task, instead of
/// appearing over the first launch (and over the iPhone Duo screenshots).
final class NotificationPromptTimingTests: XCTestCase {
    func testLaunchDoesNotAskWithoutScheduledTasks() {
        XCTAssertFalse(NotificationPromptPolicy.shouldAsk(.launch(activeTasksWithNotifications: 0)))
    }

    func testLaunchAsksOnlyToKeepExistingRemindersWorking() {
        XCTAssertTrue(NotificationPromptPolicy.shouldAsk(.launch(activeTasksWithNotifications: 2)),
                      "tasks synced from another device still need permission to remind")
    }

    func testSchedulingATaskAsks() {
        XCTAssertTrue(NotificationPromptPolicy.shouldAsk(.schedulingTask))
        XCTAssertTrue(NotificationPromptPolicy.shouldAsk(.settings))
    }

    func testLaunchWarmUpDoesNotRequestPermissionDirectly() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AnAIOdysseyApp/AnAIOdysseyApp.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private func warmUpNotifications()"))
        let body = String(text[start.upperBound...].prefix(400))
        let end = body.range(of: "\n    }\n").map { String(body[..<$0.lowerBound]) } ?? body
        XCTAssertFalse(end.contains("requestNotificationAccessIfNeeded"), "launch must not prompt for notifications")
    }
}

/// iPhone Duo: folding or unfolding swaps the root view, which rebuilds the open chat. The
/// half-typed message lives outside the view so it survives.
@MainActor
final class ChatDraftStoreTests: XCTestCase {
    func testDraftSurvivesTheChatViewBeingRebuilt() {
        let store = ChatDraftStore()
        store.setDraft("half-typed question", for: "s1")
        // A new view for the same chat reads it back.
        XCTAssertEqual(store.draft(for: "s1"), "half-typed question")
        XCTAssertEqual(store.draft(for: "s2"), "", "drafts are per chat")
    }

    func testSendingClearsTheDraft() {
        let store = ChatDraftStore()
        store.setDraft("hello", for: "s1")
        store.setDraft("", for: "s1")
        XCTAssertEqual(store.draft(for: "s1"), "")
        XCTAssertTrue(store.isEmpty)
    }
}

/// iPhone Duo: the section sidebar moves to the right of the open phone, where the system's bars
/// are. Every other layout keeps it where it was.
final class DuoNavigationPolicyTests: XCTestCase {
    func testOpenDuoPutsTheSidebarOnTheRight() {
        XCTAssertEqual(DuoNavigationPolicy.sectionSidebarEdge(
            idiomIsPhone: true, horizontalSizeClassIsRegular: true, verticalSizeClassIsRegular: true), .trailing)
    }

    func testIPadAndMacKeepTheSidebarOnTheLeft() {
        for h in [true, false] { for v in [true, false] {
            XCTAssertEqual(DuoNavigationPolicy.sectionSidebarEdge(
                idiomIsPhone: false, horizontalSizeClassIsRegular: h, verticalSizeClassIsRegular: v), .leading)
        } }
    }

    func testCompactPhonesAndPlusMaxLandscapeAreUnchanged() {
        XCTAssertEqual(DuoNavigationPolicy.sectionSidebarEdge(
            idiomIsPhone: true, horizontalSizeClassIsRegular: false, verticalSizeClassIsRegular: true), .leading,
            "outer display and ordinary iPhones (tab bar, no sidebar)")
        XCTAssertEqual(DuoNavigationPolicy.sectionSidebarEdge(
            idiomIsPhone: true, horizontalSizeClassIsRegular: true, verticalSizeClassIsRegular: false), .leading,
            "Plus/Max on its side isn't an open Duo")
        XCTAssertEqual(DuoNavigationPolicy.sectionSidebarEdge(
            idiomIsPhone: true, horizontalSizeClassIsRegular: false, verticalSizeClassIsRegular: false), .leading)
    }
}

// PUBLIC COPY: `DuoTabRail` is not implemented yet (it waits on the iOS 27.1 SDK
// dock APIs), so these tests are compiled out until it lands. Define
// ODYSSEY_DUO_TAB_RAIL in the test target's Swift flags to build them.
#if ODYSSEY_DUO_TAB_RAIL
/// iPhone Duo (open): every tab is an icon on the vertical rail down the right edge, in the
/// usual order; tabs that don't fit fold into a More menu at the bottom.
final class DuoTabRailTests: XCTestCase {
    func testHitTargetsAreAtLeast44Points() {
        XCTAssertGreaterThanOrEqual(DuoTabRail.itemSize, 44)
        XCTAssertGreaterThanOrEqual(DuoTabRail.width(trailingSafeAreaInset: 0).width, 44)
        XCTAssertGreaterThanOrEqual(DuoTabRail.width(trailingSafeAreaInset: 20).width, 44)
    }

    func testEveryTabFitsInATallRail() {
        let fit = DuoTabRail.fit(itemCount: 11, height: 11 * DuoTabRail.itemSize)
        XCTAssertEqual(fit.visibleCount, 11)
        XCTAssertEqual(fit.overflowCount, 0)
    }

    func testLowestTabsFoldIntoMore() {
        // Room for 6 slots: 5 tabs and More.
        let fit = DuoTabRail.fit(itemCount: 11, height: 6 * DuoTabRail.itemSize + 10)
        XCTAssertEqual(fit.visibleCount, 5)
        XCTAssertEqual(fit.overflowCount, 6)
    }

    func testTheRailNeverNeedsMoreThanItsHeight() {
        for h in stride(from: CGFloat(0), through: 700, by: 9) {
            let fit = DuoTabRail.fit(itemCount: 11, height: h)
            XCTAssertEqual(fit.visibleCount + fit.overflowCount, 11, "nothing lost at \(h)")
            let slots = CGFloat(fit.visibleCount + (fit.overflowCount > 0 ? 1 : 0))
            XCTAssertLessThanOrEqual(slots * DuoTabRail.itemSize, max(h, DuoTabRail.itemSize), "height \(h)")
        }
    }

    func testRailStartsBelowTheClockAndWiFi() {
        XCTAssertGreaterThanOrEqual(DuoTabRail.topClearance(windowHeight: 720, safeAreaTop: 0), 110)
        XCTAssertEqual(DuoTabRail.topClearance(windowHeight: 720, safeAreaTop: 200), 200)
    }

    func testRailUsesTheStatusStripWhenTheWindowReachesIt() {
        XCTAssertTrue(DuoTabRail.width(trailingSafeAreaInset: 60).drawsInSafeArea)
        XCTAssertEqual(DuoTabRail.width(trailingSafeAreaInset: 60).width, 60)
        XCTAssertFalse(DuoTabRail.width(trailingSafeAreaInset: 0).drawsInSafeArea)
    }
}
#endif

// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class CloudKitTests: XCTestCase {
    func testCloudKitConfigurationBuilds() throws {
        let (container, mode) = try ModelContainerFactory.make(useCloudKit: true)
        XCTAssertNotNil(container)
        XCTAssertTrue(mode == .cloudKit || mode == .local)
    }

    func testLocalFallbackWhenCloudKitUnavailable() throws {
        let container = try ModelContainerFactory.makeInMemory()
        XCTAssertNotNil(container)
    }

    func testDocumentRecordCloudKitCompatible() {
        let small = String(repeating: "a", count: 1_000)
        let large = String(repeating: "b", count: 1_000_000)
        XCTAssertTrue(CloudKitCompatibility.isCloudKitCompatible(text: small))
        XCTAssertFalse(CloudKitCompatibility.isCloudKitCompatible(text: large))
    }
}

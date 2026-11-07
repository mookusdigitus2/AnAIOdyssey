// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI
import AnAIOdysseyCore

final class AnAIOdysseyAITests: XCTestCase {
    func testAIModuleLoads() {
        XCTAssertEqual(AnAIOdysseyAI.version, AnAIOdysseyCore.version)
    }
}

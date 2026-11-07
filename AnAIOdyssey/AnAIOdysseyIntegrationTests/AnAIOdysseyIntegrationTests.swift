// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

final class AnAIOdysseyIntegrationTests: XCTestCase {
    func testIntegrationTargetLoads() throws {
        let mlxDeviceTests = ProcessInfo.processInfo.environment["MLX_DEVICE_TESTS"] == "1"
        if mlxDeviceTests {
            // MLX device tests added in Step 8.
            XCTAssertTrue(true)
        } else {
            throw XCTSkip("MLX device integration tests require MLX_DEVICE_TESTS=1 on physical hardware")
        }
    }
}
